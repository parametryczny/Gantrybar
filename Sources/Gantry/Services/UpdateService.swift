import AppKit
import Foundation

/// Checks GitHub Releases for a newer Gantry and, on request, downloads it, swaps the running
/// app bundle in place and relaunches. macOS only.
enum UpdateService {
    struct Release {
        let version: String
        let tag: String
        let downloadURL: URL
        let pageURL: URL
    }

    enum UpdateError: LocalizedError {
        case network
        case parse
        case noAsset
        case download
        case unpack
        case signature

        var errorDescription: String? {
            // errorDescription is nonisolated, so read the language directly rather than via
            // the @MainActor AppSettings.
            (BambuDefaults.shared.string(forKey: "app-language") ?? "pl") == "pl" ? polish : english
        }
        private var polish: String {
            switch self {
            case .network: "Nie udało się połączyć z GitHubem."
            case .parse: "Nie udało się odczytać informacji o wydaniu."
            case .noAsset: "Wydanie nie zawiera pliku aplikacji dla macOS."
            case .download: "Pobieranie aktualizacji nie powiodło się."
            case .unpack: "Nie udało się rozpakować aktualizacji."
            case .signature: "Podpis pobranej aktualizacji nie zgadza się z bieżącą aplikacją. Instalację przerwano — pobierz wydanie ręcznie ze strony."
            }
        }
        private var english: String {
            switch self {
            case .network: "Could not reach GitHub."
            case .parse: "Could not read the release information."
            case .noAsset: "The release has no macOS app download."
            case .download: "Downloading the update failed."
            case .unpack: "Could not unpack the update."
            case .signature: "The downloaded update is not signed by the same identity as the current app. Installation was aborted — download the release manually from the page."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/parametryczny/gantrybar/releases/latest") else {
            throw UpdateError.network
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Gantry", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw UpdateError.network }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { throw UpdateError.parse }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pageURL = (root["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/parametryczny/gantrybar/releases")!

        let assets = root["assets"] as? [[String: Any]] ?? []
        func assetURL(matching predicate: (String) -> Bool) -> URL? {
            for asset in assets {
                if let name = asset["name"] as? String, predicate(name),
                   let link = asset["browser_download_url"] as? String, let url = URL(string: link) {
                    return url
                }
            }
            return nil
        }
        guard let downloadURL = assetURL(matching: { $0.contains("macOS-Local") && $0.hasSuffix(".zip") })
            ?? assetURL(matching: { $0.contains("macOS") && $0.hasSuffix(".zip") }) else {
            throw UpdateError.noAsset
        }
        return Release(version: version, tag: tag, downloadURL: downloadURL, pageURL: pageURL)
    }

    /// `true` when `candidate` is a strictly higher semantic version than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Downloads the release, replaces the running bundle and relaunches via a detached helper.
    static func downloadAndInstall(_ release: Release) async throws {
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await URLSession.shared.download(from: release.downloadURL) }
        catch { throw UpdateError.download }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }

        let fileManager = FileManager.default
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Gantry-update-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent("update.zip")
        try? fileManager.removeItem(at: zip)
        try fileManager.moveItem(at: temporary, to: zip)

        let extractDir = work.appendingPathComponent("extract", isDirectory: true)
        try runDitto(["-x", "-k", zip.path, extractDir.path])
        guard let newApp = try? fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpack
        }

        // Refuse to install anything not signed by the same identity as the running app. HTTPS
        // already authenticates GitHub as the source; this additionally ensures a tampered or
        // foreign-signed asset can't silently replace the app, since the local signing key that
        // produced the running build is never on the release server.
        try verifySignatureMatchesCurrentApp(newApp)

        let destination = Bundle.main.bundleURL
        let script = work.appendingPathComponent("install.sh")
        let contents = """
        #!/bin/bash
        trap '' HUP
        PID="$1"; NEW="$2"; DEST="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        /bin/rm -rf "$DEST"
        /usr/bin/ditto "$NEW" "$DEST"
        /usr/bin/xattr -cr "$DEST"
        /usr/bin/open "$DEST"
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path]
        try helper.run()

        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }

    /// Verifies the downloaded bundle's code signature is intact (`codesign --verify --strict`)
    /// and that its leaf signing certificate matches the running app's. Any mismatch — an
    /// ad-hoc, unsigned, or differently-signed bundle — aborts the install.
    private static func verifySignatureMatchesCurrentApp(_ newApp: URL) throws {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "--deep", "--", newApp.path]
        verify.standardOutput = Pipe()
        verify.standardError = Pipe()
        do { try verify.run() } catch { throw UpdateError.signature }
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw UpdateError.signature }

        guard let current = signingAuthority(of: Bundle.main.bundleURL),
              let candidate = signingAuthority(of: newApp),
              current == candidate else {
            throw UpdateError.signature
        }
    }

    /// Returns the leaf-certificate authority (`Authority=` line) reported by `codesign -dvv`,
    /// or nil for an unsigned/ad-hoc bundle (which then fails the equality check above).
    private static func signingAuthority(of url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvv", "--", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { return nil }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("Authority=") {
            return String(line.dropFirst("Authority=".count))
        }
        return nil
    }
}
