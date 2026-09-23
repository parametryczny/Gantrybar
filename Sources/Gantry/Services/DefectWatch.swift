import AppKit
import CoreML
import Combine
import Vision

/// Watching prints for failures: a frame every so often, a model's opinion on it, and a warning only
/// when the opinion holds (see DefectVerdict).
///
/// Gantry ships no model. It loads a Core ML file the user points it at, because the ready-made
/// detectors people can download come under licences that forbid handing them on inside another app,
/// and because a model trained on the user's own cameras beats a general one anyway. Any model that
/// takes an image and returns labels with confidences works; the labels it uses are its own business.
@MainActor
final class DefectWatch {
    struct Status: Equatable {
        var modelName: String?
        var lastLabel: String?
        var lastConfidence: Double = 0
        var lastLookedAt: Date?
        var lastError: String?
    }

    private weak var store: PrinterStore?
    private var model: VNCoreMLModel?
    private var modelName: String?
    /// Wzorce policzone z klatek oznaczonych przez użytkownika: droga, która nie wymaga żadnego
    /// pliku modelu ani trenowania (patrz DefectPrototypes).
    private var prototypes: [DefectPrototypes.Prototype] = []
    private var timer: Timer?
    private var busy: Set<String> = []
    private var verdicts: [String: DefectVerdict] = [:]
    private var lastJob: [String: String] = [:]

    private(set) var status = Status() { didSet { if status != oldValue { changed.send(status) } } }
    let changed = PassthroughSubject<Status, Never>()

    private(set) static weak var current: DefectWatch?

    init(store: PrinterStore) {
        self.store = store
        Self.current = self
    }

    // MARK: Lifecycle

    func syncWithSettings() {
        let settings = AppSettings.shared
        guard settings.defectWatchEnabled, Build.hasExtras else {
            stop()
            return
        }
        if settings.defectModelPath.isEmpty {
            // Bez wskazanego pliku Gantry uczy się z tego, co sam oznaczyłeś.
            model = nil
            modelName = nil
            rebuildPrototypes()
            guard !prototypes.isEmpty else { return }
        } else {
            prototypes = []
            loadModel(at: settings.defectModelPath)
            guard model != nil else { return }
        }
        schedule(interval: TimeInterval(max(5, settings.defectWatchSeconds)))
    }

    /// Przelicza wzorce z oznaczonych klatek. Wołane przy włączaniu i po dołożeniu zdjęć, nie przy
    /// każdej klatce: to przejście po katalogu, nie decyzja.
    func rebuildPrototypes() {
        prototypes = DefectPrototypes.build()
        var next = status
        next.modelName = prototypes.isEmpty
            ? nil
            : AppSettings.shared.t("your own frames ({0} classes)", prototypes.count)
        next.lastError = prototypes.isEmpty
            ? AppSettings.shared.t("Mark at least three frames of a kind in Details before Gantry can recognise it.")
            : nil
        status = next
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model = nil
        prototypes = []
        verdicts.removeAll()
        status = Status()
    }

