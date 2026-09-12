import Foundation
import Network
import OSLog

/// Reads model archives from the internal eMMC exposed by recent H2/X2D firmware on TLS port 6000.
/// This is the BambuTunnelLocal CTRL protocol used by Studio's Device → Files browser. FTPS :990 is
/// chrooted to removable storage on these printers and therefore cannot see an active internal job.
actor BambuTunnelFileClient {
    struct TunnelError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RemoteFile {
        let name: String
        let path: String
        let size: Int
        let time: Int
    }

    struct ProjectParts: Sendable {
        let pickPNG: Data
        let modelSettings: Data
        let sliceInfo: Data
    }

    private let host: String
    private let accessCode: String
    private let queue = DispatchQueue(label: "gantry.bambu.tunnel6000")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var frameSequence: UInt32 = 1
    private var commandSequence: UInt32 = 1
    private static let logger = Logger(subsystem: "pl.gantry.app", category: "BambuTunnel")

    init(host: String, accessCode: String) {
        self.host = host
        self.accessCode = accessCode
    }

    /// The active print is not necessarily addressable as a normal file. Bambu Studio's
    /// `PartSkipDialog` asks the printer's virtual `mem:/16` endpoint for these three entries via
    /// `get_project_file`; this works independently of the archive name and storage location.
    func fetchActiveProjectParts(plateIndex: Int) async throws -> ProjectParts {
        defer { close() }
        Self.logger.info("Project-file tunnel: opening port 6000 for plate \(plateIndex, privacy: .public)")
        try await open()
        try await handshake()
        let pick = try await downloadProjectFile("Metadata/pick_\(plateIndex).png", sequenceID: 1)
        let settings = try await downloadProjectFile("Metadata/model_settings.config", sequenceID: 2)
        let slice = try await downloadProjectFile("Metadata/slice_info.config", sequenceID: 3)
        Self.logger.info("Project-file tunnel: received pick=\(pick.count, privacy: .public), model=\(settings.count, privacy: .public), slice=\(slice.count, privacy: .public)")
        return ProjectParts(pickPNG: pick, modelSettings: settings, sliceInfo: slice)
    }

    func fetchArchive(hint: String) async throws -> Data {
        defer { close() }
        Self.logger.info("X2D tunnel: opening port 6000")
        try await open()
        Self.logger.info("X2D tunnel: transport ready")
        try await handshake()
        Self.logger.info("X2D tunnel: handshake ready")

        var files: [RemoteFile] = []
        var lastError: Error?
        for storage in ["emmc", "internal", ""] {
            do {
                let found = try await listModels(storage: storage)
                Self.logger.info("X2D tunnel: storage \(storage.isEmpty ? "default" : storage, privacy: .public) returned \(found.count, privacy: .public) entries")
                files.append(contentsOf: found)
                if !found.isEmpty { break }
            } catch { lastError = error }
        }
        let archives = files.filter {
            let name = $0.name.lowercased()
            return name.hasSuffix(".3mf") || $0.path.lowercased().hasSuffix(".3mf")
        }
        guard let selected = Self.bestMatch(in: archives, hint: hint) else {
            if let lastError { throw lastError }
            throw TunnelError(message: "pamięć wewnętrzna X2D nie zwróciła aktywnego pliku 3MF")
        }
        Self.logger.info("X2D tunnel: downloading \(selected.name, privacy: .public), \(selected.size, privacy: .public) bytes")
        return try await download(selected)
    }

    private func open() async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: 6000, using: NWParameters(tls: tls))
        connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    conn.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    continuation.resume(throwing: TunnelError(message: "tunel X2D został zamknięty"))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func handshake() async throws {
        var login = Data(repeating: 0, count: 16)
        login.replaceSubrange(0..<min(4, login.count), with: Data("bblp".utf8))
        let code = Data(accessCode.utf8.prefix(8))
        login.replaceSubrange(8..<(8 + code.count), with: code)
        try await sendFrame(magic: 0x0101013f, payload: login)
        _ = try await readFrame()

        let setup: [String: Any] = [
            "sequence": 0, "mtype": 12291,
            "req": ["t_av": 1, "mtype": 12289, "peer_t": 3,
                    "pid": String(format: "%08x", frameSequence), "ver": "02.03.00.00"]
        ]
        try await sendFrame(magic: 0x0102013f, payload: try jsonData(setup))
        let ack = try await readJSONFrame()
        Self.logger.info("X2D tunnel: setup result \(self.int(ack["result"]) ?? -1, privacy: .public)")
        guard int(ack["result"]) == 0 else {
            throw TunnelError(message: "X2D odrzucił inicjalizację tunelu plików")
        }
    }

    private func listModels(storage: String) async throws -> [RemoteFile] {
        var request: [String: Any] = ["type": "model", "api_version": 2, "notify": "DETAIL"]
        if !storage.isEmpty { request["storage"] = storage }
        let reply = try await rpc(command: 1, request: request)
        Self.logger.info("X2D tunnel: LIST_INFO \(storage.isEmpty ? "default" : storage, privacy: .public) result \(self.int(reply["result"]) ?? -1, privacy: .public)")
        guard [0, 1].contains(int(reply["result"]) ?? -1) else {
            throw TunnelError(message: "X2D nie udostępnia listy modeli z pamięci \(storage.isEmpty ? "domyślnej" : storage)")
        }
        let body = reply["reply"] as? [String: Any]
        let rows = body?["file_lists"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            let name = string(row["name"]) ?? ""
            let path = string(row["path"]) ?? ""
            guard !name.isEmpty || !path.isEmpty else { return nil }
            return RemoteFile(name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                              path: path, size: int(row["size"]) ?? 0, time: int(row["time"]) ?? 0)
        }
    }

    private func download(_ file: RemoteFile) async throws -> Data {
        let request: [String: Any]
        if file.path.hasPrefix("/") || file.path.hasPrefix("mem:") {
            request = ["path": file.path, "offset": 0]
        } else {
            request = ["file": file.name, "offset": 0]
        }
        let sequence = nextCommandSequence()
        try await sendRPC(command: 4, sequence: sequence, request: request)
        var output = Data()
        while true {
            let payload = try await readFrame().payload
            let (reply, binary) = try splitJSONAndBinary(payload)
            guard int(reply["sequence"]) == Int(sequence) else { continue }
            let details = reply["reply"] as? [String: Any] ?? [:]
            if int(details["mem_dl_param_size"]) == nil { output.append(binary) }
            switch int(reply["result"]) {
            case 1: continue
            case 0:
                let expected = int(details["total"]) ?? file.size
                if expected > 0, output.count != expected {
                    throw TunnelError(message: "niepełny 3MF z X2D: \(output.count) z \(expected) bajtów")
                }
                guard output.count >= 4, output.prefix(2) == Data([0x50, 0x4b]) else {
                    throw TunnelError(message: "X2D nie zwrócił poprawnego archiwum 3MF")
                }
                return output
            default:
                Self.logger.error("X2D tunnel: FILE_DOWNLOAD rejected with result \(self.int(reply["result"]) ?? -1, privacy: .public)")
                throw TunnelError(message: "firmware X2D odmówił pobrania 3MF (kod \(int(reply["result"]) ?? -1))")
            }
        }
    }

    private func downloadProjectFile(_ relativePath: String, sequenceID: Int) async throws -> Data {
        Self.logger.info("Project-file tunnel: requesting \(relativePath, privacy: .public)")
        let parameter: [String: Any] = [
            "sequence_id": sequenceID,
            "version": 1,
            "peer_host": "studio",
            "command": "get_project_file",
            "file_rel_path": relativePath
        ]
        let parameterData = try jsonData(parameter)
        let request: [String: Any] = [
            "path": "mem:/16",
            "offset": 0,
            "mem_dl_param_size": parameterData.count
        ]
        let sequence = nextCommandSequence()
        try await sendRPC(command: 4, sequence: sequence, request: request, parameter: parameterData)

        var output = Data()
        var expected = 0
        while true {
            let payload = try await readFrame().payload
            let (reply, binary) = try splitJSONAndBinary(payload)
            guard int(reply["sequence"]) == Int(sequence) else { continue }
            let details = reply["reply"] as? [String: Any] ?? [:]

            if let headerSize = int(details["mem_dl_param_size"]) {
                guard headerSize > 0, binary.count >= headerSize,
                      let response = try JSONSerialization.jsonObject(with: binary.prefix(headerSize)) as? [String: Any],
                      int(response["result"]) != 1 else {
                    throw TunnelError(message: "drukarka odrzuciła \(relativePath)")
                }
                Self.logger.info("Project-file tunnel: \(relativePath, privacy: .public) accepted, size=\(self.int(response["size"]) ?? -1, privacy: .public)")
                if let size = int(response["size"]), size == 0 {
                    throw TunnelError(message: "drukarka zwróciła pusty \(relativePath)")
                }
                if binary.count > headerSize { output.append(binary.dropFirst(headerSize)) }
            } else {
                output.append(binary)
                expected = int(details["total"]) ?? expected
            }

            switch int(reply["result"]) {
            case 1: continue
            case 0:
                guard !output.isEmpty else {
                    throw TunnelError(message: "drukarka nie zwróciła \(relativePath)")
                }
                if expected > 0, output.count != expected {
                    throw TunnelError(message: "niepełny \(relativePath): \(output.count) z \(expected) bajtów")
                }
                Self.logger.info("Project-file tunnel: \(relativePath, privacy: .public) complete, bytes=\(output.count, privacy: .public)")
                return output
            default:
                throw TunnelError(message: "get_project_file dla \(relativePath) zakończył się kodem \(int(reply["result"]) ?? -1)")
            }
        }
    }

    private func rpc(command: Int, request: [String: Any]) async throws -> [String: Any] {
        let sequence = nextCommandSequence()
        try await sendRPC(command: command, sequence: sequence, request: request)
        while true {
            let reply = try await readJSONFrame()
            if int(reply["sequence"]) == Int(sequence) { return reply }
        }
    }

    private func sendRPC(command: Int, sequence: UInt32, request: [String: Any],
                         parameter: Data? = nil) async throws {
        let object: [String: Any] = ["mtype": 12289, "cmdtype": command,
                                     "sequence": Int(sequence), "req": request]
        var payload = try jsonData(object)
        if let parameter {
            payload.append(contentsOf: [10, 10])
            payload.append(parameter)
        }
        try await sendFrame(magic: 0x0102013f, payload: payload)
    }

    private func nextCommandSequence() -> UInt32 {
        defer { commandSequence &+= 1 }
        return commandSequence
    }

    private func sendFrame(magic: UInt32, payload: Data) async throws {
        var frame = Data()
        append(UInt32(payload.count), to: &frame)
        append(magic, to: &frame)
        append(frameSequence, to: &frame)
        append(0, to: &frame)
        frame.append(payload)
        frameSequence &+= 1
        try await send(frame)
    }

    private func readFrame() async throws -> (magic: UInt32, sequence: UInt32, payload: Data) {
        let header = try await readExactly(16)
        let length = Int(readUInt32(header, at: 0))
        guard length >= 0, length <= 128 * 1024 * 1024 else {
            throw TunnelError(message: "nieprawidłowa ramka tunelu X2D")
        }
        return (readUInt32(header, at: 4), readUInt32(header, at: 8), try await readExactly(length))
    }

    private func readJSONFrame() async throws -> [String: Any] {
        let payload = try await readFrame().payload
        return try splitJSONAndBinary(payload).0
    }

    private func splitJSONAndBinary(_ data: Data) throws -> ([String: Any], Data) {
        guard let end = jsonPrefixEnd(data),
              let object = try JSONSerialization.jsonObject(with: data.prefix(end)) as? [String: Any] else {
            throw TunnelError(message: "nieprawidłowa odpowiedź JSON z X2D")
        }
        var binaryStart = end
        if data.count >= end + 2, data[end..<(end + 2)] == Data([10, 10]) { binaryStart += 2 }
        else if data.count >= end + 4, data[end..<(end + 4)] == Data([13, 10, 13, 10]) { binaryStart += 4 }
        return (object, data.subdata(in: binaryStart..<data.count))
    }

    private func jsonPrefixEnd(_ data: Data) -> Int? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for (index, byte) in data.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") { inString = true }
            else if byte == UInt8(ascii: "{") { depth += 1 }
            else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
        }
        return nil
    }

    private func send(_ data: Data) async throws {
        guard let connection else { throw TunnelError(message: "brak połączenia z tunelem X2D") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        while receiveBuffer.count < count {
            guard let connection else { throw TunnelError(message: "tunel X2D jest zamknięty") }
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(65536, count)) {
                    data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: TunnelError(message: "X2D zamknął tunel plików")) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            receiveBuffer.append(chunk)
        }
        let result = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(result)
    }

    private func close() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    private func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
        UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func bestMatch(in files: [RemoteFile], hint: String) -> RemoteFile? {
        guard !files.isEmpty else { return nil }
        let wanted = normalize(hint)
        return files.max { lhs, rhs in
            let ls = score(lhs, wanted: wanted), rs = score(rhs, wanted: wanted)
            return ls == rs ? lhs.time < rhs.time : ls < rs
        }
    }

    private static func score(_ file: RemoteFile, wanted: String) -> Int {
        let candidate = normalize(file.name + file.path)
        if candidate == wanted { return 1000 }
        if !wanted.isEmpty, candidate.contains(wanted) || wanted.contains(candidate) { return 700 }
        let tokens = Set(wanted.split(separator: "_"))
        return tokens.reduce(0) { $0 + (candidate.contains($1) ? 10 : 0) }
    }

    private static func normalize(_ value: String) -> String {
        var value = (value.removingPercentEncoding ?? value).lowercased()
        for suffix in [".gcode.3mf", ".3mf", ".gcode"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
        return value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "_")
    }
}
