import Foundation
import Network
import Combine
import CryptoKit
import SystemConfiguration
import dnssd

/// A tiny, read-only web dashboard served on the local network. Gantry stays a desktop app; this just
/// exposes a browser view of the fleet at http://gantry.local:8787 (and the machine IP as a fallback).
/// View-only: no control, no assignment. LAN only. Live via WebSocket push (polling as a fallback).
@MainActor
final class GantryWebServer {
    static let port: UInt16 = 8787

    private weak var store: PrinterStore?
    /// Set by GantryApp so the /api/sync endpoint can serve and receive snapshots. Optional so the
    /// dashboard still runs if sync is not wired.
    weak var syncService: SyncService?
    private var listener: NWListener?
    private nonisolated let queue = DispatchQueue(label: "gantry.webserver")
    private var mdnsService: DNSServiceRef?
    /// Open WebSocket connections we push fleet snapshots to on every telemetry change.
    private var sockets: [ObjectIdentifier: NWConnection] = [:]
    private var telemetrySub: AnyCancellable?
    private var printersSub: AnyCancellable?

    init(store: PrinterStore) { self.store = store }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("Gantry web server failed: %@", "\(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
            registerHostname()
            // Push a fresh snapshot to every open socket whenever the fleet changes (WebSocket = instant).
            if let store {
                telemetrySub = store.$telemetry
                    .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
                    .sink { [weak self] _ in self?.pushSnapshot() }
                printersSub = store.$printers
                    .sink { [weak self] _ in self?.pushSnapshot() }
            }
            NSLog("Gantry web dashboard: %@  •  %@", Self.primaryURL(), Self.lanURL() ?? "?")
        } catch {
            NSLog("Gantry web server could not start: %@", "\(error)")
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        telemetrySub = nil; printersSub = nil
        for conn in sockets.values { conn.cancel() }
        sockets.removeAll()
        if let mdnsService { DNSServiceRefDeallocate(mdnsService); self.mdnsService = nil }
    }

    // MARK: Connection handling

    /// A fully-read HTTP request: start line + headers + (for POST) the body.
    private struct ParsedRequest: Sendable {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased header names
        var body: Data
    }

