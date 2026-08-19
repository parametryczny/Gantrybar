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

        // A script starting with a shebang (e.g. `#!/usr/bin/env python3`) is written to a temp file
        // and executed directly, so the kernel honours the interpreter — this is how pasting raw
        // Python (or any language) works. Otherwise the content runs as a zsh command.
        let tempURL: URL?
        if script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#!") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-\(id.uuidString)")
            do {
                try script.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            } catch { return false }
            tempURL = url
            process.executableURL = url
        } else {
            tempURL = nil
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script]
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
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
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            return false
        }
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
        processes.removeValue(forKey: id)
    }
}
