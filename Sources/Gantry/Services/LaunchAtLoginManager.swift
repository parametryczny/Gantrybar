import Foundation

enum LaunchAtLoginManager {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/pl.gantry.monitor.plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if isEnabled { try FileManager.default.removeItem(at: agentURL) }
            return
        }
        let appPath = Bundle.main.bundleURL.standardizedFileURL.path
        guard appPath.hasSuffix(".app"), FileManager.default.fileExists(atPath: appPath) else {
            throw LaunchAtLoginError("Nie udało się ustalić ścieżki Gantry.app.")
        }
        let directory = agentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let propertyList: [String: Any] = [
            "Label": "pl.gantry.monitor",
            "ProgramArguments": ["/usr/bin/open", appPath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": "/private/tmp/pl.gantry.login.log",
            "StandardErrorPath": "/private/tmp/pl.gantry.login.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: agentURL, options: .atomic)
    }
}

struct LaunchAtLoginError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
