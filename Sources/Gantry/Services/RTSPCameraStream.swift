import Foundation
import Network
import CryptoKit

/// Live chamber-camera stream for Bambu X1/X1C (and compatible) over the printer's RTSPS server.
///
/// Path: `rtsps://bblp:<access code>@<ip>:322/streaming/live/1`. The printer runs a LIVE555 RTSP
/// server behind TLS with HTTP Digest auth. We speak RTSP over the TLS control connection and pull
/// the RTP packets back over the *same* connection (TCP-interleaved transport), so a single socket
/// carries everything — no separate UDP data channel to negotiate through TLS. RTP payloads are
/// H.264 (RFC 6184); we reassemble them into access units and hand AVCC-framed NAL data to the view,
/// which decodes+displays via AVSampleBufferDisplayLayer.
///
/// Unlike the legacy port-6000 stream this works while the printer is cloud-connected (only "LAN Mode
/// Live View" needs enabling), which is why it replaces it.
final class RTSPCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, playing, failed(String) }

    private let host: String
    private let port: UInt16
    private let path: String            // e.g. "streaming/live/1"
    private let accessCode: String
    private let onState: @Sendable (State) -> Void
    private let onParameterSets: @Sendable (_ sps: Data, _ pps: Data) -> Void
    private let onAccessUnit: @Sendable (_ avcc: Data, _ isKeyframe: Bool) -> Void

    private let queue = DispatchQueue(label: "pl.gantry.rtsp")
    private var connection: NWConnection?
    private var stopped = false

    // RTSP state
    private var cseq = 1
    private var realm = ""
    private var nonce = ""
    private var sessionID = ""
    private var baseURL = ""
    private var controlURL = ""
    private enum Phase { case options, describe, describeAuth, setup, play, streaming }
    private var phase: Phase = .options

    // Buffers
    private var textBuffer = Data()     // RTSP response accumulation
    private var rtpBuffer = [UInt8]()   // interleaved binary accumulation (after PLAY); array stays 0-based

    // H.264 reassembly
    private var fuBuffer = Data()       // current fragmented NAL
    private var accessUnit: [Data] = [] // NAL units for the current frame
    private var sps: Data?
    private var pps: Data?

    private var requestURL: String { "rtsps://\(host)/\(path)" }

    init(host: String, port: UInt16 = 322, path: String = "streaming/live/1", accessCode: String,
         onState: @escaping @Sendable (State) -> Void,
         onParameterSets: @escaping @Sendable (_ sps: Data, _ pps: Data) -> Void,
         onAccessUnit: @escaping @Sendable (_ avcc: Data, _ isKeyframe: Bool) -> Void) {
        self.host = host
        self.port = port
        self.path = path
        self.accessCode = accessCode
        self.onState = onState
        self.onParameterSets = onParameterSets
        self.onAccessUnit = onAccessUnit
    }

    func start() {
        onState(.connecting)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)   // self-signed LAN device
        }, queue)
        let params = NWParameters(tls: tls)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendDescribe(auth: false)
                self.receiveLoop()
            case .failed(let error):
                self.onState(.failed(error.localizedDescription))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func stop() {
        stopped = true
        if !controlURL.isEmpty || !sessionID.isEmpty {
            sendRaw("TEARDOWN \(requestURL) RTSP/1.0\r\nCSeq: \(cseq)\r\n\(authHeader("TEARDOWN"))\(sessionLine())\r\n")
        }
        connection?.cancel()
        connection = nil
    }

    // MARK: RTSP requests

    private func sendDescribe(auth: Bool) {
        phase = auth ? .describeAuth : .describe
        sendRaw("DESCRIBE \(requestURL) RTSP/1.0\r\nCSeq: \(cseq)\r\nAccept: application/sdp\r\n\(auth ? authHeader("DESCRIBE") : "")\r\n")
    }

    private func sendSetup() {
        phase = .setup
        let target = controlURL.isEmpty ? requestURL : controlURL
        sendRaw("SETUP \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\(authHeader("SETUP", uri: target))\r\n")
    }

    private func sendPlay() {
        phase = .play
        sendRaw("PLAY \(requestURL) RTSP/1.0\r\nCSeq: \(cseq)\r\nRange: npt=0.000-\r\n\(authHeader("PLAY"))\(sessionLine())\r\n")
    }

    private func sendRaw(_ text: String) {
        cseq += 1
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func sessionLine() -> String { sessionID.isEmpty ? "" : "Session: \(sessionID)\r\n" }

    /// HTTP Digest (RFC 2617) authorization header for the given method.
    private func authHeader(_ method: String, uri: String? = nil) -> String {
        guard !realm.isEmpty, !nonce.isEmpty else { return "" }
        let u = uri ?? requestURL
        let ha1 = md5("bblp:\(realm):\(accessCode)")
        let ha2 = md5("\(method):\(u)")
        let response = md5("\(ha1):\(nonce):\(ha2)")
        return "Authorization: Digest username=\"bblp\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(u)\", response=\"\(response)\"\r\n"
    }

    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Receive

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if let error { self.onState(.failed(error.localizedDescription)); return }
            if isComplete { self.onState(.failed("Połączenie zamknięte")); return }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) {
        if phase == .streaming {
            rtpBuffer.append(contentsOf: data)
            drainInterleaved()
        } else {
            textBuffer.append(data)
            drainRTSPResponses()
        }
    }

    /// Parse complete RTSP responses (header block + optional Content-Length body).
    private func drainRTSPResponses() {
        while let headerEnd = textBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: textBuffer[textBuffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var total = headerEnd.upperBound
            if let cl = value(of: "Content-Length", in: header), let len = Int(cl) {
                guard textBuffer.distance(from: headerEnd.upperBound, to: textBuffer.endIndex) >= len else { return }
                total = textBuffer.index(headerEnd.upperBound, offsetBy: len)
            }
            let body = String(decoding: textBuffer[headerEnd.upperBound..<total], as: UTF8.self)
            textBuffer.removeSubrange(textBuffer.startIndex..<total)
            handleResponse(header: header, body: body)
        }
    }

    private func handleResponse(header: String, body: String) {
        let statusLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let is401 = statusLine.contains(" 401")
        let isOK = statusLine.contains(" 200")

        if let auth = value(of: "WWW-Authenticate", in: header) {
            if let r = firstMatch(#"realm="([^"]+)""#, in: auth) { realm = r }
            if let n = firstMatch(#"nonce="([^"]+)""#, in: auth) { nonce = n }
        }
        if let s = value(of: "Session", in: header) {
            sessionID = s.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? s
        }

        switch phase {
        case .describe:
            if is401 { sendDescribe(auth: true) } else if isOK { parseSDP(body); sendSetup() }
        case .describeAuth:
            if isOK { parseSDP(body); sendSetup() }
            else { onState(.failed("DESCRIBE: \(statusLine)")) }
        case .setup:
            if isOK { sendPlay() } else { onState(.failed("SETUP: \(statusLine)")) }
        case .play:
            if isOK { phase = .streaming; onState(.playing) } else { onState(.failed("PLAY: \(statusLine)")) }
        default:
            break
        }
    }

    private func parseSDP(_ sdp: String) {
        for line in sdp.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("a=control:"), !l.hasSuffix("*") {
                let ctrl = String(l.dropFirst("a=control:".count))
                controlURL = ctrl.hasPrefix("rtsp") ? ctrl : "\(requestURL)/\(ctrl)"
            }
            if l.hasPrefix("a=fmtp:"), let range = l.range(of: "sprop-parameter-sets=") {
                let sets = l[range.upperBound...].split(separator: ";").first.map(String.init) ?? ""
                let parts = sets.split(separator: ",")
                if parts.count >= 2,
                   let spsData = Data(base64Encoded: String(parts[0])),
                   let ppsData = Data(base64Encoded: String(parts[1])) {
                    sps = spsData; pps = ppsData
                    onParameterSets(spsData, ppsData)
                }
            }
        }
    }

    // MARK: Interleaved RTP → H.264

    /// Interleaved frames: `$`(0x24) channel(1) length(2 BE) payload(length).
    private func drainInterleaved() {
        while rtpBuffer.count >= 4 {
            guard rtpBuffer[0] == 0x24 else {
                // Out of sync (or an interleaved RTSP response) — drop one byte and resync.
                rtpBuffer.removeFirst()
                continue
            }
            let channel = rtpBuffer[1]
            let length = Int(rtpBuffer[2]) << 8 | Int(rtpBuffer[3])
            guard rtpBuffer.count >= 4 + length else { return }
            let packet = Data(rtpBuffer[4..<(4 + length)])
            rtpBuffer.removeFirst(4 + length)
            if channel == 0 { handleRTP(packet) }   // channel 0 = RTP
        }
    }

    private func handleRTP(_ packet: Data) {
        guard packet.count > 12 else { return }
        let b0 = packet[packet.startIndex]
        let hasExt = (b0 & 0x10) != 0
        let csrc = Int(b0 & 0x0F)
        let marker = (packet[packet.startIndex + 1] & 0x80) != 0
        var offset = 12 + csrc * 4
        if hasExt {
            guard packet.count >= offset + 4 else { return }
            let extLen = Int(packet[packet.startIndex + offset + 2]) << 8 | Int(packet[packet.startIndex + offset + 3])
            offset += 4 + extLen * 4
        }
        guard packet.count > offset else { return }
        let payload = packet.subdata(in: (packet.startIndex + offset)..<packet.endIndex)
        depacketize(payload, marker: marker)
    }

    private func depacketize(_ payload: Data, marker: Bool) {
        guard let first = payload.first else { return }
        let type = first & 0x1F
        switch type {
        case 1...23:
            appendNAL(payload)
        case 24: // STAP-A
            var i = payload.index(payload.startIndex, offsetBy: 1)
            while i < payload.endIndex {
                guard payload.distance(from: i, to: payload.endIndex) >= 2 else { break }
                let size = Int(payload[i]) << 8 | Int(payload[payload.index(after: i)])
                let start = payload.index(i, offsetBy: 2)
                guard payload.distance(from: start, to: payload.endIndex) >= size else { break }
                appendNAL(payload.subdata(in: start..<payload.index(start, offsetBy: size)))
                i = payload.index(start, offsetBy: size)
            }
        case 28: // FU-A
            guard payload.count >= 2 else { return }
            let fuHeader = payload[payload.index(after: payload.startIndex)]
            let start = (fuHeader & 0x80) != 0
            let end = (fuHeader & 0x40) != 0
            let nalType = fuHeader & 0x1F
            if start {
                let nalHeader = (first & 0xE0) | nalType
                fuBuffer = Data([nalHeader])
            }
            if !fuBuffer.isEmpty {
                fuBuffer.append(payload.subdata(in: payload.index(payload.startIndex, offsetBy: 2)..<payload.endIndex))
            }
            if end, !fuBuffer.isEmpty {
                appendNAL(fuBuffer)
                fuBuffer.removeAll(keepingCapacity: true)
            }
        default:
            break
        }
        if marker { flushAccessUnit() }
    }

    private func appendNAL(_ nal: Data) {
        guard let first = nal.first else { return }
        let type = first & 0x1F
        if type == 7 { sps = nal; emitParamsIfReady() ; return }   // SPS
        if type == 8 { pps = nal; emitParamsIfReady() ; return }   // PPS
        accessUnit.append(nal)
    }

    private func emitParamsIfReady() {
        if let sps, let pps { onParameterSets(sps, pps) }
    }

    /// Emit the collected NALs as one AVCC access unit (4-byte length prefixes).
    private func flushAccessUnit() {
        guard !accessUnit.isEmpty else { return }
        var avcc = Data()
        var keyframe = false
        for nal in accessUnit {
            if let f = nal.first, (f & 0x1F) == 5 { keyframe = true }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        accessUnit.removeAll(keepingCapacity: true)
        onAccessUnit(avcc, keyframe)
    }

    // MARK: Small helpers

    private func value(of field: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("\(field.lowercased()):") {
            return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
