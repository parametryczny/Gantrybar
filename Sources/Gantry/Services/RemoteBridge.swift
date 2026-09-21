import Foundation
import Combine
import CryptoKit

/// Gantry's bridge to a page the user hosts themselves (web/api.php in this repository).
///
/// Gantry always dials out: every few seconds it posts the fleet to that page and takes back whatever
/// the page queued for it. Nothing listens on the Mac, nothing is opened on the router, and the page
/// never learns a printer's address or access code. Both directions are signed with one shared key,
/// so a page that does not hold the key cannot queue a command, and Gantry ignores an answer that is
/// not signed with it.
///
/// The mode is the switch in Settings and it is enforced here, not on the page: in `view` every queued
/// command is refused and told so, and the page hides its own controls to match. `control` still obeys
/// the printer itself, so a Bambu machine outside LAN Only mode refuses the command the way it does
/// everywhere else in Gantry.
@MainActor
final class RemoteBridge {
    enum Mode: String, CaseIterable {
        case off, view, control

        var allowsControl: Bool { self == .control }
    }

    struct Status: Equatable {
        var lastSync: Date?
        var lastError: String?
        var watchers = 0
        var printersSent = 0
    }

    /// How often Gantry calls the page. Faster while somebody has it open, so a pause feels immediate.
    private static let idleInterval: TimeInterval = 10
    private static let watchedInterval: TimeInterval = 3
    /// A camera frame is skipped rather than sent when the JPEG is bigger than this, so one printer
    /// cannot turn the bridge into a video upload.
    private static let maxFrameBytes = 900_000
    /// Everything the page may ask for, with the range Gantry clamps it to before the printer sees it.
    private static let temperatureRange = 0...300
    private static let bedRange = 0...120
    private static let fanRange = 0...100
    private static let speedLevels = 1...4

    private weak var store: PrinterStore?
    private var timer: Timer?
    private var syncing = false
    /// Outcomes of the commands from the previous round, reported on the next one so the page can show
    /// what happened instead of guessing.
    private var results: [[String: Any]] = []
    /// Camera frames captured after the page asked for them, sent with the next sync.
    private var frames: [String: String] = [:]
    /// The object layout the page asked for, sent once and then dropped.
    private var objectLists: [String: [[String: Any]]] = [:]
    private var capturing: Set<String> = []

    private(set) var status = Status() { didSet { if status != oldValue { statusChanged.send(status) } } }
    let statusChanged = PassthroughSubject<Status, Never>()

    private let deviceID: String

    /// The instance the app built, so Settings can show what the bridge is doing and ask it to try
    /// again now instead of waiting for the next tick.
    private(set) static weak var current: RemoteBridge?

