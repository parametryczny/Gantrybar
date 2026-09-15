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
    /// Held from the Cmd 386 request until `stop()`, so the printer's single stream is released with us.
    private var elegooGate: ElegooVideoGate?
    /// Bumped by `stop()`, so an Ack that arrives after the feed was stopped or restarted opens nothing.
    private var feedGeneration = 0
    private var decodeFailures = 0
    private static let decodeFailuresBeforeNotice = 5
    private var timeout: DispatchWorkItem?
    private var receivedFrame = false
    /// When the last frame arrived, and the machinery that notices it stopped arriving.
    ///
    /// A stream that dies loudly is handled by `handleCameraState`. A stream that simply goes quiet
    /// was handled by nothing at all: measured on an X1, frames stopped after five to ten seconds
    /// with no error, no teardown and no state change, and the last frame stayed on screen for ever.
    /// That is what a camera "lagging" in the strip actually was. The keep-alive added to the RTSP
    /// client should stop most of these; this is the net under it.
    private var lastFrameAt = Date()
    private var watchdogGeneration = 0
    private var restartDelay: TimeInterval = CameraFeedController.minimumRestartDelay
    private static let minimumRestartDelay: TimeInterval = 8
    private static let maximumRestartDelay: TimeInterval = 30
    private static let watchdogInterval: TimeInterval = 2

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
        decodeFailures = 0
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
        lastFrameAt = Date()
        armWatchdog()
    }

    private func armWatchdog() {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogInterval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, generation == self.watchdogGeneration else { return }
                self.checkForSilence()
            }
        }
    }

    /// Restarts a feed that was working and then stopped, backing off so a camera that is genuinely
    /// gone is not hammered. A feed that never produced a frame is left to the 12 second message.
    private func checkForSilence() {
        guard receivedFrame, Date().timeIntervalSince(lastFrameAt) > restartDelay else {
            armWatchdog()
            return
        }
        restartDelay = min(Self.maximumRestartDelay, restartDelay * 2)
        let wasRunning = isRunning
        stop()
        guard wasRunning else { return }
        start()
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
        feedGeneration += 1
        elegooGate?.release()
        elegooGate = nil
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
        guard elegooStream == nil, elegooGate == nil else { return }
        let isCC2 = printer.kind == .elegooCC2
        let port = isCC2 ? 8080 : 3031
        let path = isCC2 ? "/?action=stream" : "/video"
        guard let url = URL(string: "http://\(cameraHost(for: printer)):\(port)\(path)") else { return }
        view.showStatus(AppSettings.shared.t("Connecting to camera…"))
        guard !isCC2, let gate = store.elegooVideoGate(serial: serial) else {
            if isCC2 { store.sendElegooMethod(serial: serial, method: 1042) }
            openElegooStream(url)
            return
        }
        // The CC1 serves nothing on 3031 until it has accepted Cmd 386, and it says why when it refuses.
        elegooGate = gate
        let generation = feedGeneration
        gate.acquire { ack in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, generation == self.feedGeneration else { return }
                if let refusal = ElegooVideoGate.refusalMessage(ack: ack) {
                    self.timeout?.cancel()
                    self.view.showStatus(refusal)
                } else {
                    self.openElegooStream(url)
                }
            }
        }
    }

    private func openElegooStream(_ url: URL) {
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
        noteFrame()
        timeout?.cancel()
        view.enqueue(avcc, keyframe: keyframe)
    }

    private func handleImageFrame(_ data: Data) {
        noteFrame()
        timeout?.cancel()
        if let image = NSImage(data: data) {
            decodeFailures = 0
            view.show(image)
        } else {
            // Frames that arrive but never decode used to leave "Connecting…" on screen for good.
            decodeFailures += 1
            if decodeFailures == Self.decodeFailuresBeforeNotice {
                view.showStatus(AppSettings.shared.t("The camera sends pictures that cannot be decoded."))
            }
        }
    }

    /// A frame arrived, so the feed is alive. Sustained flow also earns back the short retry delay,
    /// otherwise one bad patch would leave a healthy camera on a 30 second leash for the session.
    private func noteFrame() {
        receivedFrame = true
        lastFrameAt = Date()
        if restartDelay > Self.minimumRestartDelay,
           Date().timeIntervalSince(lastHealthyReset) > 60 {
            restartDelay = Self.minimumRestartDelay
            lastHealthyReset = Date()
        }
    }
    private var lastHealthyReset = Date()

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