    private nonisolated func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    /// Accumulates bytes until the full request (headers, and any Content-Length body) has arrived, so
    /// POST /api/sync with a large JSON body that spans several TCP reads is assembled correctly.
    private nonisolated func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let parsed = Self.parseRequest(buf) {
                let wsKey = parsed.headers["sec-websocket-key"]
                Task { @MainActor in self.respond(conn, parsed, wsKey: wsKey) }
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    private nonisolated static func parseRequest(_ data: Data) -> ParsedRequest? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: terminator) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headerRange.upperBound
        if let lengthText = headers["content-length"], let length = Int(lengthText), length > 0 {
            guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }   // need more
            let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: length))
            return ParsedRequest(method: method, path: path, headers: headers, body: body)
        }
        return ParsedRequest(method: method, path: path, headers: headers, body: Data())
    }

    private func respond(_ conn: NWConnection, _ request: ParsedRequest, wsKey: String?) {
        if request.path.hasPrefix("/ws"), let wsKey, request.method == "GET" {
            acceptWebSocket(conn, key: wsKey)
            return
        }
        let (status, body, type) = route(request)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Bad Request")
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Routes a request to a response tuple (status, body, contentType). The dashboard endpoints are
    /// open (read-only view); /api/sync requires the shared bearer token.
    private func route(_ request: ParsedRequest) -> (Int, Data, String) {
        if request.path.hasPrefix("/api/sync") {
            guard let sync = syncService, sync.authorize(bearer: request.headers["authorization"]) else {
                return (401, Data("{\"error\":\"unauthorized\"}".utf8), "application/json")
            }
            switch request.method {
            case "GET":
                let data = (try? SyncService.encoder.encode(sync.localSnapshot())) ?? Data("{}".utf8)
                return (200, data, "application/json")
            case "POST":
                if let snapshot = try? SyncService.decoder.decode(SyncSnapshot.self, from: request.body) {
                    sync.apply(snapshot)
                    return (200, Data("{\"ok\":true}".utf8), "application/json")
                }
                return (400, Data("{\"error\":\"bad snapshot\"}".utf8), "application/json")
            default:
                return (400, Data("{\"error\":\"method\"}".utf8), "application/json")
            }
        }
        if request.path.hasPrefix("/api/printers") { return (200, fleetJSON(), "application/json") }
        return (200, Data(Self.html.utf8), "text/html; charset=utf-8")
    }

    // MARK: WebSocket (server -> client push, view-only)

    private func acceptWebSocket(_ conn: NWConnection, key: String) {
        let accept = Self.wsAcceptKey(key)
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        let id = ObjectIdentifier(conn)
        sockets[id] = conn
        // First paint straight away, then updates arrive on change.
        conn.send(content: Self.wsFrame(fleetJSON()), completion: .contentProcessed { _ in })
        drainWebSocket(conn, id: id)
    }

    /// We never read meaningful data from the client (dashboard is read-only); we only watch for the
    /// socket closing so we can drop it from the push set.
    private nonisolated func drainWebSocket(_ conn: NWConnection, id: ObjectIdentifier) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            let closed = isComplete || error != nil || (data?.first.map { ($0 & 0x0F) == 0x8 } ?? false)
            if closed {
                Task { @MainActor in self?.sockets[id] = nil }
                conn.cancel()
                return
            }
            self?.drainWebSocket(conn, id: id)
        }
    }

    private func pushSnapshot() {
        guard !sockets.isEmpty else { return }
        let frame = Self.wsFrame(fleetJSON())
        for conn in sockets.values {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// RFC 6455 handshake accept value: base64(SHA1(key + magic GUID)).
    private nonisolated static func wsAcceptKey(_ key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// A single unmasked text frame (server -> client).
    private nonisolated static func wsFrame(_ payload: Data) -> Data {
        var frame = Data([0x81])   // FIN + opcode 0x1 (text)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((n >> 8) & 0xFF)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    // MARK: Snapshot -> JSON

    private func fleetJSON() -> Data {
        guard let store else { return Data("{\"printers\":[]}".utf8) }
        var printers: [[String: Any]] = []
        for printer in store.printers {
            let t = store.telemetry[printer.serial] ?? PrinterTelemetry()
            var groups: [[String: Any]] = []
            for (gi, group) in t.filamentGroups.enumerated() {
                var slots: [[String: Any]] = []
                for (si, slot) in group.slots.enumerated() {
                    let loc = SpoolLocation(printerSerial: printer.serial,
                                            feeder: group.isExternal ? .ext : .ams, amsIndex: gi, slot: si)
                    let spool = SpoolbaseShared.spools.spool(at: loc)
                    let def = spool.flatMap { s in SpoolbaseShared.filaments.filaments.first { $0.id == s.filamentDefinitionID } }
                    slots.append([
                        "label": slot.label,
                        "material": slot.isPresent ? (slot.material ?? "") : (def?.type ?? ""),
                        "colorHex": def?.colorHex ?? slot.colorHex ?? "8E8E93",
                        "percent": spool?.percent ?? slot.remainingPercent as Any,
                        "grams": spool.map { Int($0.remainingWeightGrams) } as Any,
                        "active": slot.isActive
                    ])
                }
                groups.append([
                    "name": group.displayName, "external": group.isExternal,
                    "humidity": group.humidityPercent as Any, "temp": group.temperatureCelsius as Any,
                    "slots": slots
                ])
            }
            // Only a running/paused print has a job to show; finished/idle echoes the last file name.
            let activeJob = (t.state == .printing || t.state == .paused) ? (t.jobName ?? "") : ""
            printers.append([
                "name": printer.name, "state": t.state.rawValue, "progress": t.progress,
                "remainingMinutes": t.remainingMinutes as Any, "job": activeJob,
                "nozzle": t.nozzleTemperature as Any, "bed": t.bedTemperature as Any, "chamber": t.chamberTemperature as Any,
                "layer": t.currentLayer as Any, "totalLayers": t.totalLayers as Any,
                "groups": groups
            ])
        }
        let payload: [String: Any] = ["printers": printers]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"printers\":[]}".utf8)
    }

    // MARK: Addresses (for the Settings QR + URL list)

    /// The machine's Bonjour local hostname without the trailing dot, e.g. "gantry" or "MacBook-Pro".
    static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? , !name.isEmpty else { return nil }
        return name
    }

    /// Preferred URL to show first: the friendly `<host>.local` name (works via the system mDNS responder).
    static func primaryURL() -> String {
        if let host = localHostName() { return "http://\(host).local:\(port)" }
        return lanURL() ?? "http://gantry.local:\(port)"
    }

    /// The raw LAN IP URL, which always works on the same network regardless of mDNS.
    static func lanURL() -> String? {
        guard let ip = localIPv4() else { return nil }
        return "http://\(ip):\(port)"
    }

    // MARK: mDNS hostname (gantry.local) + local IP

    private func registerHostname() {
        guard let ip = Self.localIPv4(), var addr = in_addr(withHost: ip) else { return }
        var ref: DNSServiceRef?
        var recordRef: DNSRecordRef?
        let err = DNSServiceCreateConnection(&ref)
        guard err == kDNSServiceErr_NoError, let ref else { return }
        _ = "gantry.local".withCString { name in
            DNSServiceRegisterRecord(ref, &recordRef, kDNSServiceFlagsShared, 0, name,
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                     4, &addr, 0, nil, nil)
        }
        DNSServiceSetDispatchQueue(ref, queue)
        mdnsService = ref
    }

    static func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: p.pointee.ifa_name)
                if name.hasPrefix("en") {   // Wi-Fi / Ethernet, skip VPN/utun
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                        break
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }

    // MARK: The (single-file) web UI — same neutral look as the app, read-only, live via WebSocket.

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Gantry</title>
    <style>
      :root{--bg:#0c0d0e;--card:#151719;--line:rgba(255,255,255,.09);--text:#f2f3f1;--sec:#a7aaa6;--muted:#6d716e;--acc:#d4d7d3;--noz:#ff8a61;--bed:#efbd5f;--cham:#bba5ef}
      *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
      body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,system-ui,'Segoe UI',sans-serif;padding:14px}
      h1{font-size:18px;font-weight:800;letter-spacing:.5px;margin:0 0 2px}
      .sub{color:var(--sec);font-size:12px;margin-bottom:14px}
      .dot{display:inline-block;width:6px;height:6px;border-radius:3px;background:var(--muted);margin-right:5px;vertical-align:middle}
      .dot.live{background:#73cfad}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px}
      .card{background:rgba(21,23,25,.6);border:1px solid var(--line);border-radius:16px;padding:12px}
      .top{display:flex;align-items:center;gap:8px}
      .name{font-weight:600;font-size:14px}
      .pill{font-size:9px;color:var(--sec);border:1px solid var(--line);border-radius:5px;padding:2px 6px}
      .status{color:var(--sec);font-size:11px;margin:6px 0 2px}
      .pct{font-size:26px;font-weight:600;font-variant-numeric:tabular-nums}
      .rule{height:1px;background:var(--line);margin:8px 0}
      .temps{display:flex;gap:6px}
      .temp{flex:1}.temp .l{font-size:7px;color:var(--sec);letter-spacing:.5px}
      .temp .v{font-size:15px;font-weight:600;font-variant-numeric:tabular-nums}
      .ams{display:flex;gap:10px;flex-wrap:wrap;margin-top:2px}
      .grp{flex:1;min-width:120px}.grp .h{font-size:10px;font-weight:600}
      .slots{display:flex;gap:5px;margin-top:4px}
      .slot{flex:1;text-align:center}
      .sw{height:22px;border-radius:6px;border:1px solid var(--line);display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700}
      .mat{font-size:10px;font-weight:600;margin-top:2px}
      .off{opacity:.45}
      .foot{color:var(--muted);text-align:center;font-size:11px;margin-top:16px}
    </style></head><body>
    <h1>GANTRY</h1><div class="sub" id="sub"><span class="dot" id="dot"></span>Ładowanie…</div>
    <div class="grid" id="grid"></div>
    <div class="foot">Podgląd na żywo • tylko sieć lokalna</div>
    <script>
    const NOZ='var(--noz)',BED='var(--bed)',CHAM='var(--cham)';
    function ink(hex){hex=(hex||'').replace('#','');const r=parseInt(hex.substr(0,2),16),g=parseInt(hex.substr(2,2),16),b=parseInt(hex.substr(4,2),16);return (0.299*r+0.587*g+0.114*b)/255>0.58?'#151719':'#fff'}
    function temp(v,c){return v==null?'<span class="v" style="color:var(--muted)">—</span>':'<span class="v" style="color:'+c+'">'+Math.round(v)+'°</span>'}
    function render(d){
      const ps=(d&&d.printers)||[];
      document.getElementById('sub').innerHTML='<span class="dot'+(live?' live':'')+'" id="dot"></span>'+ps.length+' drukarek • '+ps.filter(p=>p.state==='printing').length+' pracuje';
      document.getElementById('grid').innerHTML=ps.map(p=>{
        const temps='<div class="temps">'+
          '<div class="temp"><div class="l">DYSZA</div>'+temp(p.nozzle,NOZ)+'</div>'+
          '<div class="temp"><div class="l">STÓŁ</div>'+temp(p.bed,BED)+'</div>'+
          (p.chamber!=null?'<div class="temp"><div class="l">KOMORA</div>'+temp(p.chamber,CHAM)+'</div>':'')+'</div>';
        const ams=(p.groups||[]).map(g=>'<div class="grp"><div class="h">'+g.name+'</div><div class="slots">'+
          g.slots.map(s=>{const pct=s.percent==null?'':s.percent+'%';const col=s.material?('#'+ (s.colorHex||'8E8E93')):'transparent';
            const style=s.material?('background:'+col+';color:'+ink(s.colorHex)):'';
            return '<div class="slot"><div class="sw" style="'+style+'">'+pct+'</div><div class="mat">'+(s.material||'—')+'</div></div>'}).join('')+'</div></div>').join('');
        const off=p.state==='offline';
        return '<div class="card'+(off?' off':'')+'"><div class="top"><span class="name">'+p.name+'</span><span class="pill">'+p.state+'</span></div>'+
          '<div class="status">'+(p.job||'')+'</div><div class="pct">'+p.progress+'%</div>'+
          '<div class="rule"></div>'+temps+(ams?'<div class="rule"></div><div class="ams">'+ams+'</div>':'')+'</div>';
      }).join('');
    }
    // Live via WebSocket push; fall back to polling if the socket cannot be established.
    let live=false, pollTimer=null;
    function poll(){fetch('/api/printers').then(r=>r.json()).then(render).catch(()=>{});}
    function startPolling(){if(!pollTimer){poll();pollTimer=setInterval(poll,2000);}}
    function stopPolling(){if(pollTimer){clearInterval(pollTimer);pollTimer=null;}}
    function connect(){
      let ws;
      try{ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');}
      catch(e){startPolling();return;}
      ws.onopen=()=>{live=true;stopPolling();};
      ws.onmessage=e=>{try{render(JSON.parse(e.data));}catch(_){}};
      ws.onerror=()=>{try{ws.close();}catch(_){}};
      ws.onclose=()=>{live=false;startPolling();setTimeout(connect,1500);};
    }
    poll();connect();
    </script></body></html>
    """
}

private extension in_addr {
    init?(withHost host: String) {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        self = addr
    }
}
