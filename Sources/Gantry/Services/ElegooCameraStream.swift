import Foundation

final class ElegooCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, streaming, failed(String) }
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
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { onState(.failed("HTTP")); return }
            var buffer = Data(); buffer.reserveCapacity(256_000)
            for try await byte in bytes {
                if Task.isCancelled { return }
                buffer.append(byte)
                while let start = buffer.range(of: Data([0xFF, 0xD8])),
                      let end = buffer.range(of: Data([0xFF, 0xD9]), in: start.lowerBound..<buffer.endIndex) {
                    let frame = buffer.subdata(in: start.lowerBound..<end.upperBound)
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    onFrame(frame); onState(.streaming)
                }
                if buffer.count > 4_000_000 { buffer.removeFirst(buffer.count - 1_000_000) }
            }
        } catch is CancellationError { return }
        catch { onState(.failed(error.localizedDescription)) }
    }
}
