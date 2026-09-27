import Foundation

/// Polls an OctoPrint server's REST API and reports status through MQTTClient.Event, so PrinterStore
/// treats it like Moonraker and PrusaLink. Also sends the controls: G-code lines, pause, resume, cancel.
/// Local only: host (usually OctoPi on port 80) and an API key from OctoPrint's settings.
final class OctoPrintClient: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private var task: Task<Void, Never>?
    private var telemetry = PrinterTelemetry()
    private var connectedReported = false
    private var disconnectReported = false

    init(printer: SavedPrinter, onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer
        self.onEvent = onEvent
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
    }

    func stop() { task?.cancel() }

    static func baseURL(for printer: SavedPrinter) -> String { "http://\(printer.host):\(printer.port ?? 80)" }
    private var baseURL: String { Self.baseURL(for: printer) }

    private func run() async {
        while !Task.isCancelled {
            do {
                let (printerData, status) = try await get("\(baseURL)/api/printer")
                if status == 401 || status == 403 {
                    reportDisconnected(Localization.t("OctoPrint refused the API key."))
                    return
                }
                let jobData = try? await get("\(baseURL)/api/job").0
                // 409: OctoPrint is up but has no printer connected; report it as offline, keep polling.
                telemetry = OctoPrintStatusParser.telemetry(printer: status == 200 ? printerData : nil,
                                                            job: jobData, previous: telemetry)
                if !connectedReported { connectedReported = true; onEvent(.connected) }
                onEvent(.telemetry(telemetry))
            } catch is CancellationError {
                return
            } catch {
                reportDisconnected(error.localizedDescription)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func get(_ urlString: String) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key = printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 409 || status == 401 || status == 403 else { throw URLError(.badServerResponse) }
        return (data, status)
    }

    /// One or more G-code lines, sent as a batch so a relative move and the G90 after it stay together.
    func sendGcode(_ lines: [String]) {
        post("/api/printer/command", body: ["commands": lines])
    }

    enum JobAction: String { case pause, resume, cancel }

    func job(_ action: JobAction) {
        switch action {
        case .pause, .resume: post("/api/job", body: ["command": "pause", "action": action.rawValue])
        case .cancel: post("/api/job", body: ["command": "cancel"])
        }
    }

    private func post(_ path: String, body: [String: Any]) {
        let printer = self.printer
        guard let url = URL(string: Self.baseURL(for: printer) + path),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        onEvent(.disconnected(reason))
    }
}
