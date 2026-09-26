import Foundation
import CoreMedia
import VideoToolbox
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Grabs a single still frame from a printer's camera and returns it as JPEG, for the Telegram bot's
/// /photo. Bambu streams H.264 over RTSP, so we decode one keyframe with VideoToolbox; Klipper and Elegoo
/// stream MJPEG, so we just take the first frame. Best-effort, with a timeout. Not used for the live view.
enum CameraSnapshot {
    /// A frame for something running in the background, without taking the camera off whoever is
    /// watching it.
    ///
    /// A printer camera accepts one client at a time. A second connection does not get a second copy
    /// of the picture, it takes the first one away, so a snapshot taken while the edge panel or
    /// Details is showing the live view leaves the user staring at "No picture". Anything on a timer
    /// goes through here, and it gets its frame from the stream already running:
    ///
    /// - a preview that holds ready-made pictures (Klipper, Elegoo, the P1/A1 JPEG stream) hands one
    ///   straight over;
    /// - a Bambu RTSP preview hands over its last H.264 keyframe, decoded here, off the main thread,
    ///   because the display layer takes pixels and gives none back;
    /// - and only when nobody is watching at all does this open a connection of its own.
    ///
    /// `capture` below stays for the cases the user asked for directly, where taking the camera for
    /// a moment is the whole point.
    /// Where a frame came from. Two streams of the same printer do not frame the same picture: the
    /// P1/A1 JPEG feed and the RTSP feed differ in field of view, so a frame from one cannot be
    /// compared with a frame from the other. Anything that compares frames over time has to know
    /// when the source changed and start again, or it reads the change of camera as a change of
    /// print. That is exactly what happened: the fleet reported layer shifts of seven pixels one way
    /// and eight the other between two frames minutes apart, which no fixed camera can do.
    enum Source: Equatable { case livePreview, liveKeyframe, snapshotRTSP, snapshotJPEG, other }

    @MainActor
    static func latestFrame(printer: SavedPrinter, store: PrinterStore,
                            timeout: TimeInterval = 12) async -> (jpeg: Data, source: Source)? {
        guard CameraFeedController.isLive(serial: printer.serial) else {
            guard let jpeg = await capture(printer: printer, store: store, timeout: timeout) else { return nil }
            let source: Source = switch bambuTransports[cameraHost(printer, store)] {
            case .rtsp: .snapshotRTSP
            case .jpeg: .snapshotJPEG
            case nil: .other
            }
            return (jpeg, printer.kind == .bambu ? source : .other)
        }
        if let ready = CameraFeedController.liveFrameJPEG(serial: printer.serial) {
            return (ready, .livePreview)
        }
        guard let keyframe = CameraFeedController.liveKeyframe(serial: printer.serial) else { return nil }
        let avcc = keyframe.avcc
        let format = keyframe.format
        guard let jpeg = await Task.detached(priority: .utility, operation: {
            decodeKeyframe(avcc: avcc, format: format)
        }).value else { return nil }
        return (jpeg, .liveKeyframe)
    }

