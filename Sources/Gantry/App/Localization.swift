import Foundation

/// The shipped translation catalog, keyed by the English source string the way gettext keys by msgid.
///
/// Two consequences worth knowing. A key that is missing from the catalog falls back to the English
/// string itself, so a forgotten entry degrades to readable text instead of showing `settings.launch`
/// to the user. And adding a language means adding one JSON file, without touching any call site.
///
/// The catalog is the repository's `i18n/pl.json`, copied into the bundle by scripts/build-app.sh.
enum Localization {
    /// Polish text for an English source string, or the string itself when the catalog has no entry.
    static func polish(for english: String) -> String { table[english] ?? english }

    /// Entries the catalog does not cover. Only used by the parity check, never at runtime.
    static var loadedCount: Int { table.count }

    private static let table: [String: String] = {
        for url in candidates() {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { continue }
            return parsed
        }
        return [:]
    }()

    private static func candidates() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "pl", withExtension: "json", subdirectory: "i18n") {
            urls.append(bundled)
        }
        if let flat = Bundle.main.url(forResource: "i18n-pl", withExtension: "json") {
            urls.append(flat)
        }
        // Running from `swift run` there is no bundle, so fall back to the checkout next to the binary.
        let executable = Bundle.main.bundleURL.deletingLastPathComponent()
        urls.append(executable.appendingPathComponent("i18n/pl.json"))
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("i18n/pl.json"))
        return urls
    }
}
