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
            store.sendElegooMethod(serial: printer.serial, method: isCC2 ? 1042 : 386,
                                   params: isCC2 ? [:] : ["Enable": 1])
            let url = isCC2 ? "http://\(host):8080/?action=stream" : "http://\(host):3031/video"
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

    private final class AnycubicCollector: @unchecked Sendable {
        var stream: AnycubicCameraStream?; var onResult: ((Data?) -> Void)?
        private let lock = NSLock(); private var done = false
        func finish(_ data: Data?) { lock.lock(); if done { lock.unlock(); return }; done = true; let callback = onResult; onResult = nil; lock.unlock(); stream?.stop(); stream = nil; callback?(data) }
    }

    @MainActor
    private static func cameraHost(_ printer: SavedPrinter, _ store: PrinterStore) -> String {
        let override = PrinterOverridesStore.shared.overrides(for: printer.serial).cameraHost
        return (override?.isEmpty == false) ? override! : printer.host
    }

    // MARK: Bambu (H.264 → decode one keyframe)

    private static func captureBambu(host: String, accessCode: String, timeout: TimeInterval) async -> Data? {
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
        guard let format = makeFormat(sps: sps, pps: pps),
              let sample = makeSampleBuffer(avcc: avcc, format: format) else { return nil }
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
