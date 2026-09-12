import AppKit
import AVFoundation
import CoreMedia

/// One live camera feed, with everything needed to run it: the per-brand stream setup, the Bambu
/// RTSP-to-JPEG fallback chain, the "no frame arrived" timeout and teardown.
///
/// This used to live inside `PrinterDetailViewController`, which made the camera reachable from
/// exactly one surface. It is a separate owner now so any surface can show the same feed without
/// copying the protocol matrix: give it a store and a serial, put its `view` somewhere, and call
/// `start()` / `stop()` as that surface appears and disappears.
///
/// One controller drives one feed. A surface that wants two printers side by side creates two.
@MainActor
final class CameraFeedController {
    let view = CameraView()

    private let store: PrinterStore
    private let serial: String

    private var stream: RTSPCameraStream?
    /// P1/A1 fallback: those machines have no RTSP endpoint, only the port-6000 JPEG stream.
    private var jpegStream: BambuJPEGCameraStream?
    private var klipperStream: KlipperCameraStream?
    private var elegooStream: ElegooCameraStream?
    private var anycubicStream: AnycubicCameraStream?
    private var timeout: DispatchWorkItem?
    private var receivedFrame = false

    /// True between `start()` and `stop()`, so a surface can avoid restarting a feed it already runs.
    private(set) var isRunning = false

    init(store: PrinterStore, serial: String) {
        self.store = store
        self.serial = serial
    }

    deinit { stream?.stop() }

    static var unavailableText: String {
        AppSettings.shared.t("No camera preview.\nEnable “LAN Only Mode” on the printer — the local stream\nis unavailable while the printer is cloud-connected.")
    }

