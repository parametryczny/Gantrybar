import Foundation

enum BambuStudioConfig {
    struct Device {
        let serial: String
        let accessCode: String
        let host: String?
    }

    /// Every printer Bambu Studio has a saved access code for, paired with its last known IP
    /// address from the same config so printers can be imported without a network scan.
    static func devices() throws -> [Device] {
        let root = try configRoot()
        let codes = stringDictionary(root["access_code"])
            .merging(stringDictionary(root["user_access_code"])) { _, preferred in preferred }
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
        guard !codes.isEmpty else {
            throw BambuStudioConfigError(localizedText(
                "Bambu Studio nie ma zapisanych kodów drukarek.",
                "Bambu Studio has no saved printer access codes.",
                "Bambu Studio enthält keine gespeicherten Drucker-Zugriffscodes."
            ))
        }
        let addresses = stringDictionary(root["ip_address"])
        return codes.map { serial, code in
            let host = addresses[serial]
            return Device(serial: serial, accessCode: code, host: host?.isEmpty == false ? host : nil)
        }
    }

    static func accessCodes() throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: devices().map { ($0.serial, $0.accessCode) })
    }

    private static func configRoot() throws -> [String: Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BambuStudio/BambuStudio.conf")
        guard let data = try? Data(contentsOf: url) else {
            throw BambuStudioConfigError(localizedText(
                "Nie znaleziono konfiguracji Bambu Studio.",
                "The Bambu Studio configuration was not found.",
                "Die Bambu-Studio-Konfiguration wurde nicht gefunden."
            ))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BambuStudioConfigError(localizedText(
                "Nie udało się odczytać konfiguracji Bambu Studio.",
                "The Bambu Studio configuration could not be read.",
                "Die Bambu-Studio-Konfiguration konnte nicht gelesen werden."
            ))
        }
        return root
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.reduce(into: [:]) { result, item in
            if let code = item.value as? String { result[item.key] = code }
        }
    }
}

struct BambuStudioConfigError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
