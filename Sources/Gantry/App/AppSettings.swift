import AppKit
import Combine

enum AppLanguage: String, CaseIterable {
    case pl
    case en
}

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
    // material and additionally drops the panel's window alpha for a genuinely more see-through look.
    var windowAlpha: CGFloat {
        switch self {
        case .low, .medium: 1.0
        case .high: 0.82
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "app-language") }
    }

    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "app-theme")
            applyTheme()
        }
    }

    @Published var panelTransparency: PanelTransparency {
        didSet { defaults.set(panelTransparency.rawValue, forKey: "panel-transparency") }
    }

    @Published var notifyFinished: Bool { didSet { defaults.set(notifyFinished, forKey: "notify-finished") } }
    @Published var notifyError: Bool { didSet { defaults.set(notifyError, forKey: "notify-error") } }
    @Published var notifyPaused: Bool { didSet { defaults.set(notifyPaused, forKey: "notify-paused") } }
    @Published var notifyLowFilament: Bool { didSet { defaults.set(notifyLowFilament, forKey: "notify-low-filament") } }
    @Published var notifyHumidity: Bool { didSet { defaults.set(notifyHumidity, forKey: "notify-humidity") } }

    /// Extra discovery targets (IPs / CIDR / ranges) scanned in addition to the local subnet — lets a
    /// printer reached over a VPN like Tailscale be found. Read at scan time, so not @Published.
    var subnetScanTargets: String {
        get { defaults.string(forKey: "discovery-subnet-targets") ?? "" }
        set { defaults.set(newValue, forKey: "discovery-subnet-targets") }
    }

    private let defaults = BambuDefaults.shared

    /// System language on first launch: Polish only if the OS preference is Polish, else English —
    /// matching the Windows side, where the default follows CurrentUICulture.
    private static func detectedLanguage() -> AppLanguage {
        let code = Locale.preferredLanguages.first?.prefix(2).lowercased()
        return code == "pl" ? .pl : .en
    }

    private init() {
        let resolvedLanguage = defaults.string(forKey: "app-language").flatMap(AppLanguage.init(rawValue:)) ?? Self.detectedLanguage()
        // didSet doesn't fire during init, so persist the resolved language now — otherwise other
        // readers (e.g. UpdateService) that read the raw default would fall back to a different value.
        defaults.set(resolvedLanguage.rawValue, forKey: "app-language")
        language = resolvedLanguage
        theme = AppTheme(rawValue: defaults.string(forKey: "app-theme") ?? "dark") ?? .dark
        panelTransparency = PanelTransparency(rawValue: defaults.string(forKey: "panel-transparency") ?? "") ?? .low
        notifyFinished = defaults.object(forKey: "notify-finished") as? Bool ?? true
        notifyError = defaults.object(forKey: "notify-error") as? Bool ?? true
        notifyPaused = defaults.object(forKey: "notify-paused") as? Bool ?? true
        notifyLowFilament = defaults.object(forKey: "notify-low-filament") as? Bool ?? true
        notifyHumidity = defaults.object(forKey: "notify-humidity") as? Bool ?? true
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

    func text(_ polish: String, _ english: String) -> String {
        language == .pl ? polish : english
    }

    func stateLabel(_ state: PrinterState) -> String {
        switch state {
        case .idle: text("Gotowa", "Ready")
        case .printing: text("Drukowanie", "Printing")
        case .paused: text("Wstrzymana", "Paused")
        case .finished: text("Zakończono", "Finished")
        case .error: text("Błąd", "Error")
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
