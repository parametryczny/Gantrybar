import Foundation

/// When an automation fires. `manual` runs only from the Run button; the others fire once per print
/// when the condition first becomes true.
enum AutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case atLayer(Int)
    case atProgress(Int)
    case onState(String)   // PrinterState.rawValue

    /// `t` looks the English source string up in the catalog; positional placeholders are filled by
    /// the caller's helper, the same way every other translated string works.
    func summary(_ t: (String, [Any]) -> String) -> String {
        switch self {
        case .manual: t("manually", [])
        case .atLayer(let n): t("at layer {0}", [n])
        case .atProgress(let p): t("at {0}%", [p])
        case .onState(let s): t("on state: {0}", [s])
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

    func summary(_ t: (String, [Any]) -> String) -> String {
        switch self {
        case .light(let on): on ? t("light on", []) : t("light off", [])
        case .pause: t("pause", [])
        case .resume: t("resume", [])
        case .stop: t("stop", [])
        case .notify: t("notification", [])
        case .command: t("custom command", [])
        case .script: t("script", [])
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
