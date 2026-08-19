import Foundation

/// Persists per-printer automations (keyed by serial) in the shared defaults.
@MainActor
final class AutomationStore {
    static let shared = AutomationStore()
    private let defaults = BambuDefaults.shared
    private let key = "printer-automations-v1"
    private var all: [String: [PrinterAutomation]] = [:]

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: [PrinterAutomation]].self, from: data) {
            all = decoded
        }
    }

    func automations(for serial: String) -> [PrinterAutomation] { all[serial] ?? [] }

    func set(_ list: [PrinterAutomation], for serial: String) {
        if list.isEmpty { all.removeValue(forKey: serial) } else { all[serial] = list }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

/// Runs (and stops) user shell scripts for script-action automations, keyed by automation id so a
/// running script can be stopped from the UI.
@MainActor
final class ScriptRunner {
    static let shared = ScriptRunner()
    private var processes: [UUID: Process] = [:]

    func isRunning(_ id: UUID) -> Bool { processes[id] != nil }

    @discardableResult
    func run(_ id: UUID, script: String, onFinish: @escaping @MainActor (Int32) -> Void = { _ in }) -> Bool {
        stop(id)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.processes.removeValue(forKey: id)
                onFinish(status)
            }
        }
        do {
            try process.run()
            processes[id] = process
            return true
        } catch {
            return false
        }
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
        processes.removeValue(forKey: id)
    }
}
