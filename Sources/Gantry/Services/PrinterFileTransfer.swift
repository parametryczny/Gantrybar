import Foundation

/// Sends a sliced file to a printer that takes plain HTTP uploads, and starts it: Klipper (Moonraker),
/// PrusaLink and OctoPrint. Bambu Lab goes over FTPS instead (BambuFileClient). Uploading never starts
/// a print by itself; `start` is a separate, explicit call.
enum PrinterFileTransfer {
    struct TransferError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func supports(_ kind: PrinterKind) -> Bool {
        kind == .klipper || kind == .prusa || kind == .octoprint
    }

    /// File extensions a printer can print from the library: Bambu takes sliced 3MF projects, the
    /// others G-code, and PrusaLink Prusa's binary G-code too.
    static func accepts(_ kind: PrinterKind, fileExtension: String) -> Bool {
        switch fileExtension.lowercased() {
        case "3mf": kind == .bambu
        case "gcode", "gco", "g": supports(kind)
        case "bgcode": kind == .prusa
        default: false
        }
    }

    static func upload(printer: SavedPrinter, apiKey: String?, file: URL, remoteName: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let base: String
        var request: URLRequest
        switch printer.kind {
        case .klipper:
            base = "http://\(printer.host):\(printer.port ?? 7125)"
            request = try multipart(url: base + "/server/files/upload", file: file, remoteName: remoteName,
                                    fields: ["root": "gcodes"])
        case .octoprint:
            base = OctoPrintClient.baseURL(for: printer)
            request = try multipart(url: base + "/api/files/local", file: file, remoteName: remoteName,
                                    fields: ["select": "false", "print": "false"])
        case .prusa:
            base = "http://\(printer.host):\(printer.port ?? 80)"
            let name = remoteName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteName
            guard let url = URL(string: base + "/api/v1/files/usb/" + name) else { throw TransferError(message: Localization.t("The printer address is not valid.")) }
            request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("?0", forHTTPHeaderField: "Print-After-Upload")
            request.setValue("?1", forHTTPHeaderField: "Overwrite-File")
            request.httpBody = try Data(contentsOf: file, options: .mappedIfSafe)
        default:
            throw TransferError(message: Localization.t("This printer cannot receive files from Gantry."))
        }
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        request.timeoutInterval = 600
        try await send(request, progress: progress)
    }

    static func start(printer: SavedPrinter, apiKey: String?, remoteName: String) async throws {
        var request: URLRequest
        switch printer.kind {
        case .klipper:
            var parts = URLComponents(string: "http://\(printer.host):\(printer.port ?? 7125)/printer/print/start")
            parts?.queryItems = [URLQueryItem(name: "filename", value: remoteName)]
            guard let url = parts?.url else { throw TransferError(message: Localization.t("The printer address is not valid.")) }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
        case .octoprint:
            let name = remoteName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteName
            guard let url = URL(string: OctoPrintClient.baseURL(for: printer) + "/api/files/local/" + name) else {
                throw TransferError(message: Localization.t("The printer address is not valid."))
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["command": "select", "print": true])
        case .prusa:
            let name = remoteName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteName
            guard let url = URL(string: "http://\(printer.host):\(printer.port ?? 80)/api/v1/files/usb/" + name) else {
                throw TransferError(message: Localization.t("The printer address is not valid."))
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
        default:
            throw TransferError(message: Localization.t("This printer cannot receive files from Gantry."))
        }
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        request.timeoutInterval = 15
        try await send(request, progress: { _ in })
    }

    private static func multipart(url: String, file: URL, remoteName: String, fields: [String: String]) throws -> URLRequest {
        guard let target = URL(string: url) else { throw TransferError(message: Localization.t("The printer address is not valid.")) }
        let boundary = "gantry-\(UUID().uuidString)"
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        let safeName = remoteName.replacingOccurrences(of: "\"", with: "")
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"")
        line("Content-Type: application/octet-stream")
        line("")
        body.append(try Data(contentsOf: file, options: .mappedIfSafe))
        line("")
        line("--\(boundary)--")
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = request
        let body = request.httpBody ?? Data()
        request.httpBody = nil
        let delegate = UploadProgress(progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw TransferError(message: Localization.t("The printer refused the API key.")) }
        guard (200..<300).contains(code) else {
            let detail = String(data: data.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TransferError(message: Localization.t("The printer answered with HTTP {0}.", code) + (detail.isEmpty ? "" : " " + detail))
        }
        progress(1)
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
