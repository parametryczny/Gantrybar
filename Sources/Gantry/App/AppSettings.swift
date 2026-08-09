import AppKit
import Combine

enum AppLanguage: String, CaseIterable {
    case pl
    case en
    case de

    var displayName: String {
        switch self {
        case .pl: "Polski"
        case .en: "English"
        case .de: "Deutsch"
        }
    }

    var shortName: String { rawValue.uppercased() }

    var next: AppLanguage {
        switch self {
        case .pl: .en
        case .en: .de
        case .de: .pl
        }
    }

    static func detected(from identifier: String?) -> AppLanguage {
        switch identifier?.prefix(2).lowercased() {
        case "pl": .pl
        case "de": .de
        default: .en
        }
    }

    func text(_ polish: String, _ english: String, _ german: String) -> String {
        switch self {
        case .pl: polish
        case .en: english
        case .de: german
        }
    }
}

/// Localizes errors and connection messages produced outside the main actor. The selected language
/// is persisted before background services can emit user-facing text.
func localizedText(_ polish: String, _ english: String, _ german: String) -> String {
    let stored = BambuDefaults.shared.string(forKey: "app-language").flatMap(AppLanguage.init(rawValue:))
    let language = stored ?? AppLanguage.detected(from: Locale.preferredLanguages.first)
    return language.text(polish, english, german)
}

enum AppTheme: String, CaseIterable {
    case light
    case dark
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

    /// System language on first launch: Polish and German follow the OS preference; every other
    /// language uses English, matching the Windows and GNU/Linux editions.
    private static func detectedLanguage() -> AppLanguage {
        AppLanguage.detected(from: Locale.preferredLanguages.first)
    }

