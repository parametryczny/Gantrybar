import Foundation
import Network

/// Bambu's local FTPS service effectively handles one transfer at a time. Spool accounting and the
/// skip-object selector can ask for the same 3MF simultaneously, so serialize them per printer and
/// share the result instead of opening a second control connection that never receives a greeting.
private actor BambuFTPBroker {
    static let shared = BambuFTPBroker()
    private var heldHosts = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cache: [String: (data: Data, date: Date)] = [:]

    func acquire(host: String) async {
        guard heldHosts.contains(host) else { heldHosts.insert(host); return }
        await withCheckedContinuation { waiters[host, default: []].append($0) }
    }

    func release(host: String) {
        if var queued = waiters[host], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[host] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            heldHosts.remove(host)
        }
    }

    func cached(_ key: String) -> Data? {
        guard let value = cache[key], Date().timeIntervalSince(value.date) < 300 else {
            cache[key] = nil
            return nil
        }
        return value.data
    }

    func store(_ data: Data, for key: String) { cache[key] = (data, Date()) }
}

/// Downloads the currently-printed `.gcode.3mf` from a Bambu printer over the printer's local FTPS
/// (implicit TLS, port 990, user `bblp`, password = access code, self-signed cert accepted). Fully
/// local: no cloud, no account. The bytes go to `ThreeMFReader` to read per-filament `used_g`.
///
/// Untested against hardware at build time; tuned live like the camera. Verbose NSLog on failure so a
/// real printer can be debugged without a rebuild.
actor BambuFileClient {
    struct FTPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let host: String
    private let accessCode: String
    private let queue = DispatchQueue(label: "gantry.bambu.ftps")
    private var control: NWConnection?
    private var dataConnection: NWConnection?
    private var buffer = Data()
    private var didTimeout = false

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    /// Fetches the print file. `fileName` is the MQTT `gcode_file` (may be a path or a bare name); we try
    /// it directly and under the usual Bambu roots. Returns the raw 3mf bytes.
    func fetch(fileName: String) async throws -> Data {
        let base = (fileName as NSString).lastPathComponent
        let cacheKey = host + "|" + base
        if let cached = await BambuFTPBroker.shared.cached(cacheKey) { return cached }

        await BambuFTPBroker.shared.acquire(host: host)
        do {
            // The same file may have completed while this caller waited behind another transfer.
            if let cached = await BambuFTPBroker.shared.cached(cacheKey) {
                await BambuFTPBroker.shared.release(host: host)
                return cached
            }
            let data = try await fetchUncoordinated(fileName: fileName, base: base)
            await BambuFTPBroker.shared.store(data, for: cacheKey)
            await BambuFTPBroker.shared.release(host: host)
            return data
        } catch {
            await BambuFTPBroker.shared.release(host: host)
            throw error
        }
    }

    private func fetchUncoordinated(fileName: String, base: String) async throws -> Data {
        didTimeout = false
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(60))
            await self?.expireTransfer()
        }
        defer { watchdog.cancel(); close() }
        do {
            try await open(port: 990)
            _ = try await expect(220)
            try await send("USER bblp"); _ = try await expect(331)
            try await send("PASS \(accessCode)"); _ = try await expect(230)
            try await send("PBSZ 0"); _ = try await readResponse()
            try await send("PROT P"); _ = try await readResponse()
            try await send("TYPE I"); _ = try await readResponse()

            let candidates = Self.candidatePaths(fileName: fileName)
            var lastError = "no candidate path worked"
            for path in candidates {
                do { return try await retr(path) }
                catch let error as FTPError { lastError = error.message }
            }
            throw FTPError(message: "RETR failed for \(base) after \(candidates.count) paths: \(lastError)")
        } catch {
            if didTimeout { throw FTPError(message: "transfer timed out after 60 s") }
            throw error
        }
    }

    /// Bambu reports the archive inconsistently across firmware generations. In particular X2D
    /// reports `subtask_name` without an extension while `gcode_file` points to the plate g-code
    /// *inside* the archive. Build the real names used on the SD card and try all known roots.
    static func candidatePaths(fileName: String) -> [String] {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let raw = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        var names: [String] = []
        func addName(_ value: String) {
            let value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !value.isEmpty, !names.contains(value) else { return }
            names.append(value)
        }

        let last = (raw as NSString).lastPathComponent
        addName(raw)
        addName(last)
        for seed in [raw, last] {
            let lower = seed.lowercased()
            if !lower.hasSuffix(".3mf") {
                addName(seed + ".gcode.3mf")
                addName(seed + ".3mf")
            }
        }
        // Studio/cloud jobs sometimes replace spaces with underscores in the SD-card filename.
        for name in names where name.contains(" ") { addName(name.replacingOccurrences(of: " ", with: "_")) }

        var paths: [String] = []
        func addPath(_ value: String) {
            guard !paths.contains(value) else { return }
            paths.append(value)
        }
        for name in names {
            addPath(name)
            addPath("/\(name)")
            let leaf = (name as NSString).lastPathComponent
            for root in ["cache", "model", "data"] {
                addPath("/\(root)/\(leaf)")
                addPath("\(root)/\(leaf)")
            }
        }
        return paths
    }

    // MARK: FTP verbs

    private func retr(_ path: String) async throws -> Data {
        try await send("PASV")
        let pasv = try await readResponse()
        guard let dataPort = parsePASV(pasv.text) else { throw FTPError(message: "bad PASV: \(pasv.text)") }
        // Start the passive data channel, but do not wait for its TLS handshake yet. X2D begins that
        // handshake only after RETR arrives on the control channel; awaiting `.ready` first causes a
        // perfect deadlock (both sides wait until our 60-second watchdog fires).
        let dataConn = makeDataConnection(port: dataPort)
        async let dataReady: Void = start(dataConn)
        try await send("RETR \(path)")
        let mark = try await readResponse()          // 150/125 = transfer starting
        guard mark.code == 150 || mark.code == 125 else {
            dataConn.cancel()
            throw FTPError(message: "RETR \(path) -> \(mark.code) \(mark.text)")
        }
        try await dataReady
        let payload = try await readAll(dataConn)
        dataConn.cancel()
        dataConnection = nil
        _ = try await readResponse()                 // 226 transfer complete
        return payload
    }

    private func parsePASV(_ text: String) -> UInt16? {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return nil }
        let nums = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { return nil }
        return UInt16(nums[4] * 256 + nums[5])
    }

    // MARK: Connections (implicit TLS, self-signed accepted)

    private func tlsParams() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        return NWParameters(tls: tls)
    }

    private func open(port: UInt16) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tlsParams())
        control = conn
        try await start(conn)
    }

    private func makeDataConnection(port: UInt16) -> NWConnection {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tlsParams())
        dataConnection = conn
        return conn
    }

    private func start(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let e): cont.resume(throwing: e)
                case .cancelled: cont.resume(throwing: FTPError(message: "cancelled"))
                default: break
                }
            }
            conn.start(queue: queue)
        }
        conn.stateUpdateHandler = nil
    }

    private func close() {
        dataConnection?.cancel()
        dataConnection = nil
        control?.cancel()
        control = nil
        buffer.removeAll()
    }

    private func expireTransfer() {
        didTimeout = true
        close()
    }

    // MARK: Control I/O

    private func send(_ line: String) async throws {
        guard let control else { throw FTPError(message: "no control connection") }
        let data = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            control.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func expect(_ code: Int) async throws -> (code: Int, text: String) {
        let r = try await readResponse()
        guard r.code == code else { throw FTPError(message: "expected \(code), got \(r.code): \(r.text)") }
        return r
    }

    /// Reads one FTP reply, honouring multi-line replies ("123-...\r\n...\r\n123 done").
    private func readResponse() async throws -> (code: Int, text: String) {
        var lines: [String] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            if line.count >= 4, let code = Int(line.prefix(3)), line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return (code, lines.joined(separator: "\n"))
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.firstRange(of: Data([0x0d, 0x0a])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            try await receiveMore()
        }
    }

    private func receiveMore() async throws {
        guard let control else { throw FTPError(message: "no control connection") }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            control.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: FTPError(message: "control closed")) }
                else { cont.resume(returning: Data()) }
            }
        }
        buffer.append(chunk)
    }

    private func readAll(_ conn: NWConnection) async throws -> Data {
        var out = Data()
        while true {
            let (chunk, done): (Data, Bool) = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 262144) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: (data ?? Data(), isComplete)) }
                }
            }
            out.append(chunk)
            if done { return out }
        }
    }
}
