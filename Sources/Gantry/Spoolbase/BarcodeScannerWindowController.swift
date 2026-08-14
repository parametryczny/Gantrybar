@preconcurrency import AVFoundation
import AppKit
import Vision

@MainActor
final class BarcodeScannerWindowController: NSWindowController,
    @preconcurrency AVCaptureMetadataOutputObjectsDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let cameraView = BarcodeCameraView()
    private let onCode: (String) -> Void
    private let visionQueue = DispatchQueue(label: "pl.spoolbase.barcode-vision", qos: .userInitiated)
    private var configured = false
    private var handledCode = false
    nonisolated(unsafe) private var lastVisionScanTime: CFTimeInterval = 0

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Skanuj kod filamentu"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func startScanning() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted { self?.configureAndStart() }
                    else { self?.showCameraError("Spoolbase nie ma dostępu do kamery.") }
                }
            }
        default:
            showCameraError("Włącz dostęp do kamery dla Spoolbase w Ustawieniach systemowych → Prywatność i ochrona → Kamera.")
        }
    }

    override func close() {
        if session.isRunning { session.stopRunning() }
        super.close()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        cameraView.wantsLayer = true
        cameraView.layer?.cornerRadius = 14
        cameraView.layer?.masksToBounds = true
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(cameraView)

        let title = NSTextField(labelWithString: "Skanuj kod z etykiety szpuli")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Wypełnij kodem ramkę i przytrzymaj etykietę nieruchomo")
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(labels)

        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 10
        frame.layer?.borderWidth = 2
        frame.layer?.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor
        frame.translatesAutoresizingMaskIntoConstraints = false
        cameraView.addSubview(frame)

        let cancel = NSButton(title: "Anuluj", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(cancel)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            labels.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            labels.topAnchor.constraint(equalTo: background.topAnchor, constant: 40),
            cameraView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            cameraView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            cameraView.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 12),
            cameraView.bottomAnchor.constraint(equalTo: cancel.topAnchor, constant: -12),
            frame.centerXAnchor.constraint(equalTo: cameraView.centerXAnchor),
            frame.centerYAnchor.constraint(equalTo: cameraView.centerYAnchor),
            frame.widthAnchor.constraint(equalToConstant: 280),
            frame.heightAnchor.constraint(equalToConstant: 105),
            cancel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            cancel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16)
        ])
    }

    private func configureAndStart() {
        guard !configured else {
            if !session.isRunning { session.startRunning() }
            return
        }
        guard let camera = AVCaptureDevice.default(for: .video) else {
            showCameraError("Nie znaleziono kamery.")
            return
        }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            camera.unlockForConfiguration()
            let input = try AVCaptureDeviceInput(device: camera)
            let metadataOutput = AVCaptureMetadataOutput()
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(metadataOutput) { session.addOutput(metadataOutput) }
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            session.commitConfiguration()
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            let supported: [AVMetadataObject.ObjectType] = [.ean8, .ean13, .upce, .code128, .code39, .qr, .dataMatrix, .pdf417, .aztec]
            metadataOutput.metadataObjectTypes = supported.filter(metadataOutput.availableMetadataObjectTypes.contains)
            cameraView.previewLayer.session = session
            cameraView.previewLayer.videoGravity = .resizeAspectFill
            if let connection = cameraView.previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            // Niektóre wbudowane kamery macOS mimo wyłączonego mirroringu nadal
            // prezentują obraz jak w lustrze. Odwracamy wyłącznie warstwę podglądu;
            // surowe klatki przekazywane do Vision pozostają bez zmian.
            cameraView.previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            if let connection = metadataOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            configured = true
            session.startRunning()
        } catch {
            showCameraError(error.localizedDescription)
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        handleScannedValue(value)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastVisionScanTime >= 0.28,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVisionScanTime = now
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean8, .ean13, .upce, .code128, .code39, .qr, .dataMatrix, .pdf417, .aztec]
        let orientations: [CGImagePropertyOrientation] = [.up, .down, .upMirrored, .downMirrored]
        for orientation in orientations {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            do {
                try handler.perform([request])
                if let value = request.results?.compactMap(\.payloadStringValue).first(where: { !$0.isEmpty }) {
                    Task { @MainActor [weak self] in self?.handleScannedValue(value) }
                    return
                }
            } catch {
                continue
            }
        }
    }

    private func handleScannedValue(_ value: String) {
        guard !handledCode else { return }
        handledCode = true
        if session.isRunning { session.stopRunning() }
        onCode(value)
        close()
    }

    private func showCameraError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Nie można uruchomić skanera"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }

    @objc private func cancelPressed() { close() }
}

private final class BarcodeCameraView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
