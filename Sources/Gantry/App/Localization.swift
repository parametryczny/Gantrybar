import Foundation

/// Translation catalogs, keyed by the English source string the way gettext keys by msgid.
///
/// Three consequences worth knowing. A key missing from a catalog falls back to the English string
/// itself, so a forgotten entry degrades to readable text instead of showing `settings.launch` to the
/// user. English needs no catalog at all, because it *is* the key. And a new language is one file
/// dropped into `i18n/`: nothing here or in Settings enumerates languages by hand.
///
/// Each catalog names itself under the `@name` key ("Polski", "Deutsch"), so the Settings list needs
/// no table of language names in code. Keys starting with `@` are metadata, never lookup text.
enum Localization {
    /// A language the app can switch to. `en` is always present and always first.
    struct Language: Equatable, Sendable {
        let code: String
        let name: String
    }

    static let english = Language(code: "en", name: "English")

    /// Text for an English source string in the given language.
    static func text(_ english: String, language code: String) -> String {
        guard code != "en" else { return english }
        return table(for: code)[english] ?? english
    }

    /// Every language the app can offer: English plus one entry per catalog found on disk.
    static func available() -> [Language] {
        var found: [Language] = [english]
        for (code, url) in discovered().sorted(by: { $0.key < $1.key }) {
            guard code != "en" else { continue }
            let name = (loadTable(at: url)["@name"]) ?? code.uppercased()
            found.append(Language(code: code, name: name))
        }
        return found
    }

    /// Entry count for a language, used by the self-test; never needed at runtime.
    static func loadedCount(for code: String) -> Int { table(for: code).count }

    // MARK: Loading

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String: String]] = [:]

    private static func table(for code: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[code] { return cached }
        let loaded = discovered()[code].map(loadTable(at:)) ?? [:]
        cache[code] = loaded
        return loaded
    }

    private static func loadTable(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return parsed
    }

    /// Catalog files by language code, taking the first directory that has any.
    private static func discovered() -> [String: URL] {
        for directory in searchPaths() {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            let catalogs = files.filter { $0.pathExtension == "json" }
            if !catalogs.isEmpty {
                return Dictionary(catalogs.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                                  uniquingKeysWith: { first, _ in first })
            }
        }
        return [:]
    }

    private static func searchPaths() -> [URL] {
        var paths: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("i18n") {
            paths.append(bundled)
        }
        // Running from `swift run` there is no bundle, so fall back to the checkout.
        paths.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("i18n"))
        paths.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("i18n"))
        return paths
    }
}
