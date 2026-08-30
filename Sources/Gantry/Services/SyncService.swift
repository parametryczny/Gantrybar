import Foundation
import Combine
import Security

// MARK: - Wire models

/// A printer as shared over LAN sync. Secrets are deliberately omitted: Bambu access codes stay in
/// each Mac's Keychain, and Klipper/Prusa apiKey is never sent.
struct SyncPrinter: Codable, Sendable {
    var serial: String
    var name: String
    var model: String
    var host: String
    var kind: PrinterKind
    var port: Int?
}

/// The subset of app preferences that travel between machines. Display and notification prefs only,
/// reconciled whole as last-write-wins by `updatedAt`. Security-sensitive toggles (developer mode,
/// script permission) are intentionally excluded so they can never be flipped on remotely.
struct SyncSettings: Codable, Sendable {
    var updatedAt: Date
    var theme: String
    var language: String
    var panelTransparency: String
    var spoolbaseEnabled: Bool
    var webDashboardEnabled: Bool
    var monochrome: Bool?   // optional so a peer on an older build (which omits it) still decodes
    var autoUpdate: Bool
    var cardShowFileName: Bool
    var cardShowProgress: Bool
    var cardShowTemperatures: Bool
    var cardShowFilaments: Bool
    var notifyFinished: Bool
    var notifyError: Bool
    var notifyPaused: Bool
    var notifyLowFilament: Bool
    var notifyHumidity: Bool
}

/// One machine's full sync payload. Exchanged in both directions; each side merges what it receives.
struct SyncSnapshot: Codable, Sendable {
    var protocolVersion: Int = 1
    var deviceID: String
    var deviceName: String
    var generatedAt: Date
    var spools: [PhysicalSpool]
    var usageEvents: [SpoolUsageEvent]
    var catalog: [Filament]
    var printers: [SyncPrinter]
    var settings: SyncSettings?
}

/// A paired machine we sync with, addressed by host (or host:port) on the LAN.
struct SyncPeer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var lastSyncAt: Date?
    var lastError: String?
}

// MARK: - Service

/// Two-way LAN sync of Spoolbase, the printer list and display/notification settings between a user's
/// own computers (macOS, Windows, Linux share the same `/api/sync` contract). No cloud: each computer
/// talks HTTP directly to paired peers on the local network, authorised by a single shared token the
/// user copies from one machine to the other. See GantryWebServer for the endpoint.
@MainActor
final class SyncService {
    /// Set by GantryApp at launch so the Settings window can reach the live service without threading
    /// the dependency through every initializer.
    static weak var shared: SyncService?

    private unowned let store: PrinterStore
    private let defaults = UserDefaults.standard

    let deviceID: String
    private(set) var token: String
    private(set) var peers: [SyncPeer]
    private var settingsClock: Date
    private var isApplyingRemote = false
    private var cancellables = Set<AnyCancellable>()

    /// Fired after peers, token or merged data change so the Settings UI can refresh.
    var onChange: (() -> Void)?

    var deviceName: String { Host.current().localizedName ?? "Mac" }

    init(store: PrinterStore) {
        self.store = store
        if let existing = defaults.string(forKey: Keys.deviceID) {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
        if let existing = defaults.string(forKey: Keys.token) {
            token = existing
        } else {
            token = Self.makeToken()
            defaults.set(token, forKey: Keys.token)
        }
        peers = (defaults.data(forKey: Keys.peers).flatMap { try? JSONDecoder().decode([SyncPeer].self, from: $0) }) ?? []
        settingsClock = (defaults.object(forKey: Keys.settingsClock) as? Date) ?? .distantPast

        // Treat any local settings change as advancing our settings clock, so the newer side wins on
        // the next merge. Suppressed while we are applying a remote snapshot to avoid a feedback loop.
        AppSettings.shared.objectWillChange
            .sink { [weak self] in
                guard let self, !self.isApplyingRemote else { return }
                self.settingsClock = .now
                self.defaults.set(self.settingsClock, forKey: Keys.settingsClock)
            }
            .store(in: &cancellables)
    }

    private enum Keys {
        static let deviceID = "sync-device-id"
        static let token = "sync-token"
        static let peers = "sync-peers"
        static let settingsClock = "sync-settings-updated-at"
    }

    // MARK: Token & peers

    /// A readable shared secret, e.g. "GANTRY-3F9A-1C7E-B204-88DA". Groups of hex for easy copying.
    /// The "GANTRY" prefix is a cosmetic label only; the entropy lives in the hex groups.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let groups = stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }
        return (["GANTRY"] + groups).joined(separator: "-")
    }

    func regenerateToken() {
        token = Self.makeToken()
        defaults.set(token, forKey: Keys.token)
        onChange?()
    }

    /// Pairs with another Mac. On the second machine the user pastes this pair's shared token (via
    /// `setToken`) and the peer's address; both then trust the same token.
    func setToken(_ newToken: String) {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        token = trimmed
        defaults.set(token, forKey: Keys.token)
        onChange?()
    }

    @discardableResult
    func addPeer(address rawAddress: String) -> SyncPeer? {
        let address = Self.normalize(address: rawAddress)
        guard !address.isEmpty, !peers.contains(where: { $0.address == address }) else { return nil }
        let peer = SyncPeer(name: address, address: address)
        peers.append(peer)
        savePeers()
        onChange?()
        syncNow()
        return peer
    }

    func removePeer(_ id: UUID) {
        peers.removeAll { $0.id == id }
        savePeers()
        onChange?()
    }

