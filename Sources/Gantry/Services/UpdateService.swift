import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer Gantry and, on request, downloads it, swaps the running
/// app bundle in place and relaunches. macOS only.
enum UpdateService {
    struct Release {
        let version: String
        let tag: String
        let downloadURL: URL
        let pageURL: URL
        let sha256: String
    }

    enum UpdateError: LocalizedError {
        case network
        case parse
        case noAsset
        case download
        case checksum
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
            case .checksum: "Suma kontrolna pobranej aktualizacji jest nieprawidłowa. Instalację przerwano."
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
            case .checksum: "The downloaded update checksum is invalid. Installation was aborted."
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
        func releaseAsset(matching predicate: (String) -> Bool) -> (URL, String)? {
            for asset in assets {
                if let name = asset["name"] as? String, predicate(name),
                   let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                   let digest = asset["digest"] as? String,
                   digest.lowercased().hasPrefix("sha256:") {
                    return (url, String(digest.dropFirst("sha256:".count)).lowercased())
                }
            }
            return nil
        }
        // Pick the zip matching THIS install's signing variant, so the signature check below passes: a
        // "Gantry Keychain.app" pulls the Keychain zip, a plain "Gantry.app" pulls the Local zip. Fall
        // back to any macOS zip for older releases that shipped only one.
        let isKeychain = Bundle.main.bundleURL.deletingPathExtension()
            .lastPathComponent.localizedCaseInsensitiveContains("Keychain")
        let variantTag = isKeychain ? "macOS-Keychain" : "macOS-Local"
        guard let asset = releaseAsset(matching: { $0.contains(variantTag) && $0.hasSuffix(".zip") })
            ?? releaseAsset(matching: {
                $0.contains("macOS") && $0.hasSuffix(".zip")
                    && !$0.localizedCaseInsensitiveContains("LITE")
            }) else {
            throw UpdateError.noAsset
        }
        return Release(version: version, tag: tag, downloadURL: asset.0, pageURL: pageURL,
                       sha256: asset.1)
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
        guard let data = try? Data(contentsOf: temporary, options: .mappedIfSafe) else {
            throw UpdateError.download
        }
        let downloadedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard downloadedHash == release.sha256 else { throw UpdateError.checksum }

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

        // Refuse to install anything not signed by the same identity as the running app.
        try verifySignatureMatchesCurrentApp(newApp)

        let destination = Bundle.main.bundleURL
        let script = work.appendingPathComponent("install.sh")
        let contents = """
        #!/bin/bash
        trap '' HUP
        PID="$1"; NEW="$2"; DEST="$3"
        BACKUP="${DEST}.gantry-update-backup"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        /bin/rm -rf "$BACKUP"
        if ! /bin/mv "$DEST" "$BACKUP"; then
          /usr/bin/open "$DEST"
          exit 1
        fi
        if /usr/bin/ditto "$NEW" "$DEST"; then
          /usr/bin/xattr -cr "$DEST"
          /usr/bin/open "$DEST"
          /bin/rm -rf "$BACKUP"
        else
          /bin/rm -rf "$DEST"
          /bin/mv "$BACKUP" "$DEST"
          /usr/bin/open "$DEST"
          exit 1
        fi
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

    /// Requires the same leaf certificate and bundle identity as the running app. The ZIP itself is
    /// first matched against GitHub's SHA-256 digest. Gantry releases use a stable self-signed
    /// identity, so codesign reports CSSMERR_TP_NOT_TRUSTED for an otherwise intact release; that
    /// single trust-chain result is accepted for compatibility with existing installations.
    private static func verifySignatureMatchesCurrentApp(_ newApp: URL) throws {
        guard let current = signingLeafHash(of: Bundle.main.bundleURL),
              let candidate = signingLeafHash(of: newApp),
              current == candidate else {
            throw UpdateError.signature
        }

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "--deep", "--", newApp.path]
        verify.standardOutput = Pipe()
        let errorPipe = Pipe()
        verify.standardError = errorPipe
        do { try verify.run() } catch { throw UpdateError.signature }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        verify.waitUntilExit()
        if verify.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            guard message.contains("CSSMERR_TP_NOT_TRUSTED") else {
                throw UpdateError.signature
            }
        }

        // Also require the same product identity; the certificate signs both full and LITE builds.
        guard bundleIdentifier(of: newApp) == Bundle.main.bundleIdentifier else {
            throw UpdateError.signature
        }
    }

    /// Returns the certificate hash embedded in the designated requirement. Unlike `Authority=`,
    /// this remains available for a deliberately untrusted self-signed certificate.
    private static func signingLeafHash(of url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dr-", "--", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { return nil }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        guard let range = text.range(of: #"certificate leaf = H\"([0-9A-Fa-f]+)\""#,
                                     options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match.split(separator: "\"").dropFirst().first.map { String($0).lowercased() }
    }

    private static func bundleIdentifier(of app: URL) -> String? {
        guard let bundle = Bundle(url: app) else { return nil }
        return bundle.bundleIdentifier
    }
}