    init(store: PrinterStore) {
        self.store = store
        // A stable id for this Mac, so a page can tell two Gantry installations apart.
        if let existing = UserDefaults.standard.string(forKey: "remote-bridge-device") {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "remote-bridge-device")
            deviceID = fresh
        }
        Self.current = self
    }

    // MARK: Lifecycle

    static func mode(_ settings: AppSettings = .shared) -> Mode {
        Mode(rawValue: settings.remoteBridgeMode) ?? .off
    }

    /// Starts, stops or re-times the bridge to match Settings. Safe to call as often as the settings
    /// change: an unchanged configuration keeps the timer it already has.
    func syncWithSettings() {
        let settings = AppSettings.shared
        let configured = !settings.remoteBridgeURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.remoteBridgeKey.trimmingCharacters(in: .whitespaces).isEmpty
        guard Self.mode(settings) != .off, configured, Build.hasExtras else {
            stop()
            return
        }
        schedule(interval: status.watchers > 0 ? Self.watchedInterval : Self.idleInterval)
        Task { await self.syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        frames.removeAll()
        results.removeAll()
        status = Status()
    }

    private func schedule(interval: TimeInterval) {
        if let timer, abs(timer.timeInterval - interval) < 0.01 { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        // .common so a menu being open or a window being dragged does not stall the bridge.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: One round trip

    func syncNow() async {
        guard !syncing, let store else { return }
        let settings = AppSettings.shared
        let mode = Self.mode(settings)
        guard mode != .off, let url = Self.endpoint(from: settings.remoteBridgeURL) else { return }
        let key = settings.remoteBridgeKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        syncing = true
        defer { syncing = false }

        var body = snapshot(store: store, mode: mode)
        body["results"] = results
        body["cameras"] = frames
        body["objects"] = objectLists
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        // Exactly what this round carries. A camera frame or an object list that lands while the POST
        // is in flight belongs to the next round, and clearing wholesale would throw it away unsent.
        let sentResults = Set(results.compactMap { $0["id"] as? String })
        let sentFrames = Array(frames.keys)
        let sentObjects = Array(objectLists.keys)

        do {
            let answer = try await post(data, to: url, key: key)
            results.removeAll { ($0["id"] as? String).map(sentResults.contains) ?? true }
            for serial in sentFrames { frames.removeValue(forKey: serial) }
            for serial in sentObjects { objectLists.removeValue(forKey: serial) }
            var next = status
            next.lastSync = Date()
            next.lastError = nil
            next.watchers = answer["watchers"] as? Int ?? 0
            next.printersSent = store.printers.count
            status = next
            schedule(interval: next.watchers > 0 ? Self.watchedInterval : Self.idleInterval)

            for command in answer["commands"] as? [[String: Any]] ?? [] {
                if let result = run(command, store: store, mode: mode) { results.append(result) }
            }
            for serial in answer["wantCameras"] as? [String] ?? [] { captureFrame(serial: serial, store: store) }
        } catch {
            var next = status
            next.lastError = (error as? BridgeError)?.text ?? error.localizedDescription
            status = next
        }
    }

    enum BridgeError: Error {
        case http(Int)
        case badAnswer
        case refused(String)

        @MainActor var text: String {
            switch self {
            case .http(let code): AppSettings.shared.t("The page answered {0}.", code)
            case .badAnswer: AppSettings.shared.t("That address answered, but not with Gantry data. Check that api.php from the web/ folder is really there.")
            case .refused(let reason): reason
            }
        }
    }

    /// One signed POST. The signature covers the exact bytes sent, so nothing between the two ends can
    /// add a printer, change a temperature or replay yesterday's command.
    private func post(_ data: Data, to url: URL, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Gantry/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(deviceID, forHTTPHeaderField: "X-Gantry-Device")
        request.setValue(Self.signature(for: data, key: key), forHTTPHeaderField: "X-Gantry-Signature")
        request.httpBody = data
        let (answerData, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // The page names its own refusals (a key that does not match, a clock too far off).
            if let object = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
               let reason = object["error"] as? String {
                throw BridgeError.refused(reason)
            }
            throw BridgeError.http(code)
        }
        guard let object = try? JSONSerialization.jsonObject(with: answerData) as? [String: Any],
              object["ok"] as? Bool == true else { throw BridgeError.badAnswer }
        return object
    }

    /// The address the user typed, turned into the one the bridge actually calls. People paste the
    /// address of the page, not of its api.php, and an address without a scheme at all; both are what
    /// they meant, so Gantry finishes the job instead of failing on a login page that is not JSON.
    static func endpoint(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var url = URL(string: text), url.host != nil else { return nil }
        let last = url.lastPathComponent.lowercased()
        // The address of the page itself is the one people have in the browser bar, so it is the one
        // they paste. api.php sits next to it.
        if last == "index.php" {
            url.deleteLastPathComponent()
            url.appendPathComponent("api.php")
        } else if !last.hasSuffix(".php") {
            url.appendPathComponent("api.php")
        }
        return url
    }

    static func signature(for data: Data, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A key the user can paste into the page's config.php. Hex, because it travels through PHP, a URL
    /// bar and a text field on the way there.
    static func freshKey() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: What the page is told

    /// JSONSerialization wants NSNull where a number is simply not reported. Wrapping every optional
    /// in `as Any` does the same thing while making the compiler complain at each field.
    private static func json(_ value: Int?) -> Any { value ?? NSNull() }
    private static func json(_ value: Double?) -> Any { value ?? NSNull() }

    private func snapshot(store: PrinterStore, mode: Mode) -> [String: Any] {
        var printers: [[String: Any]] = []
        for printer in store.printers {
            let t = store.telemetry[printer.serial] ?? PrinterTelemetry()
            // What this printer would accept right now, so the page can grey out what cannot work
            // instead of queueing a command that is refused two seconds later.
            let signingBlocked = printer.kind == .bambu && store.requiresSignedCommands(serial: printer.serial)
            let controllable = mode.allowsControl && (printer.kind == .bambu || printer.kind == .klipper) && !signingBlocked
            var groups: [[String: Any]] = []
            for (groupIndex, group) in t.filamentGroups.enumerated() {
                var slots: [[String: Any]] = []
                for (slotIndex, slot) in group.slots.enumerated() {
                    let location = SpoolLocation(printerSerial: printer.serial,
                                                 feeder: group.isExternal ? .ext : .ams,
                                                 amsIndex: groupIndex, slot: slotIndex)
                    let spool = AppSettings.shared.spoolbaseEnabled ? SpoolbaseShared.spools.spool(at: location) : nil
                    let definition = spool.flatMap { assigned in
                        SpoolbaseShared.filaments.filaments.first { $0.id == assigned.filamentDefinitionID }
                    }
                    slots.append([
                        "label": slot.label,
                        "material": slot.isPresent ? (slot.material ?? "") : (definition?.type ?? ""),
                        "colorHex": definition?.colorHex ?? slot.colorHex ?? "8E8E93",
                        "percent": Self.json(spool?.percent ?? slot.remainingPercent),
                        "grams": Self.json(spool.map { Int($0.remainingWeightGrams) }
                                           ?? slot.remainingWeightGrams.map { Int($0) }),
                        "active": slot.isActive
                    ])
                }
                groups.append([
                    "name": group.displayName, "external": group.isExternal,
                    "humidity": Self.json(group.humidityPercent), "temp": Self.json(group.temperatureCelsius),
                    "slots": slots
                ])
            }
            printers.append([
                "serial": printer.serial,
                "name": printer.name,
                "kind": printer.kind.rawValue,
                "model": printer.model,
                "state": t.state.rawValue,
                "progress": t.progress,
                "job": (t.state == .printing || t.state == .paused) ? (t.jobName ?? "") : "",
                "remainingMinutes": Self.json(t.remainingMinutes),
                "layer": Self.json(t.currentLayer),
                "totalLayers": Self.json(t.totalLayers),
                "nozzle": Self.json(t.nozzleTemperature),
                "nozzleTarget": Self.json(t.nozzleTargetTemperature),
                "bed": Self.json(t.bedTemperature),
                "bedTarget": Self.json(t.bedTargetTemperature),
                "chamber": Self.json(t.chamberTemperature),
                "fans": ["part": Self.json(t.partFanPercent), "aux": Self.json(t.auxFanPercent),
                         "chamber": Self.json(t.chamberFanPercent)],
                "speedLevel": Self.json(t.speedLevel),
                "speedPercent": Self.json(t.speedPercent),
                "hasCamera": printer.kind != .prusa,
                "controllable": controllable,
                "signingBlocked": signingBlocked,
                "offersSkipping": mode.allowsControl && store.offersObjectSkipping(serial: printer.serial),
                "groups": groups
            ])
        }
        return [
            "action": "sync",
            "device": deviceID,
            "deviceName": Host.current().localizedName ?? "Mac",
            "app": ["name": "Gantry", "version": Self.appVersion, "platform": "macOS"],
            "mode": mode.rawValue,
            "sentAt": Int(Date().timeIntervalSince1970),
            "printers": printers
        ]
    }

    // MARK: What the page may ask for

    /// Runs one queued command and says what happened. Every refusal carries a reason the page shows,
    /// because a control that silently does nothing is worse than one that says why. Nil means the
    /// answer cannot be given yet and will be sent when it is known (fetching the object list).
    private func run(_ command: [String: Any], store: PrinterStore, mode: Mode) -> [String: Any]? {
        let id = command["id"] as? String ?? ""
        let type = command["type"] as? String ?? ""
        let serial = command["serial"] as? String ?? ""
        func done() -> [String: Any] { ["id": id, "status": "done"] }
        func refuse(_ reason: String) -> [String: Any] { ["id": id, "status": "refused", "reason": reason] }

        guard mode.allowsControl else {
            return refuse(AppSettings.shared.t("Gantry is set to view only."))
        }
        guard let printer = store.printers.first(where: { $0.serial == serial }) else {
            return refuse(AppSettings.shared.t("Gantry no longer has this printer."))
        }
        if printer.kind == .bambu, store.requiresSignedCommands(serial: serial), type != "objects" {
            return refuse(AppSettings.shared.t("The printer only accepts commands signed by Bambu Connect. To control it from Gantry, turn on LAN Only mode and then Developer Mode on the printer."))
        }
        let value = (command["value"] as? NSNumber)?.intValue

        switch type {
        case "pause": store.runAutomation(Self.action(.pause), serial: serial)
        case "resume": store.runAutomation(Self.action(.resume), serial: serial)
        case "stop": store.runAutomation(Self.action(.stop), serial: serial)
        case "light": store.setChamberLight(command["value"] as? Bool ?? true, serial: serial)
        case "nozzle":
            guard let value else { return refuse(AppSettings.shared.t("Missing value.")) }
            store.setNozzleTemperature(serial: serial, celsius: Self.clamp(value, Self.temperatureRange))
        case "bed":
            guard let value else { return refuse(AppSettings.shared.t("Missing value.")) }
            store.setBedTemperature(serial: serial, celsius: Self.clamp(value, Self.bedRange))
        case "fan":
            guard let value, let index = (command["index"] as? NSNumber)?.intValue, (0...2).contains(index) else {
                return refuse(AppSettings.shared.t("Missing value."))
            }
            store.setFan(serial: serial, index: index, percent: Self.clamp(value, Self.fanRange))
        case "speed":
            guard let value else { return refuse(AppSettings.shared.t("Missing value.")) }
            store.setPrintSpeedLevel(serial: serial, level: Self.clamp(value, Self.speedLevels))
        case "objects":
            // Two steps on purpose: the layout is fetched from the printer, so it is loaded on demand
            // and travels with a later sync instead of being carried every few seconds for nobody.
            // The answer goes back when the printer has actually given it up, however long that takes.
            Task { @MainActor [weak self] in await self?.loadObjects(serial: serial, id: id, store: store) }
            return nil
        case "skip":
            let ids = Set((command["objects"] as? [String] ?? []).prefix(64))
            guard !ids.isEmpty else { return refuse(AppSettings.shared.t("Missing value.")) }
            guard store.offersObjectSkipping(serial: serial) else {
                return refuse(AppSettings.shared.t("This printer does not take object skipping."))
            }
            store.skipPrintObjects(serial: serial, ids: ids)
        default:
            return refuse(AppSettings.shared.t("Gantry does not know this command."))
        }
        return done()
    }

    private static func action(_ action: AutomationAction) -> PrinterAutomation {
        PrinterAutomation(name: "remote", trigger: .manual, action: action)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func loadObjects(serial: String, id: String, store: PrinterStore) async {
        switch await store.loadPrintObjectLayout(serial: serial) {
        case .loaded(let layout):
            objectLists[serial] = layout.objects.map { object in
                ["id": object.id, "name": object.name,
                 "skipped": layout.skippedObjectIDs.contains(object.id),
                 "current": layout.currentObjectID == object.id]
            }
            results.append(["id": id, "status": "done"])
        case .unavailable(let reason):
            objectLists[serial] = []
            results.append(["id": id, "status": "refused", "reason": reason])
        }
    }

    /// One frame, captured only because somebody has the page open and asked for this printer. It is
    /// sent with the next sync and then dropped: Gantry keeps no gallery and the page keeps one frame.
    private func captureFrame(serial: String, store: PrinterStore) {
        guard !capturing.contains(serial), frames[serial] == nil,
              let printer = store.printers.first(where: { $0.serial == serial }) else { return }
        capturing.insert(serial)
        Task { @MainActor [weak self] in
            let jpeg = await CameraSnapshot.capture(printer: printer, store: store)
            guard let self else { return }
            capturing.remove(serial)
            if let jpeg, jpeg.count <= Self.maxFrameBytes {
                frames[serial] = jpeg.base64EncodedString()
            }
        }
    }
}
