import Foundation

/// Polls a Snapmaker printer's local HTTP API (port 8080, used by Luban) and reports status through
/// MQTTClient.Event, so PrinterStore treats Snapmaker like any other connection.
///
/// Snapmaker's auth is stateful, unlike PrusaLink/Moonraker:
///  1. `POST /api/v1/connect` returns a session token.
///  2. `GET /api/v1/status?token=…` returns 204 until the user taps **Allow** on the printer's
///     touchscreen, then 200 with the live status. The token is dropped when the printer powers off.
///  3. The token has to be pinged regularly (our 2 s status poll doubles as the keep-alive).
///
/// We keep the token in memory for the life of the connection and keep polling through the 204
/// "awaiting authorization" phase, so the printer only shows a single Allow dialog.
final class SnapmakerClient: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private var task: Task<Void, Never>?
    private var telemetry = PrinterTelemetry()
    private var token: String?
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

    private var baseURL: String { "http://\(printer.host):\(printer.port ?? 8080)" }

    private func run() async {
        while !Task.isCancelled {
            do {
                if token == nil { token = try await connect() }
                guard let token else { try? await Task.sleep(for: .seconds(2)); continue }

                let (data, code) = try await get("\(baseURL)/api/v1/status?token=\(token)")
                switch code {
                case 200:
                    // A stale token still answers 200 with a plain-text "not connected" body.
                    if let text = String(data: data, encoding: .utf8),
                       text.localizedCaseInsensitiveContains("not connected") {
                        self.token = nil
                        break
                    }
                    if let updated = SnapmakerStatusParser.telemetry(status: data, previous: telemetry) {
                        telemetry = updated
                        if !connectedReported { connectedReported = true; onEvent(.connected) }
                        onEvent(.telemetry(updated))
                    }
                case 204:
                    break   // waiting for the user to tap Allow on the printer — keep polling
                case 401, 403:
                    reportDisconnected("Połączenie odrzucone na drukarce Snapmaker")
                    return
                default:
                    self.token = nil   // re-handshake on anything unexpected
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

    /// POSTs to /api/v1/connect and returns the fresh session token.
    private func connect() async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/v1/connect") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()   // empty body asks the printer for a new token
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["token"] as? String, !token.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private func get(_ urlString: String) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, code)
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        onEvent(.disconnected(reason))
    }
}
