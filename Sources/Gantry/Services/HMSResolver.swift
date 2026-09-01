import Foundation

@MainActor
final class HMSResolver {
    static let shared = HMSResolver()
    private var cache: [String: [String: String]] = [:]

    private init() {}

    func description(for codes: [String], serial: String, language: AppLanguage) -> String? {
        let actionable = actionableCodes(codes, serial: serial, language: language)
        guard !actionable.isEmpty else { return nil }
        let prefix = String(serial.prefix(3)).uppercased()
        let languageCode = language == .pl ? "pl" : "en"
        let lookup = messages(prefix: prefix, languageCode: languageCode)
        for code in actionable {
            let normalized = normalize(code)
            if let message = lookup[normalized], !message.isEmpty { return message }
        }
        return actionable.first.map { "HMS \($0)" }
    }

    /// Bambu's catalog contains internal HMS markers with an intentionally empty description.
    /// Bambu Studio does not present those as user-facing faults, so Gantry suppresses them. Truly
    /// unknown codes remain actionable and keep their raw HMS fallback.
    func actionableCodes(_ codes: [String], serial: String, language: AppLanguage) -> [String] {
        guard !codes.isEmpty else { return [] }
        let prefix = String(serial.prefix(3)).uppercased()
        let languageCode = language == .pl ? "pl" : "en"
        let lookup = messages(prefix: prefix, languageCode: languageCode)
        return codes.filter { code in
            guard let knownMessage = lookup[normalize(code)] else { return true }
            return !knownMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func messages(prefix: String, languageCode: String) -> [String: String] {
        // The merged catalog is identical for every printer using the same UI language. Reuse it
        // across the whole fleet instead of parsing ~8 MB of Bambu Studio JSON once per serial.
        let cacheKey = "\(languageCode)-all-models"
        if let cached = cache[cacheKey] { return cached }
        let directory = URL(fileURLWithPath: "/Applications/BambuStudio.app/Contents/Resources/hms", isDirectory: true)
        let exactName = "hms_\(languageCode)_\(prefix).json"
        let discovered = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        // Model suffixes in Bambu Studio (20P, 094, 31B, …) are not serial prefixes. Prefer an
        // exact match when present, then merge all model catalogs for the selected language.
        let candidates = discovered
            .filter { $0.lastPathComponent.hasPrefix("hms_\(languageCode)_") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                if lhs.lastPathComponent == exactName { return true }
                if rhs.lastPathComponent == exactName { return false }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
        var result: [String: String] = [:]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectMessages(in: root, languageCode: languageCode, result: &result)
        }
        cache[cacheKey] = result
        return result
    }

    private func collectMessages(in value: Any, languageCode: String, result: inout [String: String]) {
        if let array = value as? [[String: Any]] {
            for item in array {
                if let code = item["ecode"] as? String,
                   let intro = item["intro"] as? String {
                    let key = normalize(code)
                    let message = intro.precomposedStringWithCanonicalMapping
                    // Prefer a non-empty description supplied by another model, but retain known
                    // empty entries so internal markers can be distinguished from unknown codes.
                    if result[key] == nil || (result[key]?.isEmpty == true && !message.isEmpty) {
                        result[key] = message
                    }
                } else {
                    collectMessages(in: item, languageCode: languageCode, result: &result)
                }
            }
        } else if let dictionary = value as? [String: Any] {
            if let localized = dictionary[languageCode] { collectMessages(in: localized, languageCode: languageCode, result: &result) }
            for (key, child) in dictionary where key != languageCode {
                collectMessages(in: child, languageCode: languageCode, result: &result)
            }
        } else if let array = value as? [Any] {
            for child in array { collectMessages(in: child, languageCode: languageCode, result: &result) }
        }
    }

    private func normalize(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "").uppercased()
    }
}
