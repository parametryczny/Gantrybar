import AppKit
import Combine

enum AppTheme: String, CaseIterable {
    case light
    case dark
}

/// How much of the desktop shows through the panel background.
enum PanelTransparency: String, CaseIterable {
    case low     // most opaque — the original popover look
    case medium
    case high    // most see-through

    var material: NSVisualEffectView.Material {
        switch self {
        case .low: .popover
        case .medium, .high: .hudWindow
        }
    }

    // `.underWindowBackground` renders opaque inside a popover, so "high" reuses the working glass
    // material and additionally drops the alpha of the BACKDROP (not the whole window, which would
    // fade the cards too) for a genuinely more see-through panel behind the still-solid cards.
    var backgroundAlpha: CGFloat {
        switch self {
        case .low, .medium: 1.0
        case .high: 0.7
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Language code ("pl", "en", "de"…). Free-form on purpose: the list comes from the catalogs
    /// present in i18n/, so a new language is one file and no code change.
    @Published var language: String {
        didSet { defaults.set(language, forKey: "app-language") }
    }

    /// Kept because a handful of call sites still ask for Polish specifically (insights snapshots
    /// build their own strings).
    var isPolish: Bool { language == "pl" }

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "app-theme")
            applyTheme()
        }
    }

    @Published var panelTransparency: PanelTransparency {
        didSet { defaults.set(panelTransparency.rawValue, forKey: "panel-transparency") }
    }

    /// Whether the embedded Spoolbase filament-stock tool appears in the tray menu.
    @Published var spoolbaseEnabled: Bool { didSet { defaults.set(spoolbaseEnabled, forKey: "spoolbase-enabled") } }

    /// Whether the read-only LAN web dashboard (http://<host>.local:8787) runs. Off keeps Gantry a
    /// pure desktop app with no listening socket.
    @Published var webDashboardEnabled: Bool { didSet { defaults.set(webDashboardEnabled, forKey: "web-dashboard-enabled") } }

    /// Download and install new releases automatically (verifying the signature) instead of only
    /// notifying that one is available.
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "auto-update") } }

    /// Developer mode: reveals the printer control + automations tile in the detail card. Off by
    /// default so casual users get a pure monitor without control surfaces.
    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developer-mode") } }

    // What each fleet card shows (customisable in Settings).
    @Published var cardShowFileName: Bool { didSet { defaults.set(cardShowFileName, forKey: "card-show-filename") } }
    @Published var cardShowProgress: Bool { didSet { defaults.set(cardShowProgress, forKey: "card-show-progress") } }
    @Published var cardShowTemperatures: Bool { didSet { defaults.set(cardShowTemperatures, forKey: "card-show-temps") } }
    @Published var cardShowFilaments: Bool { didSet { defaults.set(cardShowFilaments, forKey: "card-show-filaments") } }
    /// Show remaining grams on the spool under AMS NFC / Spoolbase slots (off by default).
    @Published var cardShowSpoolGrams: Bool { didSet { defaults.set(cardShowSpoolGrams, forKey: "card-show-spool-grams") } }

    /// Calmer palette for people who find the colours tiring: temperature values stay grey (no
    /// heating/cooling tint) and filament colours are muted toward grey.
    @Published var monochrome: Bool { didSet { defaults.set(monochrome, forKey: "monochrome") } }

    /// Security kill switch for automation actions that execute code: `.script` (runs a program on this
    /// Mac) and `.command` (an arbitrary raw MQTT/G-code command). OFF by default so a tampered or planted
    /// automation config cannot run code silently — the same class of issue as KeePass triggers
    /// (CVE-2023-24055). The rule engine refuses these actions unless this is enabled.
    @Published var allowScriptActions: Bool { didSet { defaults.set(allowScriptActions, forKey: "allow-script-actions") } }

    /// Per-rule, first-run consent: ids the user has explicitly approved, so the confirmation prompt
    /// appears once per rule rather than on every trigger.
    func isScriptRuleApproved(_ id: UUID) -> Bool {
        (defaults.string(forKey: "approved-script-rules") ?? "").split(separator: "\n").contains(Substring(id.uuidString))
    }
    func approveScriptRule(_ id: UUID) {
        var set = Set((defaults.string(forKey: "approved-script-rules") ?? "").split(separator: "\n").map(String.init))
        if set.insert(id.uuidString).inserted { defaults.set(set.joined(separator: "\n"), forKey: "approved-script-rules") }
    }

    // Telegram push (outbound). Fires on the same events enabled above (finished/error/paused/low/humidity)
    // when enabled. Keys are shared verbatim with the Windows/Linux ports (telegram-enabled / -bot-token /
    // -chat-id) so the same account works across a user's machines.
    @Published var telegramEnabled: Bool { didSet { defaults.set(telegramEnabled, forKey: "telegram-enabled") } }
    @Published var telegramBotToken: String { didSet { defaults.set(telegramBotToken, forKey: "telegram-bot-token") } }
    @Published var telegramChatID: String { didSet { defaults.set(telegramChatID, forKey: "telegram-chat-id") } }
    /// Alerts (Telegram push) are silenced until this moment, set by the bot's `/mute`. Not @Published:
    /// only the notify path reads it. Empty/absent means not muted.
    ///
    /// Stored as an ISO-8601 string, the same shape Windows and Linux write, so the key documented in
    /// docs/telegram.md really is portable. Older builds wrote a Unix timestamp here, so the getter
    /// still accepts a number and the next write migrates it.
    var telegramMuteUntil: Date? {
        get {
            guard let raw = defaults.string(forKey: "telegram-mute-until"), !raw.isEmpty else {
                let legacy = defaults.double(forKey: "telegram-mute-until")   // pre-0.11 numeric form
                return legacy > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: legacy) : nil
            }
            // Windows writes 7 fractional digits ("o"), Linux 6 (datetime.isoformat), and either may
            // have none, so try the fractional parser first and fall back to the plain one.
            guard let date = Self.iso8601Fractional.date(from: raw) ?? Self.iso8601.date(from: raw),
                  date > Date() else { return nil }
            return date
        }
        set {
            defaults.set(newValue.map { Self.iso8601.string(from: $0) } ?? "", forKey: "telegram-mute-until")
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @Published var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notify-finished") } }
    @Published var notifyError: Bool { didSet { defaults.set(notifyError, forKey: "notify-error") } }
    @Published var notifyPaused: Bool { didSet { defaults.set(notifyPaused, forKey: "notify-paused") } }
    @Published var notifyLowFilament: Bool { didSet { defaults.set(notifyLowFilament, forKey: "notify-low-filament") } }
    /// Heads-up shortly before a job ends, so a long print can be collected without watching the ETA.
    /// Off by default: on a busy fleet it is one extra alert per job on top of the finished one.
    @Published var notifyFinishingSoon: Bool { didSet { defaults.set(notifyFinishingSoon, forKey: "notify-finishing-soon") } }
    /// Minutes of remaining print time that trigger the heads-up above.
    @Published var finishingSoonMinutes: Int { didSet { defaults.set(finishingSoonMinutes, forKey: "notify-finishing-soon-minutes") } }
    @Published var notifyHumidity: Bool { didSet { defaults.set(notifyHumidity, forKey: "notify-humidity") } }

    // Edge dock: the narrow always-on-top strip pinned to a screen edge. Off by default — it is an
    // opt-in second surface, not a replacement for the menu-bar popover.
    @Published var edgeDockEnabled: Bool { didSet { defaults.set(edgeDockEnabled, forKey: "edge-dock-enabled") } }
    @Published var edgeDockEdge: EdgeDockEdge { didSet { defaults.set(edgeDockEdge.rawValue, forKey: "edge-dock-edge") } }
    /// Hide printers that are neither printing nor paused, so a large fleet does not fill the screen
    /// with idle rings.
    @Published var edgeDockOnlyPrinting: Bool { didSet { defaults.set(edgeDockOnlyPrinting, forKey: "edge-dock-only-printing") } }

    /// Serials the user unticked. Stored as an exclusion list rather than an inclusion list so a newly
    /// added printer shows up by itself instead of silently missing from the strip.
    @Published var edgeDockHiddenPrinters: Set<String> {
        didSet { defaults.set(edgeDockHiddenPrinters.sorted().joined(separator: "\n"), forKey: "edge-dock-hidden") }
    }

    /// Extra discovery targets (IPs / CIDR / ranges) scanned in addition to the local subnet — lets a
    /// printer reached over a VPN like Tailscale be found. Read at scan time, so not @Published.
    var subnetScanTargets: String {
        get { defaults.string(forKey: "discovery-subnet-targets") ?? "" }
        set { defaults.set(newValue, forKey: "discovery-subnet-targets") }
    }

    private let defaults = BambuDefaults.shared

    /// System language on first launch: Polish only if the OS preference is Polish, else English —
    /// matching the Windows side, where the default follows CurrentUICulture.
    /// First launch: use the OS language when a catalog for it exists, else English.
    private static func detectedLanguage() -> String {
        let code = String(Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en")
        return Localization.available().contains { $0.code == code } ? code : "en"
    }

    private init() {
        // A stored language whose catalog has since been removed must not leave the app on a dead
        // code, so it falls back to detection rather than being trusted blindly.
        let stored = defaults.string(forKey: "app-language")
        let known = Localization.available().map(\.code)
        let resolvedLanguage = stored.flatMap { known.contains($0) ? $0 : nil } ?? Self.detectedLanguage()
        // didSet doesn't fire during init, so persist the resolved language now — otherwise other
        // readers (e.g. UpdateService) that read the raw default would fall back to a different value.
        defaults.set(resolvedLanguage, forKey: "app-language")
        language = resolvedLanguage
        theme = AppTheme(rawValue: defaults.string(forKey: "app-theme") ?? "dark") ?? .dark
        panelTransparency = PanelTransparency(rawValue: defaults.string(forKey: "panel-transparency") ?? "") ?? .low
        spoolbaseEnabled = defaults.object(forKey: "spoolbase-enabled") as? Bool ?? true
        webDashboardEnabled = defaults.object(forKey: "web-dashboard-enabled") as? Bool ?? true
        autoUpdate = defaults.object(forKey: "auto-update") as? Bool ?? false
        developerMode = defaults.object(forKey: "developer-mode") as? Bool ?? false
        cardShowFileName = defaults.object(forKey: "card-show-filename") as? Bool ?? true
        cardShowProgress = defaults.object(forKey: "card-show-progress") as? Bool ?? true
        cardShowTemperatures = defaults.object(forKey: "card-show-temps") as? Bool ?? true
        cardShowFilaments = defaults.object(forKey: "card-show-filaments") as? Bool ?? true
        cardShowSpoolGrams = defaults.object(forKey: "card-show-spool-grams") as? Bool ?? false
        monochrome = defaults.object(forKey: "monochrome") as? Bool ?? false
        allowScriptActions = defaults.object(forKey: "allow-script-actions") as? Bool ?? false
        telegramEnabled = defaults.object(forKey: "telegram-enabled") as? Bool ?? false
        telegramBotToken = defaults.string(forKey: "telegram-bot-token") ?? ""
        telegramChatID = defaults.string(forKey: "telegram-chat-id") ?? ""
        notifyFinished = defaults.object(forKey: "notify-finished") as? Bool ?? true
        notifyError = defaults.object(forKey: "notify-error") as? Bool ?? true
        notifyPaused = defaults.object(forKey: "notify-paused") as? Bool ?? true
        notifyLowFilament = defaults.object(forKey: "notify-low-filament") as? Bool ?? true
        notifyFinishingSoon = defaults.object(forKey: "notify-finishing-soon") as? Bool ?? false
        finishingSoonMinutes = defaults.object(forKey: "notify-finishing-soon-minutes") as? Int ?? 10
        notifyHumidity = defaults.object(forKey: "notify-humidity") as? Bool ?? true
        edgeDockEnabled = defaults.object(forKey: "edge-dock-enabled") as? Bool ?? false
        edgeDockEdge = EdgeDockEdge(rawValue: defaults.string(forKey: "edge-dock-edge") ?? "") ?? .right
        edgeDockOnlyPrinting = defaults.object(forKey: "edge-dock-only-printing") as? Bool ?? false
        edgeDockHiddenPrinters = Set((defaults.string(forKey: "edge-dock-hidden") ?? "")
            .split(separator: "\n").map(String.init))
    }

    func applyTheme() {
        let selectedAppearance = appearance
        NSApp.appearance = selectedAppearance
        for window in NSApp.windows {
            window.appearance = selectedAppearance
            window.contentView?.appearance = selectedAppearance
            window.contentView?.needsDisplay = true
        }
    }

    var appearance: NSAppearance? {
        NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    }

    /// Looks the English source string up in the shipped catalog (i18n/pl.json). This is the form new
    /// code should use; `text(_:_:)` below stays until every call site is migrated.
    func t(_ english: String) -> String {
        Localization.text(english, language: language)
    }

    /// Same lookup, with positional placeholders filled in: `t("Layer {0} / {1}", current, total)`.
    ///
    /// The catalog uses `{0}`-style placeholders rather than printf specifiers because that is the one
    /// syntax all three platforms can share: C# has string.Format and Python has str.format natively,
    /// so a message needs exactly one catalog entry instead of one per platform. Values that need a
    /// specific precision are formatted at the call site and passed as text.
    func t(_ english: String, _ arguments: Any...) -> String { t(english, arguments: arguments) }

    /// Array form, so a wrapper can forward its own variadic arguments without nesting them.
    func t(_ english: String, arguments: [Any]) -> String {
        var result = Localization.text(english, language: language)
        for (index, argument) in arguments.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: String(describing: argument))
        }
        return result
    }

    func text(_ polish: String, _ english: String) -> String {
        // Legacy form: the Polish literal is only correct for Polish, so any other language goes
        // through the catalog, which for English simply returns the key.
        language == "pl" ? polish : Localization.text(english, language: language)
    }

    func stateLabel(_ state: PrinterState) -> String {
        switch state {
        case .idle: t("Ready")
        case .printing: t("Printing")
        case .paused: t("Paused")
        case .finished: t("Finished")
        case .error: t("Error")
        case .offline: "Offline"
        }
    }

    func activityLabel(stage: Int?, state: PrinterState) -> String {
        guard state == .printing || state == .paused,
              let stage,
              let labels = Self.stageLabels[stage] else { return stateLabel(state) }
        return text(labels.pl, labels.en)
    }

    private static let stageLabels: [Int: (pl: String, en: String)] = [
        0: ("Drukowanie", "Printing"),
        1: ("Poziomowanie stołu", "Auto bed leveling"),
        2: ("Nagrzewanie stołu", "Heating bed"),
        3: ("Kalibracja drgań", "Vibration calibration"),
        4: ("Zmiana filamentu", "Changing filament"),
        5: ("Oczekiwanie", "Waiting"),
        6: ("Brak filamentu", "Filament runout"),
        7: ("Nagrzewanie dyszy", "Heating nozzle"),
        8: ("Kalibracja ekstruzji", "Calibrating extrusion"),
        9: ("Skanowanie stołu", "Scanning bed"),
        10: ("Kontrola pierwszej warstwy", "Inspecting first layer"),
        11: ("Rozpoznawanie płyty", "Identifying build plate"),
        12: ("Kalibracja LiDAR", "Calibrating LiDAR"),
        13: ("Bazowanie", "Homing"),
        14: ("Czyszczenie dyszy", "Cleaning nozzle"),
        15: ("Kontrola temperatury dyszy", "Checking nozzle temperature"),
        16: ("Wstrzymano przez użytkownika", "Paused by user"),
        17: ("Otwarta przednia osłona", "Front cover open"),
        18: ("Kalibracja LiDAR", "Calibrating LiDAR"),
        19: ("Kalibracja przepływu", "Calibrating flow"),
        20: ("Błąd temperatury dyszy", "Nozzle temperature issue"),
        21: ("Błąd temperatury stołu", "Bed temperature issue"),
        22: ("Wyładowanie filamentu", "Unloading filament"),
        23: ("Wykryto pominięty krok", "Skipped step detected"),
        24: ("Ładowanie filamentu", "Loading filament"),
        25: ("Kalibracja silników", "Calibrating motors"),
        26: ("Utracono połączenie z AMS", "AMS connection lost"),
        27: ("Niska prędkość wentylatora", "Low heatbreak fan speed"),
        28: ("Błąd temperatury komory", "Chamber temperature issue"),
        29: ("Chłodzenie komory", "Cooling chamber"),
        30: ("Pauza z G-code", "Paused by G-code"),
        31: ("Test dźwięku silników", "Motor noise test"),
        32: ("Filament na dyszy", "Filament covering nozzle"),
        33: ("Błąd obcinaka", "Cutter issue"),
        34: ("Błąd pierwszej warstwy", "First layer issue"),
        35: ("Zatkana dysza", "Nozzle clog"),
        36: ("Kontrola dokładności", "Checking accuracy"),
        37: ("Kalibracja dokładności", "Calibrating accuracy"),
        38: ("Weryfikacja dokładności", "Verifying accuracy"),
        39: ("Kalibracja offsetu dyszy", "Calibrating nozzle offset"),
        40: ("Poziomowanie na gorąco", "High-temperature bed leveling"),
        41: ("Kontrola szybkozłącza", "Checking quick release"),
        42: ("Kontrola drzwi i osłon", "Checking doors and covers"),
        43: ("Kalibracja lasera", "Calibrating laser"),
        44: ("Kontrola platformy", "Checking platform"),
        45: ("Kontrola kamery BirdEye", "Checking BirdEye camera"),
        46: ("Kalibracja kamery BirdEye", "Calibrating BirdEye camera"),
        47: ("Poziomowanie stołu · 1", "Bed leveling · 1"),
        48: ("Poziomowanie stołu · 2", "Bed leveling · 2"),
        49: ("Nagrzewanie komory", "Heating chamber"),
        50: ("Chłodzenie stołu", "Cooling bed"),
        51: ("Druk linii kalibracyjnych", "Printing calibration lines"),
        52: ("Kontrola materiału", "Checking material"),
        53: ("Kalibracja kamery podglądu", "Calibrating live-view camera"),
        54: ("Oczekiwanie na temperaturę stołu", "Waiting for bed temperature"),
        55: ("Kontrola pozycji materiału", "Checking material position"),
        56: ("Kalibracja offsetu obcinaka", "Calibrating cutter offset"),
        57: ("Pomiar powierzchni", "Measuring surface"),
        58: ("Przygotowanie termiczne", "Thermal preconditioning"),
        59: ("Bazowanie uchwytu ostrza", "Homing blade holder"),
        60: ("Kalibracja offsetu kamery", "Calibrating camera offset"),
        61: ("Kalibracja uchwytu ostrza", "Calibrating blade holder"),
        62: ("Test wymiany hotendu", "Hotend pick-and-place test"),
        63: ("Stabilizacja temperatury komory", "Equalizing chamber temperature"),
        64: ("Przygotowanie hotendu", "Preparing hotend"),
        65: ("Kalibracja wykrywania grudek", "Calibrating clump detection"),
        66: ("Oczyszczanie powietrza", "Purifying chamber air"),
        67: ("Pomiar modułu obrotowego", "Measuring rotary attachment"),
        68: ("Przejazd nad zsyp", "Moving above purge chute"),
        69: ("Chłodzenie dyszy", "Cooling nozzle"),
        70: ("Centrowanie głowicy", "Centering toolhead"),
        71: ("Dopasowanie łuków", "Arc fitting"),
        72: ("Rozpoznawanie hotendu", "Detecting hotend type"),
        73: ("Kontrola ułożenia płyty", "Checking build plate alignment"),
        74: ("Kontrola powierzchni stołu", "Checking bed surface"),
        75: ("Kontrola spodu stołu", "Checking bed underside"),
        76: ("Wstępna ekstruzja", "Pre-extrusion"),
        77: ("Przygotowanie AMS", "Preparing AMS")
    ]
}