    @MainActor
    static func capture(printer: SavedPrinter, store: PrinterStore, timeout: TimeInterval = 12) async -> Data? {
        let host = cameraHost(printer, store)
        switch printer.kind {
        case .bambu:
            guard let code = store.accessCode(for: printer.serial), !code.isEmpty else { return nil }
            return await captureBambu(host: host, accessCode: code, timeout: timeout)
        case .klipper:
            let url = "http://\(host):\(printer.port ?? 7125)/webcam/?action=stream"
            return await captureMJPEG(url: url, apiKey: store.accessCode(for: printer.serial), timeout: timeout)
        case .elegooCC1, .elegooCC2:
            let isCC2 = printer.kind == .elegooCC2
            let url = isCC2 ? "http://\(host):8080/?action=stream" : "http://\(host):3031/video"
            guard !isCC2, let gate = store.elegooVideoGate(serial: printer.serial) else {
                if isCC2 { store.sendElegooMethod(serial: printer.serial, method: 1042) }
                return await captureMJPEG(url: url, apiKey: nil, timeout: timeout)
            }
            // A snapshot is a viewer too: it shares the printer's single stream with an open live view and
            // gives it back afterwards instead of leaving the camera enabled.
            let ack = await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
                gate.acquire { cont.resume(returning: $0) }
            }
            defer { gate.release() }
            guard ElegooVideoGate.refusalMessage(ack: ack) == nil else { return nil }
            return await captureMJPEG(url: url, apiKey: nil, timeout: timeout)
        case .anycubicKobraS1:
            return await captureAnycubic(host: host, timeout: timeout)
        default:
            return nil
        }
    }

    private static func captureAnycubic(host: String, timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: "http://\(host):18088/flv") else { return nil }
        let collector = AnycubicCollector()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            collector.onResult = { continuation.resume(returning: $0) }
            let stream = AnycubicCameraStream(url: url, onFrame: { collector.finish($0) }, onState: { state in
                if case .failed = state { collector.finish(nil) }
            })
            collector.stream = stream; stream.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish(nil) }
        }
    }

    /// Takes the first frame off a stream that already sends pictures, then shuts it down. Used by
    /// the Kobra's FLV feed and by the P1/A1 JPEG feed: both answer with a whole image, so there is
    /// nothing to decode and the first one that arrives is the snapshot.
    private final class AnycubicCollector: @unchecked Sendable {
        var stream: AnycubicCameraStream?
        var jpegStream: BambuJPEGCameraStream?
        var onResult: ((Data?) -> Void)?
        private let lock = NSLock(); private var done = false
        func finish(_ data: Data?) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let callback = onResult; onResult = nil
            lock.unlock()
            stream?.stop(); stream = nil
            jpegStream?.stop(); jpegStream = nil
            callback?(data)
        }
    }

    @MainActor
    private static func cameraHost(_ printer: SavedPrinter, _ store: PrinterStore) -> String {
        let override = PrinterOverridesStore.shared.overrides(for: printer.serial).cameraHost
        return (override?.isEmpty == false) ? override! : printer.host
    }

    // MARK: Bambu (H.264 → decode one keyframe)

    /// A still from a Bambu camera: RTSP first, then the port-6000 JPEG stream.
    ///
    /// The live preview has had that second step since the P1 and A1 turned out to have no RTSP
    /// endpoint at all; this did not, so a snapshot of a P1S or an A1 mini spent twelve seconds
    /// timing out and came back with nothing. Telegram's /photo was silently blank for those
    /// machines, and the defect watcher never once looked at them. Measured on the fleet: with the
    /// fallback in place both answer with a frame.
    private enum BambuTransport { case rtsp, jpeg }

    /// Which way each camera answered last time.
    ///
    /// Without it a P1S spends half its budget waiting for an RTSP endpoint it has never had, and on
    /// a twenty second watch interval that was enough to make most rounds come back empty: measured
    /// one frame in four. A printer does not change which stream it speaks, so remembering the answer
    /// costs one dictionary and makes every round after the first go straight to the right one.
    @MainActor private static var bambuTransports: [String: BambuTransport] = [:]

    @MainActor
    private static func captureBambu(host: String, accessCode: String, timeout: TimeInterval) async -> Data? {
        let known = bambuTransports[host]
        let order: [BambuTransport] = known == .jpeg ? [.jpeg, .rtsp] : [.rtsp, .jpeg]
        for transport in order {
            // The stream we already know this camera speaks gets the whole budget. Splitting it in
            // half was measured to be too little for the P1/A1 feed, which has a handshake and an
            // authentication step before its first whole picture: one frame in five came back.
            let budget = transport == known ? timeout : timeout / 2
            let frame = switch transport {
            case .rtsp: await captureBambuRTSP(host: host, accessCode: accessCode, timeout: budget)
            case .jpeg: await captureBambuJPEG(host: host, accessCode: accessCode, timeout: budget)
            }
            if let frame {
                bambuTransports[host] = transport
                return frame
            }
        }
        return nil
    }

    /// The P1/A1 stream: already JPEG, so the first frame is the answer.
    private static func captureBambuJPEG(host: String, accessCode: String, timeout: TimeInterval) async -> Data? {
        let collector = AnycubicCollector()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            collector.onResult = { continuation.resume(returning: $0) }
            let stream = BambuJPEGCameraStream(
                host: host, accessCode: accessCode,
                onState: { state in if case .failed = state { collector.finish(nil) } },
                onFrame: { collector.finish($0) })
            collector.jpegStream = stream
            stream.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish(nil) }
        }
    }

    private static func captureBambuRTSP(host: String, accessCode: String, timeout: TimeInterval) async -> Data? {
        let collector = BambuCollector()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            collector.onResult = { cont.resume(returning: $0) }
            let stream = RTSPCameraStream(
                host: host, accessCode: accessCode,
                onState: { _ in },
                onParameterSets: { sps, pps in collector.setParameters(sps: sps, pps: pps) },
                onAccessUnit: { avcc, keyframe in collector.feed(avcc: avcc, keyframe: keyframe) }
            )
            collector.stream = stream
            stream.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish(nil) }
        }
    }

    /// Collects SPS/PPS + the first keyframe, decodes it to JPEG, and resumes exactly once (or on timeout).
    private final class BambuCollector: @unchecked Sendable {
        var stream: RTSPCameraStream?
        var onResult: ((Data?) -> Void)?
        private let lock = NSLock()
        private var sps: Data?
        private var pps: Data?
        private var done = false

        func setParameters(sps: Data, pps: Data) {
            lock.lock(); self.sps = sps; self.pps = pps; lock.unlock()
        }

        func feed(avcc: Data, keyframe: Bool) {
            lock.lock()
            let ready = keyframe && !done, s = sps, p = pps
            lock.unlock()
            guard ready, let s, let p else { return }
            if let jpeg = decode(sps: s, pps: p, avcc: avcc) { finish(jpeg) }
        }

        func finish(_ data: Data?) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let callback = onResult; onResult = nil
            lock.unlock()
            stream?.stop(); stream = nil
            callback?(data)
        }
    }

    private static func decode(sps: Data, pps: Data, avcc: Data) -> Data? {
        guard let format = makeFormat(sps: sps, pps: pps) else { return nil }
        return decodeKeyframe(avcc: avcc, format: format)
    }

    /// One self-contained H.264 keyframe into a JPEG.
    ///
    /// Shared with the live preview, which keeps its most recent keyframe exactly so that a still can
    /// be produced from a stream already running instead of opening a second connection the camera
    /// will not grant. A keyframe decodes on its own; anything else would need the frames before it.
    nonisolated static func decodeKeyframe(avcc: Data, format: CMFormatDescription) -> Data? {
        guard let sample = makeSampleBuffer(avcc: avcc, format: format) else { return nil }
        var session: VTDecompressionSession?
        let imageAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: imageAttrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        var jpeg: Data?
        let sem = DispatchSemaphore(value: 0)
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableTemporalProcessing],
                                          infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            defer { sem.signal() }
            guard status == noErr, let imageBuffer else { return }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
            if let cgImage { jpeg = encodeJPEG(cgImage) }
        }
        _ = sem.wait(timeout: .now() + 6)
        return jpeg
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMFormatDescription? {
        var format: CMFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!, parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                    }
                }
            }
        }
        return format
    }

    private static func makeSampleBuffer(avcc: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        let length = avcc.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: MJPEG (Klipper / Elegoo — take the first JPEG frame)

    private static func captureMJPEG(url: String, apiKey: String?, timeout: TimeInterval) async -> Data? {
        guard let parsed = URL(string: url) else { return nil }
        let collector = FrameCollector()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            collector.onResult = { cont.resume(returning: $0) }
            let stream = MJPEGReader(url: parsed, apiKey: apiKey) { data in collector.finish(data) }
            collector.reader = stream
            stream.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish(nil) }
        }
    }

    private final class FrameCollector: @unchecked Sendable {
        var reader: MJPEGReader?
        var onResult: ((Data?) -> Void)?
        private let lock = NSLock()
        private var done = false
        func finish(_ data: Data?) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let callback = onResult; onResult = nil
            lock.unlock()
            reader?.stop(); reader = nil
            callback?(data)
        }
    }
}

/// A tiny MJPEG reader that returns just the first complete JPEG frame (SOI…EOI), then can be stopped.
/// Standalone so it doesn't disturb the live-view Klipper/Elegoo streams.
final class MJPEGReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let apiKey: String?
    private let onFrame: (Data) -> Void
    private var session: URLSession?
    private var buffer = Data()
    private let lock = NSLock()

    init(url: URL, apiKey: String?, onFrame: @escaping (Data) -> Void) {
        self.url = url; self.apiKey = apiKey; self.onFrame = onFrame
    }

    func start() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func stop() { session?.invalidateAndCancel(); session = nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); buffer.append(data)
        // JPEG frame = FF D8 (SOI) … FF D9 (EOI).
        guard let start = buffer.firstRange(of: Data([0xFF, 0xD8])),
              let end = buffer.firstRange(of: Data([0xFF, 0xD9]), in: start.lowerBound..<buffer.endIndex) else {
            lock.unlock(); return
        }
        let frame = buffer.subdata(in: start.lowerBound..<end.upperBound)
        lock.unlock()
        onFrame(frame)
    }
}

private extension Data {
    func firstRange(of pattern: Data, in range: Range<Index>) -> Range<Index>? {
        self.range(of: pattern, options: [], in: range)
    }
}
