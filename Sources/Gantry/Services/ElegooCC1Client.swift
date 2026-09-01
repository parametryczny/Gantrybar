import Foundation

final class ElegooCC1Client: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private let queue: DispatchQueue
    private var task: URLSessionWebSocketTask?
    private var statusTimer: DispatchSourceTimer?
    private var telemetry = PrinterTelemetry()
    private var stopped = false

    init(printer: SavedPrinter, onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer; self.onEvent = onEvent
        queue = DispatchQueue(label: "pl.gantry.elegoo.cc1.\(printer.serial)")
    }

    func start() { queue.async { [weak self] in self?.connect() } }
    func stop() { queue.async { [weak self] in
        self?.stopped = true; self?.statusTimer?.cancel(); self?.statusTimer = nil
        self?.task?.cancel(with: .goingAway, reason: nil); self?.task = nil
    } }

    func sendMethod(_ command: Int, data: [String: Any] = [:]) {
        guard let parameters = try? JSONSerialization.data(withJSONObject: data) else { return }
        queue.async { [weak self] in
            guard let self, let task else { return }
            let decoded = (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? [:]
            let request: [String: Any] = [
                "Id": printer.serial,
                "Data": ["Cmd": command, "Data": decoded, "RequestID": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                         "MainboardID": printer.serial, "TimeStamp": Int(Date().timeIntervalSince1970 * 1000), "From": 1],
                "Topic": "sdcp/request/\(printer.serial)"
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: request), let text = String(data: json, encoding: .utf8) else { return }
            task.send(.string(text)) { _ in }
        }
    }

    private func connect() {
        stopped = false
        guard let url = URL(string: "ws://\(printer.host):\(printer.port ?? 3030)/websocket") else { return }
        let task = URLSession.shared.webSocketTask(with: url); self.task = task; task.resume()
        onEvent(.connected); sendMethod(0); sendMethod(1); sendMethod(512, data: ["TimePeriod": 5000]); startStatusTimer(); receive()
    }

    private func startStatusTimer() {
        statusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.sendMethod(0) }
        timer.resume(); statusTimer = timer
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    self.statusTimer?.cancel(); self.statusTimer = nil
                    if !self.stopped { self.onEvent(.disconnected(error.localizedDescription)) }
                case .success(let message):
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: data = Data() }
                    if let updated = ElegooStatusParser.cc1(data: data, previous: self.telemetry) {
                        self.telemetry = updated; self.onEvent(.telemetry(updated))
                    }
                    if !self.stopped { self.receive() }
                }
            }
        }
    }
}
