import Foundation

/// Polls a Klipper printer's Moonraker API and reports status through MQTTClient.Event, so
/// PrinterStore treats Klipper and Bambu connections identically. REST polling keeps the first
/// version simple; a WebSocket subscription can replace the loop later.
final class MoonrakerClient: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private var task: Task<Void, Never>?
    private var telemetry = PrinterTelemetry()
    private var connectedReported = false
    private var disconnectReported = false

    // Creality CFS lives on the printer's own WebSocket, not Moonraker; fed in on the side.
    private var cfsTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private let cfsLock = NSLock()
    private var cfsGroups: [FilamentGroup] = []
    private static let cfsRequest = "{\"method\":\"get\",\"params\":{\"boxsInfo\":1}}"

    private let objects: MoonrakerObjects

    init(printer: SavedPrinter, objects: MoonrakerObjects = .init(),
         onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer
        self.objects = objects
        self.onEvent = onEvent
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
        cfsTask = Task.detached(priority: .utility) { [weak self] in await self?.runCFS() }
    }

    func stop() {
        task?.cancel()
        cfsTask?.cancel()
        webSocket?.cancel(with: .goingAway, reason: nil)
    }

    /// Sends a raw G-code line (used by the detail card's controls and automations). Klipper macros
    /// like PAUSE / RESUME / CANCEL_PRINT go through here too.
    func sendGcode(_ script: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  var components = URLComponents(string: "\(self.baseURL)/printer/gcode/script") else { return }
            components.queryItems = [URLQueryItem(name: "script", value: script)]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            if let key = self.printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private var baseURL: String { "http://\(printer.host):\(printer.port ?? 7125)" }

    private func run() async {
        guard let queryURL = await buildQueryURL() else {
            reportDisconnected("Nie znaleziono API Moonraker (port \(printer.port ?? 7125))")
            return
        }
        while !Task.isCancelled {
            do {
                let data = try await get(queryURL)
                if var updated = MoonrakerStatusParser.telemetry(from: data, previous: telemetry, objects: objects) {
                    // A Creality CFS overrides the (absent) Happy Hare gates with its own modules.
                    let cfs = currentCFSGroups()
                    if !cfs.isEmpty {
                        updated.filamentGroups = cfs
                        updated.amsSlots = cfs.flatMap(\.legacyAMSSlots)
                    }
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

    /// Query only objects the printer actually exposes, so Moonraker doesn't reject the request,
    /// and pick up any chamber temperature sensor and the MMU object if present.
    private func buildQueryURL() async -> URL? {
        var wanted = ["print_stats", "virtual_sdcard", "display_status", "mmu", "gcode_move",
                      objects.nozzle, objects.bed, objects.fan]
        if let chamber = objects.chamber { wanted.append(chamber) }
        wanted = Array(Set(wanted))
        if let listURL = URL(string: "\(baseURL)/printer/objects/list"),
           let data = try? await get(listURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let objects = (root["result"] as? [String: Any])?["objects"] as? [String] {
            let available = Set(objects)
            wanted = wanted.filter { available.contains($0) }
            for object in objects where object.lowercased().contains("chamber")
                && (object.hasPrefix("temperature_sensor") || object.hasPrefix("heater_generic")) {
                wanted.append(object)
            }
        }
        guard !wanted.isEmpty else { return nil }
        var components = URLComponents(string: "\(baseURL)/printer/objects/query")
        components?.queryItems = wanted.map { URLQueryItem(name: $0, value: nil) }
        return components?.url
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let key = printer.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func currentCFSGroups() -> [FilamentGroup] {
        cfsLock.lock(); defer { cfsLock.unlock() }
        return cfsGroups
    }

    private func setCFSGroups(_ groups: [FilamentGroup]) {
        cfsLock.lock(); cfsGroups = groups; cfsLock.unlock()
    }

    /// Best-effort Creality CFS reader. Connects to the printer's `ws://host:9999`, asks for
    /// `boxsInfo`, and maps any material boxes to AMS slots. Klipper printers without a CFS (Voron,
    /// stock Moonraker) simply never answer on that port, so this backs off and stays idle.
    private func runCFS() async {
        guard let url = URL(string: "ws://\(printer.host):9999") else { return }
        while !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: url)
            webSocket = socket
            socket.resume()

            let requester = Task { [weak self] in
                while !Task.isCancelled {
                    try? await self?.webSocket?.send(.string(MoonrakerClient.cfsRequest))
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let payload: Data?
                    switch message {
                    case .string(let text): payload = text.data(using: .utf8)
                    case .data(let data): payload = data
                    @unknown default: payload = nil
                    }
                    if let payload, let groups = MoonrakerStatusParser.parseCFSGroups(from: payload) {
                        setCFSGroups(groups)
                    }
                }
            } catch {
                // Connection refused/closed — expected on non-Creality printers.
            }
            requester.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            webSocket = nil
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(30))   // gentle retry; don't hammer a closed port
        }
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        onEvent(.disconnected(reason))
    }
}