    private init() {
        let resolvedLanguage = defaults.string(forKey: "app-language").flatMap(AppLanguage.init(rawValue:)) ?? Self.detectedLanguage()
        // didSet doesn't fire during init, so persist the resolved language now — otherwise other
        // readers (e.g. UpdateService) that read the raw default would fall back to a different value.
        defaults.set(resolvedLanguage.rawValue, forKey: "app-language")
        language = resolvedLanguage
        theme = AppTheme(rawValue: defaults.string(forKey: "app-theme") ?? "dark") ?? .dark
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

    func text(_ polish: String, _ english: String, _ german: String) -> String {
        language.text(polish, english, german)
    }

    func stateLabel(_ state: PrinterState) -> String {
        switch state {
        case .idle: text("Gotowa", "Ready", "Bereit")
        case .printing: text("Drukowanie", "Printing", "Druckt")
        case .paused: text("Wstrzymana", "Paused", "Pausiert")
        case .finished: text("Zakończono", "Finished", "Abgeschlossen")
        case .error: text("Błąd", "Error", "Fehler")
        case .offline: "Offline"
        }
    }

    func activityLabel(stage: Int?, state: PrinterState) -> String {
        guard state == .printing || state == .paused,
              let stage,
              let labels = Self.stageLabels[stage] else { return stateLabel(state) }
        return text(labels.pl, labels.en, labels.de)
    }

    private static let stageLabels: [Int: (pl: String, en: String, de: String)] = [
        0: ("Drukowanie", "Printing", "Druckt"),
        1: ("Poziomowanie stołu", "Auto bed leveling", "Automatische Druckbettnivellierung"),
        2: ("Nagrzewanie stołu", "Heating bed", "Druckbett wird aufgeheizt"),
        3: ("Kalibracja drgań", "Vibration calibration", "Vibrationskalibrierung"),
        4: ("Zmiana filamentu", "Changing filament", "Filament wird gewechselt"),
        5: ("Oczekiwanie", "Waiting", "Wartet"),
        6: ("Brak filamentu", "Filament runout", "Filament aufgebraucht"),
        7: ("Nagrzewanie dyszy", "Heating nozzle", "Düse wird aufgeheizt"),
        8: ("Kalibracja ekstruzji", "Calibrating extrusion", "Extrusion wird kalibriert"),
        9: ("Skanowanie stołu", "Scanning bed", "Druckbett wird gescannt"),
        10: ("Kontrola pierwszej warstwy", "Inspecting first layer", "Erste Schicht wird geprüft"),
        11: ("Rozpoznawanie płyty", "Identifying build plate", "Druckplatte wird erkannt"),
        12: ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"),
        13: ("Bazowanie", "Homing", "Referenzfahrt"),
        14: ("Czyszczenie dyszy", "Cleaning nozzle", "Düse wird gereinigt"),
        15: ("Kontrola temperatury dyszy", "Checking nozzle temperature", "Düsentemperatur wird geprüft"),
        16: ("Wstrzymano przez użytkownika", "Paused by user", "Von dir pausiert"),
        17: ("Otwarta przednia osłona", "Front cover open", "Frontabdeckung geöffnet"),
        18: ("Kalibracja LiDAR", "Calibrating LiDAR", "LiDAR wird kalibriert"),
        19: ("Kalibracja przepływu", "Calibrating flow", "Fluss wird kalibriert"),
        20: ("Błąd temperatury dyszy", "Nozzle temperature issue", "Problem mit der Düsentemperatur"),
        21: ("Błąd temperatury stołu", "Bed temperature issue", "Problem mit der Druckbetttemperatur"),
        22: ("Wyładowanie filamentu", "Unloading filament", "Filament wird entladen"),
        23: ("Wykryto pominięty krok", "Skipped step detected", "Schrittverlust erkannt"),
        24: ("Ładowanie filamentu", "Loading filament", "Filament wird geladen"),
        25: ("Kalibracja silników", "Calibrating motors", "Motoren werden kalibriert"),
        26: ("Utracono połączenie z AMS", "AMS connection lost", "AMS-Verbindung verloren"),
        27: ("Niska prędkość wentylatora", "Low heatbreak fan speed", "Heatbreak-Lüfter zu langsam"),
        28: ("Błąd temperatury komory", "Chamber temperature issue", "Problem mit der Bauraumtemperatur"),
        29: ("Chłodzenie komory", "Cooling chamber", "Bauraum wird gekühlt"),
        30: ("Pauza z G-code", "Paused by G-code", "Durch G-Code pausiert"),
        31: ("Test dźwięku silników", "Motor noise test", "Motorgeräuschtest"),
        32: ("Filament na dyszy", "Filament covering nozzle", "Filament bedeckt die Düse"),
        33: ("Błąd obcinaka", "Cutter issue", "Problem mit dem Filamentschneider"),
        34: ("Błąd pierwszej warstwy", "First layer issue", "Problem mit der ersten Schicht"),
        35: ("Zatkana dysza", "Nozzle clog", "Düse verstopft"),
        36: ("Kontrola dokładności", "Checking accuracy", "Genauigkeit wird geprüft"),
        37: ("Kalibracja dokładności", "Calibrating accuracy", "Genauigkeit wird kalibriert"),
        38: ("Weryfikacja dokładności", "Verifying accuracy", "Genauigkeit wird verifiziert"),
        39: ("Kalibracja offsetu dyszy", "Calibrating nozzle offset", "Düsenversatz wird kalibriert"),
        40: ("Poziomowanie na gorąco", "High-temperature bed leveling", "Druckbettnivellierung bei hoher Temperatur"),
        41: ("Kontrola szybkozłącza", "Checking quick release", "Schnellverschluss wird geprüft"),
        42: ("Kontrola drzwi i osłon", "Checking doors and covers", "Türen und Abdeckungen werden geprüft"),
        43: ("Kalibracja lasera", "Calibrating laser", "Laser wird kalibriert"),
        44: ("Kontrola platformy", "Checking platform", "Plattform wird geprüft"),
        45: ("Kontrola kamery BirdEye", "Checking BirdEye camera", "BirdEye-Kamera wird geprüft"),
        46: ("Kalibracja kamery BirdEye", "Calibrating BirdEye camera", "BirdEye-Kamera wird kalibriert"),
        47: ("Poziomowanie stołu · 1", "Bed leveling · 1", "Druckbettnivellierung · 1"),
        48: ("Poziomowanie stołu · 2", "Bed leveling · 2", "Druckbettnivellierung · 2"),
        49: ("Nagrzewanie komory", "Heating chamber", "Bauraum wird aufgeheizt"),
        50: ("Chłodzenie stołu", "Cooling bed", "Druckbett wird gekühlt"),
        51: ("Druk linii kalibracyjnych", "Printing calibration lines", "Kalibrierungslinien werden gedruckt"),
        52: ("Kontrola materiału", "Checking material", "Material wird geprüft"),
        53: ("Kalibracja kamery podglądu", "Calibrating live-view camera", "Livebildkamera wird kalibriert"),
        54: ("Oczekiwanie na temperaturę stołu", "Waiting for bed temperature", "Wartet auf Druckbetttemperatur"),
        55: ("Kontrola pozycji materiału", "Checking material position", "Materialposition wird geprüft"),
        56: ("Kalibracja offsetu obcinaka", "Calibrating cutter offset", "Versatz des Filamentschneiders wird kalibriert"),
        57: ("Pomiar powierzchni", "Measuring surface", "Oberfläche wird vermessen"),
        58: ("Przygotowanie termiczne", "Thermal preconditioning", "Thermische Vorbereitung"),
        59: ("Bazowanie uchwytu ostrza", "Homing blade holder", "Referenzfahrt des Klingenhalters"),
        60: ("Kalibracja offsetu kamery", "Calibrating camera offset", "Kameraversatz wird kalibriert"),
        61: ("Kalibracja uchwytu ostrza", "Calibrating blade holder", "Klingenhalter wird kalibriert"),
        62: ("Test wymiany hotendu", "Hotend pick-and-place test", "Hotend-Wechseltest"),
        63: ("Stabilizacja temperatury komory", "Equalizing chamber temperature", "Bauraumtemperatur wird stabilisiert"),
        64: ("Przygotowanie hotendu", "Preparing hotend", "Hotend wird vorbereitet"),
        65: ("Kalibracja wykrywania grudek", "Calibrating clump detection", "Klumpenerkennung wird kalibriert"),
        66: ("Oczyszczanie powietrza", "Purifying chamber air", "Bauraumluft wird gereinigt"),
        67: ("Pomiar modułu obrotowego", "Measuring rotary attachment", "Drehmodul wird vermessen"),
        68: ("Przejazd nad zsyp", "Moving above purge chute", "Fährt über den Auswurfschacht"),
        69: ("Chłodzenie dyszy", "Cooling nozzle", "Düse wird gekühlt"),
        70: ("Centrowanie głowicy", "Centering toolhead", "Werkzeugkopf wird zentriert"),
        71: ("Dopasowanie łuków", "Arc fitting", "Bögen werden angepasst"),
        72: ("Rozpoznawanie hotendu", "Detecting hotend type", "Hotend-Typ wird erkannt"),
        73: ("Kontrola ułożenia płyty", "Checking build plate alignment", "Ausrichtung der Druckplatte wird geprüft"),
        74: ("Kontrola powierzchni stołu", "Checking bed surface", "Druckbettoberfläche wird geprüft"),
        75: ("Kontrola spodu stołu", "Checking bed underside", "Druckbettunterseite wird geprüft"),
        76: ("Wstępna ekstruzja", "Pre-extrusion", "Vor-Extrusion"),
        77: ("Przygotowanie AMS", "Preparing AMS", "AMS wird vorbereitet")
    ]
}
