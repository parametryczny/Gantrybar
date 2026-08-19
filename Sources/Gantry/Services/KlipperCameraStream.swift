import Foundation

/// Camera for Klipper/Moonraker printers by polling the webcam's JPEG snapshot. Moonraker publishes
/// configured cameras at `/server/webcams/list` (snapshot_url / stream_url); we discover the snapshot
/// URL there and fall back to the common crowsnest default. Polling snapshots (rather than parsing an
/// MJPEG multipart stream) keeps it simple and robust across setups.
final class KlipperCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, streaming, failed(String) }

    private let host: String
    private let port: Int
    private let apiKey: String?
    private let onFrame: @Sendable (Data) -> Void
    private let onState: @Sendable (State) -> Void
    private var task: Task<Void, Never>?

    init(host: String, port: Int, apiKey: String?,
         onFrame: @escaping @Sendable (Data) -> Void,
         onState: @escaping @Sendable (State) -> Void) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.onFrame = onFrame
        self.onState = onState
    }

    func start() {
        task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
    }

    func stop() { task?.cancel() }

    private func run() async {
        onState(.connecting)
        guard let snapshotURL = await discoverSnapshotURL() else {
            onState(.failed("Brak skonfigurowanej kamery"))
            return
        }
        var everSucceeded = false
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: snapshotURL)
                request.timeoutInterval = 6
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
                let (data, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                    everSucceeded = true
                    onFrame(data)
                    onState(.streaming)
                } else if !everSucceeded {
                    onState(.failed("Kamera nie odpowiada"))
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                if !everSucceeded { onState(.failed(error.localizedDescription)); return }
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    private func discoverSnapshotURL() async -> URL? {
        let moonraker = "http://\(host):\(port)"
        if let listURL = URL(string: "\(moonraker)/server/webcams/list") {
            var request = URLRequest(url: listURL)
            if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let webcams = (root["result"] as? [String: Any])?["webcams"] as? [[String: Any]],
               let first = webcams.first {
                let raw = (first["snapshot_url"] as? String) ?? (first["stream_url"] as? String)
                if let raw, let url = absoluteURL(raw) { return url }
            }
        }
        // Crowsnest / mjpg-streamer default (served on port 80, not the Moonraker port).
        return URL(string: "http://\(host)/webcam/?action=snapshot")
    }

    /// Webcam URLs from Moonraker are often relative (`/webcam/?action=snapshot`) and served on the
    /// printer's web port (80), not the Moonraker API port.
    private func absoluteURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        let path = raw.hasPrefix("/") ? raw : "/\(raw)"
        // A stream URL points at an MJPEG stream; turn it into a snapshot where we can.
        let snapshot = path.replacingOccurrences(of: "action=stream", with: "action=snapshot")
        return URL(string: "http://\(host)\(snapshot)")
    }
}