    /// Accepts "gantry.local", "192.168.1.20", "host:8787" and normalises to a host[:port] with the
    /// default web-server port when none was given. Strips any scheme the user may have pasted.
    static func normalize(address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where value.lowercased().hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { return "" }
        if !value.contains(":") { value += ":\(GantryWebServer.port)" }
        return value
    }

    private func savePeers() {
        if let data = try? JSONEncoder().encode(peers) { defaults.set(data, forKey: Keys.peers) }
    }

    private func updatePeer(_ id: UUID, _ transform: (inout SyncPeer) -> Void) {
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
        transform(&peers[index])
        savePeers()
        onChange?()
    }

    // MARK: Snapshot build / apply

    func localSnapshot() -> SyncSnapshot {
        SyncSnapshot(
            deviceID: deviceID,
            deviceName: deviceName,
            generatedAt: .now,
            spools: SpoolbaseShared.spools.spools,
            usageEvents: SpoolbaseShared.spools.usageEvents,
            catalog: SpoolbaseShared.filaments.filaments,
            printers: store.printers.map {
                SyncPrinter(serial: $0.serial, name: $0.name, model: $0.model, host: $0.host, kind: $0.kind, port: $0.port)
            },
            settings: currentSettings()
        )
    }

    func apply(_ remote: SyncSnapshot) {
        var changed = false
        changed = SpoolbaseShared.spools.mergeRemote(spools: remote.spools, usageEvents: remote.usageEvents) || changed
        changed = SpoolbaseShared.filaments.mergeRemote(remote.catalog) || changed
        changed = store.mergeRemote(printers: remote.printers) || changed
        if let settings = remote.settings, settings.updatedAt > settingsClock {
            applySettings(settings)
            settingsClock = settings.updatedAt
            defaults.set(settingsClock, forKey: Keys.settingsClock)
            changed = true
        }
        if changed { onChange?() }
    }

    private func currentSettings() -> SyncSettings {
        let s = AppSettings.shared
        return SyncSettings(
            updatedAt: settingsClock,
            theme: s.theme.rawValue,
            language: s.language.rawValue,
            panelTransparency: s.panelTransparency.rawValue,
            spoolbaseEnabled: s.spoolbaseEnabled,
            webDashboardEnabled: s.webDashboardEnabled,
            monochrome: s.monochrome,
            autoUpdate: s.autoUpdate,
            cardShowFileName: s.cardShowFileName,
            cardShowProgress: s.cardShowProgress,
            cardShowTemperatures: s.cardShowTemperatures,
            cardShowFilaments: s.cardShowFilaments,
            notifyFinished: s.notifyFinished,
            notifyError: s.notifyError,
            notifyPaused: s.notifyPaused,
            notifyLowFilament: s.notifyLowFilament,
            notifyHumidity: s.notifyHumidity
        )
    }

    private func applySettings(_ v: SyncSettings) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let s = AppSettings.shared
        if let theme = AppTheme(rawValue: v.theme) { s.theme = theme }
        if let language = AppLanguage(rawValue: v.language) { s.language = language }
        if let transparency = PanelTransparency(rawValue: v.panelTransparency) { s.panelTransparency = transparency }
        s.spoolbaseEnabled = v.spoolbaseEnabled
        s.webDashboardEnabled = v.webDashboardEnabled
        if let m = v.monochrome { s.monochrome = m }
        s.autoUpdate = v.autoUpdate
        s.cardShowFileName = v.cardShowFileName
        s.cardShowProgress = v.cardShowProgress
        s.cardShowTemperatures = v.cardShowTemperatures
        s.cardShowFilaments = v.cardShowFilaments
        s.notifyFinished = v.notifyFinished
        s.notifyError = v.notifyError
        s.notifyPaused = v.notifyPaused
        s.notifyLowFilament = v.notifyLowFilament
        s.notifyHumidity = v.notifyHumidity
    }

    // MARK: Sync over HTTP (pull peer, then push ours)

    func syncNow() {
        guard !peers.isEmpty else { return }
        let snapshot = localSnapshot()
        for peer in peers {
            Task { await self.sync(peer: peer, pushing: snapshot) }
        }
    }

    private func sync(peer: SyncPeer, pushing snapshot: SyncSnapshot) async {
        do {
            if let remote = try await exchange(peer: peer, method: "GET", body: nil) {
                apply(remote)
            }
            _ = try await exchange(peer: peer, method: "POST", body: snapshot)
            updatePeer(peer.id) { $0.lastSyncAt = .now; $0.lastError = nil }
        } catch {
            updatePeer(peer.id) { $0.lastError = (error as NSError).localizedDescription }
        }
    }

    private func exchange(peer: SyncPeer, method: String, body: SyncSnapshot?) async throws -> SyncSnapshot? {
        guard let url = URL(string: "http://\(peer.address)/api/sync") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw NSError(domain: "Gantry.Sync", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Token odrzucony (401)."])
        }
        return (try? Self.decoder.decode(SyncSnapshot.self, from: data))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// Validates a bearer token presented by an incoming request (constant-ish comparison).
    nonisolated func authorize(bearer: String?) -> Bool {
        guard let bearer else { return false }
        let presented = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        return presented == tokenSnapshot
    }

    /// A copy of the token readable from the server's non-main-actor parsing without hopping actors.
    nonisolated private var tokenSnapshot: String {
        UserDefaults.standard.string(forKey: Keys.token) ?? ""
    }
}
