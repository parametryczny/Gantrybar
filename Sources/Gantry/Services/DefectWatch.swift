import AppKit
import CoreML
import Combine
import Vision

/// Watching prints for failures: a frame every so often, an opinion on it, and a warning only when
/// the opinion holds (see DefectVerdict).
///
/// Two things give that opinion and they stack, so the feature means something the day it is switched
/// on and gets better as the user uses it:
///
/// 1. **How the print is behaving** (PrintBaseline). Needs nothing at all. It compares each frame
///    with the minutes before it on the same camera, which is what catches an object coming off the
///    bed and a layer shift, neither of which a single picture can show.
/// 2. **What the frame looks like**, from two directions at once: the Core ML engine (Gantry Vision,
///    or a file the user chose instead), and `DefectPrototypes` (the reference frames Gantry ships
///    plus every frame the user marked). Both are asked, always. The engine knows the cameras it was
///    trained on; the user's own frames know the camera in front of them, and when the engine says
///    "something like a failure, but too weak" about a picture the user has already named, the
///    frames win. For a while the engine was the sole judge and marking a defect did nothing at all.
///
/// The frame itself is taken through `CameraSnapshot.latestFrame`, never `capture`: a printer camera
/// allows one client at a time, so a watcher that opens its own connection every minute takes the
/// picture away from whoever is watching it live.
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
    /// Wzorce policzone z klatek oznaczonych przez użytkownika: droga, która nie wymaga żadnego
    /// pliku modelu ani trenowania (patrz DefectPrototypes).
    private var prototypes: [DefectPrototypes.Prototype] = []
    private var timer: Timer?
    private var busy: Set<String> = []
    private var verdicts: [String: DefectVerdict] = [:]
    /// Jak zachowuje się każdy wydruk z osobna. Nie wymaga żadnych danych, więc działa od pierwszego
    /// uruchomienia i jest jedyną drogą, którą ma nowy użytkownik (patrz PrintBaseline).
    private var baselines: [String: PrintBaseline] = [:]
    private var lastFrame: [String: Data] = [:]
    private var masks: [String: DefectMask] = [:]
    private var lastInspection: [String: Date] = [:]
    private var lastJob: [String: String] = [:]
    /// Ile klatek „idzie dobrze" Gantry zapisało samo dla bieżącego wydruku i kiedy ostatnio.
    private var goodFrames: [String: (job: String, count: Int, at: Date)] = [:]
    /// Skąd przyszła poprzednia klatka. Dwa strumienie tej samej drukarki kadrują inaczej, więc
    /// porównywanie klatki z jednego z klatką z drugiego czyta zmianę kamery jako zmianę wydruku.
    private var frameSource: [String: CameraSnapshot.Source] = [:]
    /// O czym już powiedzieliśmy przy tym wydruku, żeby karta nie zbierała tej samej wpadki w kółko.
    private var toldAbout: [String: (job: String, labels: Set<String>)] = [:]
    /// Przy którym wydruku powiedzieliśmy już, że kamera nic nie widzi. Raz na wydruk wystarczy.
    private var toldBlind: [String: String] = [:]
    /// Kiedy Gantry ostatnio otwierało własne połączenie z kamerą danej drukarki i jak długo ma teraz
    /// czekać. Klatka z cudzego podglądu jest darmowa, własne połączenie nie jest.
    private var ownLookAt: [String: Date] = [:]
    private var ownLookBackoff: [String: TimeInterval] = [:]
    private static let ownLookInterval: TimeInterval = 60
    private static let ownLookCeiling: TimeInterval = 300

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
        // Wzorce liczą się zawsze, także obok modelu: to jedyna rzecz, która zna akurat Twoją kamerę.
        // Dopóki model był wyłącznym sędzią, oznaczanie defektów nie robiło zupełnie nic.
        rebuildPrototypes()
        // Gantry Vision jest podstawą; wskazany plik ją zastępuje. Ładowany od razu, żeby zły plik
        // zgłosił się teraz, a nie dopiero przez ciszę w nocy.
        if let path = DefectModel.effectivePath(chosen: settings.defectModelPath) {
            var next = status
            do {
                try DefectModel.shared.prepare(path: path)
                next.modelName = DefectModel.shared.displayName(for: path)
                next.lastError = nil
            } catch {
                next.modelName = nil
                next.lastError = error.localizedDescription
            }
            status = next
        }
        schedule(interval: TimeInterval(max(5, settings.defectWatchSeconds)))
    }

    /// Przelicza wzorce z oznaczonych klatek. Wołane przy włączaniu i po dołożeniu zdjęć, nie przy
    /// każdej klatce: to przejście po katalogu, nie decyzja.
    func rebuildPrototypes() {
        prototypes = DefectPrototypes.build()
        let tally = DefectPrototypes.tally(prototypes)
        var next = status
        next.modelName = prototypes.isEmpty
            ? AppSettings.shared.t("how the print is behaving")
            : AppSettings.shared.t("how the print is behaving + {0} reference frames, {1} of them yours",
                                   prototypes.count, tally.mine)
        next.lastError = nil
        status = next
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        prototypes = []
        verdicts.removeAll()
        lastFrame.removeAll()
        lastInspection.removeAll()
        baselines.removeAll()
        goodFrames.removeAll()
        frameSource.removeAll()
        toldAbout.removeAll()
        toldBlind.removeAll()
        ownLookAt.removeAll()
        ownLookBackoff.removeAll()
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


    // MARK: One look

    private func look() {
        guard let store else { return }
        for printer in store.printers {
            let telemetry = store.telemetry[printer.serial] ?? PrinterTelemetry()
            // Only a running print can fail in a way worth interrupting, and only a printer with a
            // camera can be looked at.
            guard telemetry.state == .printing, CameraFeedController.supportsCamera(printer.kind) else { continue }
            // A new job starts with a clean slate: yesterday's spaghetti says nothing about today's.
            let job = telemetry.jobName ?? ""
            if lastJob[printer.serial] != job {
                lastFrame[printer.serial] = nil
                lastInspection[printer.serial] = nil
                lastJob[printer.serial] = job
                verdicts[printer.serial]?.reset()
                baselines[printer.serial]?.reset()
                toldAbout[printer.serial] = (job: job, labels: [])
                toldBlind[printer.serial] = nil
            }
            guard !busy.contains(printer.serial) else { continue }
            // A frame from a preview somebody already has open is free. A frame that needs Gantry to
            // open its own connection is not: it is a fresh TLS session against a small embedded
            // board, and at the watch interval that is three a minute per printer, for ever. So those
            // are rationed, and backed off further when they keep failing.
            if !CameraFeedController.isLive(serial: printer.serial) {
                let wait = ownLookBackoff[printer.serial] ?? Self.ownLookInterval
                let since = Date().timeIntervalSince(ownLookAt[printer.serial] ?? .distantPast)
                guard since >= wait else { continue }
                ownLookAt[printer.serial] = Date()
            }
            busy.insert(printer.serial)
            Task { @MainActor [weak self] in
                defer { self?.busy.remove(printer.serial) }
                guard let self else { return }
                let taken = await CameraSnapshot.latestFrame(printer: printer, store: store)
                if CameraFeedController.isLive(serial: printer.serial) == false {
                    // A camera that keeps refusing is asked less and less often, up to five minutes.
                    self.ownLookBackoff[printer.serial] = taken == nil
                        ? min(Self.ownLookCeiling, (self.ownLookBackoff[printer.serial] ?? Self.ownLookInterval) * 2)
                        : Self.ownLookInterval
                }
                guard AppSettings.shared.defectWatchEnabled,
                      let current = store.telemetry[printer.serial], current.state == .printing,
                      (current.jobName ?? "") == job, let frame = taken else { return }
                guard self.lastFrame[printer.serial] != frame.jpeg else { return }
                let now = Date()
                if now.timeIntervalSince(self.lastInspection[printer.serial] ?? now) > max(180, Double(AppSettings.shared.defectWatchSeconds) * 3) {
                    self.verdicts[printer.serial]?.reset()
                }
                self.lastFrame[printer.serial] = frame.jpeg
                self.lastInspection[printer.serial] = now
                // A frame from a different stream cannot be compared with the last one, so the
                // history starts again rather than reading the new framing as a failure.
                if self.frameSource[printer.serial] != frame.source {
                    self.frameSource[printer.serial] = frame.source
                    self.baselines[printer.serial]?.reset()
                    self.verdicts[printer.serial]?.reset()
                }
                self.inspect(jpeg: frame.jpeg, printer: printer, telemetry: current)
            }
        }
    }

    private func inspect(jpeg: Data, printer: SavedPrinter, telemetry: PrinterTelemetry) {
        let mask = DefectMask.load(serial: printer.serial)
        if masks[printer.serial] != mask {
            masks[printer.serial] = mask
            baselines[printer.serial]?.reset()
            verdicts[printer.serial]?.reset()
        }
        let analysis: Data
        do { analysis = try mask.applying(to: jpeg) }
        catch {
            baselines[printer.serial]?.reset()
            verdicts[printer.serial]?.reset()
            var next = status; next.lastError = error.localizedDescription; status = next
            return
        }
        // Klatka, na której nic nie widać, nie jest klatką o wydruku. Kamera w komorze bez światła
        // oddaje czarny prostokąt, a każda z trzech dróg ma o nim jakieś zdanie i każde jest zmyślone.
        // Na tej flocie MINI oddała dziewięć takich i wszystkie skończyły z etykietą spaghetti.
        guard let frame = FrameSignals.grey(from: analysis) else { return }
        guard FrameSignals.legible(frame) else {
            baselines[printer.serial]?.reset()
            verdicts[printer.serial]?.reset()
            reportBlindCamera(printer: printer, telemetry: telemetry)
            return
        }
        // Store raw camera frames, but use the selected area for both analysis paths.
        let fromBehaviour = watchBehaviour(frame: frame, printer: printer, telemetry: telemetry)

        // Wzorce liczą się zawsze, także przy wskazanym modelu. Model zna kamery, na których był
        // uczony; Twoje klatki znają Twoją. Gdy model mówi „coś podobnego, ale za słabo", a klatka
        // z tej samej kamery, którą sam oznaczyłeś, mówi wprost, to ta druga ma rację.
        let match = mask.isActive ? nil : DefectPrototypes.match(jpeg: analysis, against: prototypes)
        let fromFrames = PrintBaseline.Reading(label: match?.label, confidence: match?.confidence ?? 0)

        guard let path = DefectModel.effectivePath(chosen: AppSettings.shared.defectModelPath) else {
            settle([fromBehaviour, fromFrames], jpeg: jpeg, printer: printer, telemetry: telemetry)
            return
        }
        // Ten sam wczytany plik, którego używa „Testuj". Dwa wczytania tego samego modelu prędzej
        // czy później zaczęłyby odpowiadać inaczej, a wtedy sprawdzanie przestaje cokolwiek znaczyć.
        do {
            let guess = try DefectModel.shared.guess(jpeg: analysis, path: path)
            let appearance = DefectAppearance.select(
                model: guess.map { ($0.label, $0.confidence) },
                reference: match.map { ($0.label, $0.confidence) },
                threshold: AppSettings.shared.defectThreshold)
            let fromModel = PrintBaseline.Reading(label: appearance?.label, confidence: appearance?.confidence ?? 0)
            settle([fromBehaviour, fromModel], jpeg: jpeg, printer: printer, telemetry: telemetry)
        } catch {
            var next = status
            next.lastError = error.localizedDescription
            status = next
        }
    }

    /// Co o tej klatce mówi samo zachowanie wydruku. Historia jest osobna dla każdej drukarki, bo
    /// każda ma własną kamerę, własne światło i własny kadr.
    private func watchBehaviour(frame: [Float], printer: SavedPrinter,
                                telemetry: PrinterTelemetry) -> PrintBaseline.Reading {
        var baseline = baselines[printer.serial] ?? PrintBaseline()
        let reading = baseline.observe(frame: frame, progress: Double(telemetry.progress) / 100)
        baselines[printer.serial] = baseline
        return reading
    }

    /// Bierze mocniejszą z dwóch opinii i na niej opiera decyzję.
    ///
    /// Dwie drogi patrzą na co innego: jedna na to, jak wydruk się zmienia, druga na to, jak wygląda.
    /// Zgodzić się nie muszą, a wystarczy, że jedna ma naprawdę mocny powód, żeby zawołać: „wygląda
    /// normalnie" nie może zagłuszyć „przed chwilą wszystko się posypało". Dopóki jednak żadna nie
    /// przekroczyła progu, liczy się zwykłe „spokojnie", bo to ono kasuje licznik.
    private func settle(_ readings: [PrintBaseline.Reading],
                        jpeg: Data, printer: SavedPrinter, telemetry: PrinterTelemetry) {
        let threshold = AppSettings.shared.defectThreshold
        let alarming = readings
            .filter { $0.confidence >= threshold && ($0.label.map(DefectVerdict.warrantsWarning) ?? false) }
            .max { $0.confidence < $1.confidence }
        let best = alarming ?? readings.max { $0.confidence < $1.confidence } ?? readings[0]
        let first = readings[0]
        if alarming == nil, first.label == nil {
            rememberGoodFrame(jpeg: jpeg, printer: printer, telemetry: telemetry)
        }
        var next = status
        next.lastLabel = best.label
        next.lastConfidence = best.confidence
        next.lastLookedAt = Date()
        status = next
        react(label: best.label, confidence: best.confidence,
              jpeg: jpeg, printer: printer, telemetry: telemetry)
    }


    /// Co zrobić, gdy człowiek odpowie na ostrzeżenie.
    ///
    /// „Fałszywy alarm" jest wart więcej niż samo ostrzeżenie: klatka trafia do „idzie dobrze" i od
    /// tej chwili jest tym, z czym porównywane są następne, a licznik wraca do zera, żeby ta sama
    /// wpadka mogła zostać zgłoszona jeszcze raz, gdyby wydarzyła się naprawdę. Bez tego pomyłka była
    /// czystą stratą: nic się z niej nie brało, a karta powtarzała ją aż do końca wydruku.
    /// Ta sama odpowiedź, gdy padła na przycisku powiadomienia. Wtedy znany jest plik, nie drukarka,
    /// więc drukarkę odnajduje się po tym pliku, żeby karta przestała pytać o rzecz już rozstrzygniętą.
    func answeredOnNotification(frame: String, confirmed: Bool) {
        if let store, let serial = store.defectAlarms.first(where: { $0.value.frame == frame })?.key {
            store.answerDefect(serial: serial, confirmed: confirmed)
            return
        }
        DefectDataset.refile(frame: URL(fileURLWithPath: frame), as: confirmed ? nil : .ok)
        rebuildPrototypes()
    }

    func answered(serial: String, confirmed: Bool) {
        if !confirmed {
            verdicts[serial]?.reset()
            baselines[serial]?.reset()
            toldAbout[serial] = nil
        }
        rebuildPrototypes()
    }

    /// Mówi raz na wydruk, że z tej kamery nic nie da się wyczytać.
    ///
    /// Cisza znaczy tu dwie zupełnie różne rzeczy: „wszystko w porządku" i „patrzę w ciemność". Do
    /// tej pory wyglądały tak samo, więc drukarka z zgaszoną komorą sprawiała wrażenie pilnowanej.
    private func reportBlindCamera(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        let job = telemetry.jobName ?? ""
        guard toldBlind[printer.serial] != job else { return }
        toldBlind[printer.serial] = job
        let settings = AppSettings.shared
        var next = status
        next.lastLabel = nil
        next.lastConfidence = 0
        next.lastLookedAt = Date()
        status = next
        store?.postCardNotice(serial: printer.serial,
                              text: settings.t("Nothing to see from this camera: the chamber light is off, so the print is not being watched."))
    }

    /// Keeps a few frames of a print that is going well, from the user's own camera.
    ///
    /// Recognising spaghetti needs something for it to be *unlike*, and a stranger's photograph of a
    /// tidy print is not that. Gantry shipped one for a while and it was a mistake worth writing
    /// down: the "this is fine" frames were daylight photographs of whole printers on desks, the
    /// spaghetti frames were close-ups from inside a chamber, so anything at all from a real chamber
    /// camera landed nearer the spaghetti. A perfectly good print came back as spaghetti.
    ///
    /// The only pictures that can stand for "normal on this printer" come from this printer. So
    /// Gantry takes them itself, quietly, while nothing is wrong: a few per print, spaced out, from
    /// the middle of the job where a print is neither starting nor finishing. They go in the same
    /// folder as the marked ones and are pruned by the same limit, and the index records that Gantry
    /// chose them rather than a person.
    private func rememberGoodFrame(jpeg: Data, printer: SavedPrinter, telemetry: PrinterTelemetry) {
        let progress = Double(telemetry.progress) / 100
        guard progress >= 0.15, progress <= 0.85 else { return }
        let job = telemetry.jobName ?? ""
        var kept = goodFrames[printer.serial] ?? (job: job, count: 0, at: .distantPast)
        if kept.job != job { kept = (job: job, count: 0, at: .distantPast) }
        // Three a print is enough to describe a camera, and far apart enough to catch it at
        // different heights of the same object rather than three views of one minute.
        guard kept.count < 3, Date().timeIntervalSince(kept.at) > 8 * 60 else { return }
        guard (try? DefectDataset.save(jpeg: jpeg, label: .ok, printer: printer, telemetry: telemetry,
                                       limitBytes: AppSettings.shared.defectDatasetLimitMB * 1024 * 1024,
                                       automatic: true)) != nil else { return }
        goodFrames[printer.serial] = (job: job, count: kept.count + 1, at: Date())
        // A new "this is fine" frame changes what everything is compared against, so the bank is
        // rebuilt now rather than at the next restart.
        rebuildPrototypes()
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
        // Once per print per kind, and that is the end of it. The verdict clears itself after a few
        // calm frames so a failure that comes back can be reported again, which is right for a
        // notification and wrong for a card: the fleet ended up with three identical warnings
        // stacked on one printer, all of them wrong, none of them dismissable as a group.
        let job = telemetry.jobName ?? ""
        var told = toldAbout[printer.serial] ?? (job: job, labels: [])
        if told.job != job { told = (job: job, labels: []) }
        guard !told.labels.contains(failed) else { return }
        told.labels.insert(failed)
        toldAbout[printer.serial] = told

        let percent = Int((sure * 100).rounded())
        let body = settings.t("{0} ({1}%) on {2}", settings.t(failed), percent, printer.name)
        // The frame that caused the warning is kept under the label it was guessed to be: it is
        // exactly the picture the recogniser should learn from, whether the call was right or wrong.
        let frame = try? DefectDataset.save(jpeg: jpeg, label: DefectDataset.Label(rawValue: failed) ?? .other,
                                            printer: printer, telemetry: telemetry,
                                            limitBytes: settings.defectDatasetLimitMB * 1024 * 1024, prediction: true)
        // Two buttons on the warning, because only the person who looks at the printer knows whether
        // the guess was right, and their answer both settles it and teaches the recogniser.
        NotificationService.post(title: settings.t("Possible print failure"), body: body,
                                 userInfo: frame.map { ["frame": $0.path] } ?? [:],
                                 category: frame == nil ? nil : NotificationService.defectCategory)
        TelegramService.notify(printer: printer.name, title: settings.t("Possible print failure"), body: body)
        // The card keeps saying it until dismissed. A notification can be swiped away unread, and
        // quiet hours suppress it altogether, so it cannot be the only place a warning ever appears.
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        store?.postDefectAlarm(serial: printer.serial,
                               text: settings.t("Possible print failure at {0}: {1} ({2}%)",
                                                clock.string(from: Date()), settings.t(failed), percent),
                               frame: frame?.path)
        if settings.defectPausesPrint, let store {
            store.runAutomation(PrinterAutomation(name: "defect", trigger: .manual, action: .pause),
                                serial: printer.serial)
        }
    }
}
