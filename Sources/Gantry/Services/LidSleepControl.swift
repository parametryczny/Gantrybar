import Foundation

/// The one thing keeping a Mac awake needs root for: the system's own `disablesleep`, which is what a
/// MacBook obeys when the lid is shut. A power assertion cannot reach it (see KeepAwake).
///
/// Gantry asks for it the same way Capsomnia does: once, with the user's admin password, it installs a
/// sudoers rule that allows exactly two command lines and nothing else. After that the switch and the
/// shortcut work with the lid shut, with no password and no root code of Gantry's own running in the
/// background.
///
/// The rule is deliberately as small as a rule can be:
///
///     <user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
///
/// One user, one absolute path, two complete argument lists, no wildcards. sudo matches the whole
/// command line, so this grant cannot be bent into running anything else. It is validated with visudo
/// before it is installed, so a mistake here can never lock the user out of sudo.
@MainActor
enum LidSleepControl {
    static let rulePath = "/etc/sudoers.d/gantry-keepawake"
    private static let pmset = "/usr/bin/pmset"

    /// Whether Gantry itself turned the system setting on, so it only ever turns off what it turned on.
    private(set) static var setByGantry = false

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: rulePath) }

    /// The exact file that gets installed. Kept as one function so the tests can read it.
    static func rule(for user: String = NSUserName()) -> String {
        """
        # Gantry: let this Mac stay awake with the lid shut, and nothing else.
        # Remove this file to take the permission away: sudo rm \(rulePath)
        \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1, \(pmset) -a disablesleep 0
        """
    }

    /// Carries the text the user should see, resolved where it is thrown. A LocalizedError would have
    /// to reach the catalog from whatever thread asked for the message, which is exactly the kind of
    /// hop Swift's concurrency rules refuse.
    struct Failure: Error {
        let message: String
        let wasCancelled: Bool

        init(message: String, wasCancelled: Bool = false) {
            self.message = message
            self.wasCancelled = wasCancelled
        }
    }

    /// Asks for the admin password once and installs the rule. The password goes to macOS's own
    /// authorisation dialog; Gantry never sees it.
    static func install() throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-keepawake-\(UUID().uuidString)")
        try rule().write(to: staging, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: staging) }
        let path = staging.path
        // visudo -cf first: an invalid file installed into sudoers.d breaks sudo for everything.
        try runAsAdministrator("/usr/sbin/visudo -cf '\(path)' && /usr/bin/install -m 0440 -o root -g wheel '\(path)' '\(rulePath)'")
    }

    static func remove() throws {
        setDisabled(false)
        try runAsAdministrator("/bin/rm -f '\(rulePath)'")
    }

    /// Turns the system setting on or off. Silent and instant once the rule is installed; without it
    /// the call simply fails and the caller stays with the ordinary lid-open promise.
    @discardableResult
    static func setDisabled(_ on: Bool) -> Bool {
        guard isInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never ask for a password. If the rule is gone, this fails instead of hanging on a prompt
        // nobody can answer from a menu-bar app.
        process.arguments = ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        setByGantry = on
        return true
    }

    /// Gives the system setting back if Gantry was the one holding it. Called when the switch goes off
    /// and when the app quits, so a closed-lid night cannot turn into a Mac that never sleeps again.
    static func releaseIfOurs() {
        guard setByGantry else { return }
        setDisabled(false)
    }

    private static func runAsAdministrator(_ command: String) throws {
        let source = "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        // -128 is the user closing the password dialog, which is an answer, not a fault.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            throw Failure(message: AppSettings.shared.t("Cancelled."), wasCancelled: true)
        }
        throw Failure(message: (error[NSAppleScript.errorMessage] as? String)
                      ?? AppSettings.shared.t("Cancelled."))
    }
}
