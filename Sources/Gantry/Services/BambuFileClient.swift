import Foundation
import Network

/// Downloads the currently-printed `.gcode.3mf` from a Bambu printer over the printer's local FTPS
/// (implicit TLS, port 990, user `bblp`, password = access code, self-signed cert accepted). Fully
/// local: no cloud, no account. The bytes go to `ThreeMFReader` to read per-filament `used_g`.
///
/// Untested against hardware at build time; tuned live like the camera. Verbose NSLog on failure so a
/// real printer can be debugged without a rebuild.
actor BambuFileClient {
    struct FTPError: Error { let message: String }

    private let host: String
    private let accessCode: String
    private let queue = DispatchQueue(label: "gantry.bambu.ftps")
    private var control: NWConnection?
    private var buffer = Data()

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    /// Fetches the print file. `fileName` is the MQTT `gcode_file` (may be a path or a bare name); we try
    /// it directly and under the usual Bambu roots. Returns the raw 3mf bytes.
    func fetch(fileName: String) async throws -> Data {
        try await open(port: 990)
        _ = try await expect(220)
        try await send("USER bblp"); _ = try await expect(331)
        try await send("PASS \(accessCode)"); _ = try await expect(230)
        try await send("PBSZ 0"); _ = try await readResponse()
        try await send("PROT P"); _ = try await readResponse()
        try await send("TYPE I"); _ = try await readResponse()

        let base = (fileName as NSString).lastPathComponent
        let candidates = [fileName, "/\(base)", base, "/cache/\(base)", "/model/\(base)"]
        var lastError = "no candidate path worked"
        for path in candidates {
            do { return try await retr(path) }
            catch let e as FTPError { lastError = e.message }
        }
        close()
        throw FTPError(message: "RETR failed for \(base): \(lastError)")
    }

    // MARK: FTP verbs

    private func retr(_ path: String) async throws -> Data {
        try await send("PASV")
        let pasv = try await readResponse()
        guard let dataPort = parsePASV(pasv.text) else { throw FTPError(message: "bad PASV: \(pasv.text)") }
        // Open the (also-TLS) data channel first, then issue RETR on the control channel.
        let dataConn = try await openData(port: dataPort)
        try await send("RETR \(path)")
        let mark = try await readResponse()          // 150/125 = transfer starting
        guard mark.code == 150 || mark.code == 125 else {
            dataConn.cancel()
            throw FTPError(message: "RETR \(path) -> \(mark.code) \(mark.text)")
        }
        let payload = try await readAll(dataConn)
        dataConn.cancel()
        _ = try await readResponse()                 // 226 transfer complete
        close()
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

    private func openData(port: UInt16) async throws -> NWConnection {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tlsParams())
        try await start(conn)
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
        control?.cancel()
        control = nil
        buffer.removeAll()
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
