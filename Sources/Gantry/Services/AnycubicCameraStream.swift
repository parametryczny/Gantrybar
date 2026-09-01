import Foundation

/// Decodes the Kobra S1 HTTP/FLV stream to JPEG frames. Release bundles may include ffmpeg next to
/// Gantry; development builds also use a Homebrew ffmpeg when available and fail gracefully otherwise.
final class AnycubicCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, streaming, failed(String) }
    private let url: URL, onFrame: @Sendable (Data) -> Void, onState: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "pl.gantry.anycubic.camera", qos: .utility)
    private var process: Process?; private var stopped = false
    init(url: URL, onFrame: @escaping @Sendable (Data) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.url = url; self.onFrame = onFrame; self.onState = onState
    }
    func start() { queue.async { [weak self] in self?.run() } }
    func stop() { queue.async { [weak self] in self?.stopped = true; self?.process?.terminate(); self?.process = nil } }
    private func run() {
        onState(.connecting)
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onState(.failed("Kamera Kobra S1 wymaga ffmpeg (brew install ffmpeg).")); return
        }
        let process = Process(), stdout = Pipe(), stderr = Pipe(); self.process = process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-loglevel", "error", "-i", url.absoluteString, "-an", "-f", "image2pipe", "-vcodec", "mjpeg", "-q:v", "5", "-"]
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { onState(.failed(error.localizedDescription)); return }
        var buffer = Data(); buffer.reserveCapacity(512_000); var announced = false
        while !stopped {
            let chunk = stdout.fileHandleForReading.readData(ofLength: 16_384); if chunk.isEmpty { break }; buffer.append(chunk)
            while let start = buffer.range(of: Data([0xFF, 0xD8])),
                  let end = buffer.range(of: Data([0xFF, 0xD9]), in: start.lowerBound..<buffer.endIndex) {
                onFrame(buffer.subdata(in: start.lowerBound..<end.upperBound)); buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                if !announced { announced = true; onState(.streaming) }
            }
            if buffer.count > 4_000_000 { buffer.removeFirst(buffer.count - 1_000_000) }
        }
        if !stopped {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            onState(.failed(detail?.isEmpty == false ? detail! : "Strumień FLV został zakończony."))
        }
    }
}
