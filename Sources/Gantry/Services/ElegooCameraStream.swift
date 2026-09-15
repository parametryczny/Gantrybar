import Foundation

final class ElegooCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, streaming, failed(String) }
    /// A printer that has just been told to start its camera can take a moment to serve it, so a stream
    /// that has not produced a picture yet is retried a few times before the failure is shown.
    private static let attemptsBeforeFailing = 3
    private let url: URL
    private let onFrame: @Sendable (Data) -> Void
    private let onState: @Sendable (State) -> Void
    private var task: Task<Void, Never>?

    init(url: URL, onFrame: @escaping @Sendable (Data) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.url = url; self.onFrame = onFrame; self.onState = onState
    }
    func start() { task = Task.detached(priority: .utility) { [weak self] in await self?.run() } }
    func stop() { task?.cancel(); task = nil }

    private func run() async {
        onState(.connecting)
        var delivered = false
        for attempt in 1... {
            let failure: String
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                // Frames are cut as bytes arrive. Searching the whole buffer again for every byte made a
                // 100 KB frame cost billions of comparisons, far slower than the camera sends them.
                var splitter = MJPEGFrameSplitter()
                for try await byte in bytes {
                    guard let frame = splitter.push(byte) else { continue }
                    delivered = true
                    onFrame(JPEGHuffman.ensureTables(frame)); onState(.streaming)
                }
                if Task.isCancelled { return }
                failure = Localization.t("The camera stream ended.")
            } catch {
                if Task.isCancelled { return }
                failure = error.localizedDescription
            }
            // A stream that already showed pictures is the watchdog's to restart.
            guard !delivered, attempt < Self.attemptsBeforeFailing else { onState(.failed(failure)); return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
        }
    }
}
