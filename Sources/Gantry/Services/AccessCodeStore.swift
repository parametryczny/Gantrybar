import Foundation
#if KEYCHAIN_STORAGE
import Security
#endif

@MainActor
enum AccessCodeStore {
    #if KEYCHAIN_STORAGE
    static let modeName = "Keychain"
    static let usesKeychain = true
    // All codes live in ONE keychain item (a JSON serial→code map). macOS shows its access
    // prompt per keychain item, so a single item means at most one prompt no matter how many
    // printers are saved — instead of one prompt per printer with per-serial items.
    private static let service = "pl.gantry.printer-access-codes.v3"
    // Pre-rebrand consolidated item; read once so upgrades keep their saved codes.
    private static let legacyConsolidatedService = "pl.bambubar.printer-access-codes.v3"
    private static let account = "all"
    // Older builds stored one item per serial; migration folds these in and deletes them.
    private static let legacyService = "pl.bambubar.printer-access-code.v2"

    // Read once per launch; save/delete keep it in sync, so the keychain is touched minimally.
    private static var cache: [String: String]?

    static func save(accessCode: String, for serial: String) throws {
        guard !accessCode.isEmpty else { throw AccessCodeStoreError.invalidData }
        var codes = allCodes()
        guard codes[serial] != accessCode else { return }
        codes[serial] = accessCode
        try persist(codes)
    }

    static func accessCode(for serial: String) -> String? {
        let code = allCodes()[serial]
        return (code?.isEmpty == false) ? code : nil
    }

    static func readAccessCode(for serial: String) throws -> String {
        guard let value = accessCode(for: serial) else { throw AccessCodeStoreError.missing }
        return value
    }

    static func delete(for serial: String) {
        var codes = allCodes()
        guard codes.removeValue(forKey: serial) != nil else { return }
        try? persist(codes)
    }

    private static func allCodes() -> [String: String] {
        if let cache { return cache }
        let codes = readItem() ?? [:]
        cache = codes
        return codes
    }

    private static func readItem() -> [String: String]? {
        if let dict = readItem(service: service) { return dict }
        // Migrate codes saved by the pre-rebrand app into the Gantry item.
        if let legacy = readItem(service: legacyConsolidatedService) {
            try? persist(legacy)
            return legacy
        }
        return nil
    }

    private static func readItem(service: String) -> [String: String]? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    private static func persist(_ codes: [String: String]) throws {
        cache = codes
        let data = try JSONSerialization.data(withJSONObject: codes)
        let query = baseQuery()
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw AccessCodeStoreError.keychain("update", status) }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw AccessCodeStoreError.keychain("add", status) }
        }
    }

    private static func baseQuery(service: String = AccessCodeStore.service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// One-time migration into the single consolidated item. Reads codes only from the plaintext
    /// UserDefaults build (a prompt-free source) and writes them into the app's own keychain item,
    /// then wipes the plaintext copy. Obsolete per-serial items are deleted by service — a delete
    /// needs no data read, so it never triggers a keychain prompt.
    static func migrateLegacyPlaintextCodes() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService
        ] as CFDictionary)

        let legacyKey = "printer-access-codes-local-v1"
        guard let legacy = BambuDefaults.shared.dictionary(forKey: legacyKey) as? [String: String],
              !legacy.isEmpty else { return }
        var codes = allCodes()
        for (serial, code) in legacy where !code.isEmpty && codes[serial] == nil {
            codes[serial] = code
        }
        BambuDefaults.shared.removeObject(forKey: legacyKey)
        try? persist(codes)
    }
    #else
    static let modeName = "Local"
    static let usesKeychain = false
    private static let defaults = BambuDefaults.shared
    private static let storageKey = "printer-access-codes-local-v1"

    static func save(accessCode: String, for serial: String) throws {
        var values = storedValues()
        guard values[serial] != accessCode else { return }
        values[serial] = accessCode
        defaults.set(values, forKey: storageKey)
    }

    static func accessCode(for serial: String) -> String? {
        storedValues()[serial]
    }

    static func readAccessCode(for serial: String) throws -> String {
        guard let value = accessCode(for: serial), !value.isEmpty else {
            throw AccessCodeStoreError.missing
        }
        return value
    }

    static func delete(for serial: String) {
        var values = storedValues()
        values.removeValue(forKey: serial)
        defaults.set(values, forKey: storageKey)
    }

    private static func storedValues() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    /// No-op in the plaintext build; the Keychain build overrides this to migrate legacy codes.
    static func migrateLegacyPlaintextCodes() {}
    #endif
}

enum AccessCodeStoreError: LocalizedError {
    case missing
    case invalidData
    #if KEYCHAIN_STORAGE
    case keychain(String, OSStatus)
    #endif

    var errorDescription: String? {
        switch self {
        case .missing:
            "Brak zapisanego kodu dostępu. Użyj importu z Bambu Studio albo edytuj drukarkę."
        case .invalidData:
            "Zapisanego kodu dostępu nie można odczytać."
        #if KEYCHAIN_STORAGE
        case .keychain(let operation, let status):
            "Keychain \(operation): \(SecCopyErrorMessageString(status, nil) as String? ?? "błąd") (\(status))"
        #endif
        }
    }
}
