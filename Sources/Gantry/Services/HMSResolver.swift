import Foundation

@MainActor
final class HMSResolver {
    static let shared = HMSResolver()
    private var cache: [String: [String: String]] = [:]

    private init() {}

    func description(for codes: [String], serial: String, language: AppLanguage) -> String? {
        guard !codes.isEmpty else { return nil }
        let prefix = String(serial.prefix(3)).uppercased()
        let languageCode = language == .pl ? "pl" : "en"
        let lookup = messages(prefix: prefix, languageCode: languageCode)
        for code in codes {
            let normalized = normalize(code)
            if let message = lookup[normalized], !message.isEmpty { return message }
        }
        return codes.first.map { "HMS \($0)" }
    }

    private func messages(prefix: String, languageCode: String) -> [String: String] {
        let cacheKey = "\(languageCode)-\(prefix)"
        if let cached = cache[cacheKey] { return cached }
        let url = URL(fileURLWithPath: "/Applications/BambuStudio.app/Contents/Resources/hms/hms_\(languageCode)_\(prefix).json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            cache[cacheKey] = [:]
            return [:]
        }
        var result: [String: String] = [:]
        collectMessages(in: root, languageCode: languageCode, result: &result)
        cache[cacheKey] = result
        return result
    }

    private func collectMessages(in value: Any, languageCode: String, result: inout [String: String]) {
        if let array = value as? [[String: Any]] {
            for item in array {
                if let code = item["ecode"] as? String,
                   let intro = item["intro"] as? String,
                   !intro.isEmpty {
                    result[normalize(code)] = intro.precomposedStringWithCanonicalMapping
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