    private func schedule(interval: TimeInterval) {
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.look() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor in self.look() }
    }

    /// Loads the user's model. A bad file is reported once, in Settings, rather than silently leaving
    /// the feature off: a watchdog that is quietly not watching is worse than none.
    private func loadModel(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard modelName != url.lastPathComponent || model == nil else { return }
        var next = status
        do {
            // A .mlpackage has to be compiled before it can be loaded; a compiled .mlmodelc is used as is.
            let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
            modelName = url.lastPathComponent
            next.modelName = modelName
            next.lastError = nil
        } catch {
            model = nil
            modelName = nil
            next.modelName = nil
            next.lastError = error.localizedDescription
        }
        status = next
    }

    // MARK: One look

    private func look() {
        guard let store, model != nil || !prototypes.isEmpty else { return }
        for printer in store.printers {
            let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
            // Only a running print can fail in a way worth interrupting, and only a printer with a
            // camera can be looked at.
            guard telemetry.state == .printing, CameraFeedController.supportsCamera(printer.kind) else { continue }
            // A new job starts with a clean slate: yesterday's spaghetti says nothing about today's.
            let job = telemetry.jobName ?? ""
            if lastJob[printer.serial] != job {
                lastJob[printer.serial] = job
                verdicts[printer.serial]?.reset()
            }
            guard !busy.contains(printer.serial) else { continue }
            busy.insert(printer.serial)
            Task { @MainActor [weak self] in
                defer { self?.busy.remove(printer.serial) }
                guard let self, let jpeg = await CameraSnapshot.capture(printer: printer, store: store) else { return }
                self.inspect(jpeg: jpeg, printer: printer, telemetry: telemetry)
            }
        }
    }

    private func inspect(jpeg: Data, printer: SavedPrinter, telemetry: PrinterTelemetry) {
        guard let model else {
            // Droga bez pliku modelu: porównanie z wzorcami z własnych klatek.
            let match = DefectPrototypes.match(jpeg: jpeg, against: prototypes)
            var next = status
            next.lastLabel = match?.label
            next.lastConfidence = match?.confidence ?? 0
            next.lastLookedAt = Date()
            status = next
            react(label: match?.label, confidence: match?.confidence ?? 0,
                  jpeg: jpeg, printer: printer, telemetry: telemetry)
            return
        }
        guard let image = CIImage(data: jpeg) else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] request, _ in
            Task { @MainActor in
                guard let self else { return }
                let best = Self.bestGuess(from: request.results)
                var next = self.status
                next.lastLabel = best?.label
                next.lastConfidence = best?.confidence ?? 0
                next.lastLookedAt = Date()
                self.status = next
                self.react(label: best?.label, confidence: best?.confidence ?? 0,
                           jpeg: jpeg, printer: printer, telemetry: telemetry)
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(ciImage: image).perform([request])
        } catch {
            var next = status
            next.lastError = error.localizedDescription
            status = next
        }
    }

    /// The strongest label a Vision request came back with, whether the model classifies whole frames
    /// or finds objects in them.
    private static func bestGuess(from results: [VNObservation]?) -> (label: String, confidence: Double)? {
        guard let results else { return nil }
        var best: (String, Double)?
        for result in results {
            if let classification = result as? VNClassificationObservation {
                let confidence = Double(classification.confidence)
                if confidence > (best?.1 ?? 0) { best = (classification.identifier, confidence) }
            } else if let recognized = result as? VNRecognizedObjectObservation,
                      let top = recognized.labels.first {
                let confidence = Double(top.confidence)
                if confidence > (best?.1 ?? 0) { best = (top.identifier, confidence) }
            }
        }
        return best.map { (label: $0.0, confidence: $0.1) }
    }

    private func react(label: String?, confidence: Double, jpeg: Data,
                       printer: SavedPrinter, telemetry: PrinterTelemetry) {
        let settings = AppSettings.shared
        var verdict = verdicts[printer.serial] ?? DefectVerdict(threshold: settings.defectThreshold,
                                                                hitsNeeded: settings.defectHitsNeeded)
        verdict.threshold = settings.defectThreshold
        verdict.hitsNeeded = settings.defectHitsNeeded
        let outcome = verdict.observe(label: label, confidence: confidence)
        verdicts[printer.serial] = verdict
        guard case .failure(let failed, let sure) = outcome else { return }

        let percent = Int((sure * 100).rounded())
        let body = settings.t("{0} ({1}%) on {2}", settings.t(failed), percent, printer.name)
        // The frame that caused the warning is kept under the label it was guessed to be: it is
        // exactly the picture the recogniser should learn from, whether the call was right or wrong.
        let frame = try? DefectDataset.save(jpeg: jpeg, label: DefectDataset.Label(rawValue: failed) ?? .other,
                                            printer: printer, telemetry: telemetry,
                                            limitBytes: settings.defectDatasetLimitMB * 1024 * 1024)
        // Two buttons on the warning, because only the person who looks at the printer knows whether
        // the guess was right, and their answer both settles it and teaches the recogniser.
        NotificationService.post(title: settings.t("Possible print failure"), body: body,
                                 userInfo: frame.map { ["frame": $0.path] } ?? [:],
                                 category: frame == nil ? nil : NotificationService.defectCategory)
        TelegramService.notify(printer: printer.name, title: settings.t("Possible print failure"), body: body)
        if settings.defectPausesPrint, let store {
            store.runAutomation(PrinterAutomation(name: "defect", trigger: .manual, action: .pause),
                                serial: printer.serial)
        }
    }
}
