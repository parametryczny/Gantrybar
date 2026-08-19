import Foundation

/// When an automation fires. `manual` runs only from the Run button; the others fire once per print
/// when the condition first becomes true.
enum AutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case atLayer(Int)
    case atProgress(Int)
    case onState(String)   // PrinterState.rawValue

    func summary(_ t: (String, String) -> String) -> String {
        switch self {
        case .manual: t("ręcznie", "manually")
        case .atLayer(let n): t("po warstwie \(n)", "at layer \(n)")
        case .atProgress(let p): t("po \(p)%", "at \(p)%")
        case .onState(let s): t("gdy stan: \(PrinterState(rawValue: s)?.label ?? s)",
                                 "on state: \(s)")
        }
    }
}

/// What an automation does when it fires.
enum AutomationAction: Codable, Equatable, Sendable {
    case light(Bool)          // chamber LED on/off
    case pause
    case resume
    case stop
    case notify(String)       // local notification with this text
    case command(String)      // raw Bambu MQTT JSON (advanced / custom)
    case script(String)       // shell script content

    func summary(_ t: (String, String) -> String) -> String {
        switch self {
        case .light(let on): on ? t("światło wł.", "light on") : t("światło wył.", "light off")
        case .pause: t("pauza", "pause")
        case .resume: t("wznów", "resume")
        case .stop: t("stop", "stop")
        case .notify: t("powiadomienie", "notification")
        case .command: t("własna komenda", "custom command")
        case .script: t("skrypt", "script")
        }
    }

    var isScript: Bool { if case .script = self { return true }; return false }
}

struct PrinterAutomation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var enabled: Bool = true
    var trigger: AutomationTrigger = .manual
    var action: AutomationAction = .light(false)
}