    /// Brands with a local stream Gantry can decode. One definition for every surface, so a new
    /// surface cannot end up offering a camera the feed has no protocol for.
    /// Takes an optional so callers holding a printer that may not exist any more need no dance.
    static func supportsCamera(_ kind: PrinterKind?) -> Bool {
        switch kind {
        case .bambu, .klipper, .elegooCC1, .elegooCC2, .anycubicKobraS1: true
        default: false
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let printer = store.printers.first(where: { $0.serial == serial }) else { return }
        isRunning = true
        receivedFrame = false
        switch printer.kind {
        case .bambu: startBambuCamera(printer)
        case .klipper: startKlipperCamera(printer)
        case .elegooCC1, .elegooCC2: startElegooCamera(printer)
        case .anycubicKobraS1: startAnycubicCamera(printer)
        default:
            isRunning = false
            return
        }
        // If no frame arrives in time, show a helpful fallback.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.receivedFrame else { return }
            self.view.showStatus(Self.unavailableText)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func stop() {
        isRunning = false
        timeout?.cancel()
        timeout = nil
        stream?.stop()
        stream = nil
        jpegStream?.stop()
        jpegStream = nil
        klipperStream?.stop()
        klipperStream = nil
        elegooStream?.stop()
        elegooStream = nil
        anycubicStream?.stop()
        anycubicStream = nil
    }

    /// Camera reachable on a separate IP (per-printer override) or the printer's own host.
    private func cameraHost(for printer: SavedPrinter) -> String {
        let override = PrinterOverridesStore.shared.overrides(for: serial).cameraHost
        return (override?.isEmpty == false) ? override! : printer.host
    }

    private func startBambuCamera(_ printer: SavedPrinter) {
        guard stream == nil, let code = store.accessCode(for: serial), !code.isEmpty else {
            view.showStatus(AppSettings.shared.t("Camera unavailable (no access code)"))
            return
        }
        view.showStatus(AppSettings.shared.t("Connecting to camera…"))
        let stream = RTSPCameraStream(
            host: cameraHost(for: printer),
            accessCode: code,
            onState: { state in Task { @MainActor [weak self] in self?.handleCameraState(state) } },
            onParameterSets: { sps, pps in Task { @MainActor [weak self] in self?.view.setParameterSets(sps: sps, pps: pps) } },
            onAccessUnit: { avcc, keyframe in Task { @MainActor [weak self] in self?.handleAccessUnit(avcc, keyframe: keyframe) } }
        )
        self.stream = stream
        stream.start()
    }

    private func startKlipperCamera(_ printer: SavedPrinter) {
        guard klipperStream == nil else { return }
        view.showStatus(AppSettings.shared.t("Connecting to camera…"))
        let stream = KlipperCameraStream(
            host: cameraHost(for: printer),
            port: printer.port ?? 7125,
            apiKey: store.accessCode(for: serial),
            onFrame: { data in Task { @MainActor [weak self] in self?.handleImageFrame(data) } },
            onState: { state in Task { @MainActor [weak self] in self?.handleKlipperState(state) } }
        )
        klipperStream = stream
        stream.start()
    }

    private func startElegooCamera(_ printer: SavedPrinter) {
        guard elegooStream == nil else { return }
        let isCC2 = printer.kind == .elegooCC2
        store.sendElegooMethod(serial: serial, method: isCC2 ? 1042 : 386,
                               params: isCC2 ? [:] : ["Enable": 1])
        let port = isCC2 ? 8080 : 3031
        let path = isCC2 ? "/?action=stream" : "/video"
        guard let url = URL(string: "http://\(cameraHost(for: printer)):\(port)\(path)") else { return }
        view.showStatus(AppSettings.shared.t("Connecting to camera…"))
        let stream = ElegooCameraStream(url: url,
            onFrame: { data in Task { @MainActor [weak self] in self?.handleImageFrame(data) } },
            onState: { state in Task { @MainActor [weak self] in
                if case .failed = state, self?.receivedFrame == false { self?.view.showStatus(Self.unavailableText) }
            } })
        elegooStream = stream; stream.start()
    }

    private func startAnycubicCamera(_ printer: SavedPrinter) {
        guard anycubicStream == nil, let url = URL(string: "http://\(cameraHost(for: printer)):18088/flv") else { return }
        view.showStatus(AppSettings.shared.t("Connecting to FLV camera…"))
        let stream = AnycubicCameraStream(url: url,
            onFrame: { data in Task { @MainActor [weak self] in self?.handleImageFrame(data) } },
            onState: { state in Task { @MainActor [weak self] in
                if case .failed(let message) = state, self?.receivedFrame == false { self?.view.showStatus(message) }
            } })
        anycubicStream = stream; stream.start()
    }

    private func handleAccessUnit(_ avcc: Data, keyframe: Bool) {
        receivedFrame = true
        timeout?.cancel()
        view.enqueue(avcc, keyframe: keyframe)
    }

    private func handleImageFrame(_ data: Data) {
        receivedFrame = true
        timeout?.cancel()
        if let image = NSImage(data: data) { view.show(image) }
    }

    /// The X1 answers on RTSP(S); the P1 and A1 do not have that endpoint at all and serve JPEG frames
    /// on port 6000 instead. So a failed RTSP attempt is not the end of the road, it is the cue to try
    /// the other protocol before telling the user anything is wrong.
    private func startBambuJPEGFallback(_ printer: SavedPrinter) {
        guard jpegStream == nil, !receivedFrame,
              let code = store.accessCode(for: serial), !code.isEmpty else { return }
        view.showStatus(AppSettings.shared.t("Connecting to the P1/A1 camera…"))
        let stream = BambuJPEGCameraStream(
            host: cameraHost(for: printer),
            accessCode: code,
            onState: { state in Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failed = state, !self.receivedFrame {
                    self.view.showStatus(Self.unavailableText)
                }
            } },
            onFrame: { data in Task { @MainActor [weak self] in self?.handleImageFrame(data) } })
        jpegStream = stream
        stream.start()
    }

    private func handleCameraState(_ state: RTSPCameraStream.State) {
        switch state {
        case .connecting, .playing:
            break
        case .failed:
            // Not necessarily a dead end: on a P1/A1 there is no RTSP endpoint to begin with.
            guard let printer = store.printers.first(where: { $0.serial == serial }) else {
                if !receivedFrame { view.showStatus(Self.unavailableText) }
                return
            }
            startBambuJPEGFallback(printer)
        }
    }

    private func handleKlipperState(_ state: KlipperCameraStream.State) {
        switch state {
        case .connecting, .streaming:
            break
        case .failed:
            if !receivedFrame {
                view.showStatus(AppSettings.shared.t("Camera unavailable — check the webcam config in Moonraker (Fluidd/Mainsail)"))
            }
        }
    }
}

// MARK: - Camera view (H.264 via AVSampleBufferDisplayLayer)

@MainActor
final class CameraView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()   // Bambu H.264
    private let imageView = NSImageView()                     // Klipper JPEG snapshots
    private let statusLabel = NSTextField(labelWithString: "")
    private var formatDescription: CMFormatDescription?

    /// Corner rounding of the black plate. The detail view's card wants 10; the edge dock sits inside
    /// its own silhouette and asks for a tighter radius.
    var cornerRadius: CGFloat = 10 { didSet { layer?.cornerRadius = cornerRadius } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func setParameterSets(sps: Data, pps: Data) {
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
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        if let format { formatDescription = format }
    }

    func enqueue(_ avcc: Data, keyframe: Bool) {
        guard let formatDescription else { return }
        let length = avcc.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        // Live stream with no timestamps → display each frame as soon as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
        statusLabel.isHidden = true
    }

    /// Klipper JPEG snapshot frame.
    func show(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        statusLabel.isHidden = true
    }

    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }
}
