import Foundation

/// Polls a Prusa printer's local PrusaLink HTTP API and reports status through MQTTClient.Event, so
/// PrinterStore treats Prusa like any other connection. Local only (IP + API key), no Prusa account.
final class PrusaLinkClient: PrinterConnection, @unchecked Sendable {
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

    private var baseURL: String { "http://\(printer.host):\(printer.port ?? 80)" }

    private func run() async {
        while !Task.isCancelled {
            do {
                let statusData = try await get("\(baseURL)/api/v1/status")
                let jobData = try? await get("\(baseURL)/api/v1/job")   // file name; absent when idle
                if let updated = PrusaLinkStatusParser.telemetry(status: statusData, job: jobData, previous: telemetry) {
                    telemetry = updated
                    if !connectedReported { connectedReported = true; onEvent(.connected) }
                    onEvent(.telemetry(updated))
                }
            } catch is CancellationError {
                return
            } catch {
                reportDisconnected(error.localizedDescription)
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key = printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        onEvent(.disconnected(reason))
    }
}
