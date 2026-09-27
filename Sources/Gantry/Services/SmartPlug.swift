import Foundation

/// A Wi-Fi socket or one outlet of a power strip that feeds a printer, so Gantry can cut or restore
/// its power: from the card, from an automation, from Telegram, or all printers at once in an
/// emergency. Stored per printer serial in the shared defaults; a password or Home Assistant token
/// goes to the same secret store as printer access codes, never into the defaults.
///
/// The JSON shape is shared with the Windows and GNU/Linux ports (`smart-plugs-v1`).
struct SmartPlug: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Tasmota firmware (Sonoff, Athom, Nous, NodeMCU strips): `/cm?cmnd=Power<n> On`.
        case tasmota
        /// Shelly Gen1 (Plug S, 1PM, 2.5): `/relay/<n>?turn=on`, HTTP basic auth.
        case shelly
        /// Shelly Gen2 and later (Plus, Pro, Gen3/4): `/rpc/Switch.Set?id=<n>&on=true`, digest auth.
        case shellyRPC
        /// Any switch, light or input_boolean in Home Assistant, through its REST API and a token.
        /// Covers TP-Link Tapo/Kasa, IKEA, Zigbee strips and everything else HA already controls.
        case homeAssistant
        /// Two plain URLs, for anything else that switches on a GET.
        case http

        var title: String {
            switch self {
            case .tasmota: "Tasmota"
            case .shelly: "Shelly Gen1"
            case .shellyRPC: "Shelly Plus / Pro / Gen3"
            case .homeAssistant: "Home Assistant"
            case .http: Localization.t("Custom URLs")
            }
        }
    }

    var kind: Kind
    /// IP or host of the socket. For Home Assistant the base URL, e.g. `http://192.168.1.10:8123`.
    var host: String = ""
    /// Outlet on a strip or multi-relay device, counted from 1 as printed on the strip.
    var channel: Int = 1
    /// Home Assistant entity, e.g. `switch.printer_x1c`.
    var entityID: String?
    var onURL: String?
    var offURL: String?
    /// Login for Tasmota/Shelly web auth. The password itself is in `SmartPlugSecrets`.
    var username: String?
    /// Switch the socket off this many minutes after a print finishes, when the printer has not
    /// started another one. Nil: never on its own.
    var autoOffMinutes: Int?
    /// Take part in "switch everything off". Off for a socket that also feeds something else.
    var includeInEmergency: Bool = true

    init(kind: Kind, host: String = "", channel: Int = 1) {
        self.kind = kind; self.host = host; self.channel = channel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .http
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        channel = max(1, (try? c.decodeIfPresent(Int.self, forKey: .channel)) ?? 1)
        entityID = try? c.decodeIfPresent(String.self, forKey: .entityID)
        onURL = try? c.decodeIfPresent(String.self, forKey: .onURL)
        offURL = try? c.decodeIfPresent(String.self, forKey: .offURL)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        autoOffMinutes = try? c.decodeIfPresent(Int.self, forKey: .autoOffMinutes)
        includeInEmergency = (try? c.decodeIfPresent(Bool.self, forKey: .includeInEmergency)) ?? true
    }

    /// What is missing before this socket can be switched, or nil when it is complete.
    var problem: String? {
        switch kind {
        case .tasmota, .shelly, .shellyRPC:
            return host.trimmingCharacters(in: .whitespaces).isEmpty ? Localization.t("Enter the socket's IP address.") : nil
        case .homeAssistant:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return Localization.t("Enter the Home Assistant address.") }
            if (entityID ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return Localization.t("Enter the Home Assistant entity, e.g. switch.printer.") }
            return nil
        case .http:
            return (onURL ?? "").isEmpty || (offURL ?? "").isEmpty ? Localization.t("Enter both URLs.") : nil
        }
    }

    /// The HTTP request that switches the socket, or reads it when `on` is nil.
    func request(on: Bool?, secret: String?) -> URLRequest? {
        func base() -> String {
            let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let withScheme = raw.contains("://") ? raw : "http://\(raw)"
            return withScheme.hasSuffix("/") ? String(withScheme.dropLast()) : withScheme
        }
        var request: URLRequest?
        switch kind {
        case .tasmota:
            let command = "Power\(channel)" + (on.map { $0 ? " On" : " Off" } ?? "")
            var parts = URLComponents(string: base() + "/cm")
            var query = [URLQueryItem(name: "cmnd", value: command)]
            if let secret, !secret.isEmpty {
                query.append(URLQueryItem(name: "user", value: (username?.isEmpty == false ? username : "admin")))
                query.append(URLQueryItem(name: "password", value: secret))
            }
            parts?.queryItems = query
            request = parts?.url.map { URLRequest(url: $0) }
        case .shelly:
            var parts = URLComponents(string: base() + "/relay/\(channel - 1)")
            if let on { parts?.queryItems = [URLQueryItem(name: "turn", value: on ? "on" : "off")] }
            request = parts?.url.map { URLRequest(url: $0) }
        case .shellyRPC:
            let method = on == nil ? "Switch.GetStatus" : "Switch.Set"
            var parts = URLComponents(string: base() + "/rpc/\(method)")
            var query = [URLQueryItem(name: "id", value: String(channel - 1))]
            if let on { query.append(URLQueryItem(name: "on", value: on ? "true" : "false")) }
            parts?.queryItems = query
            request = parts?.url.map { URLRequest(url: $0) }
        case .homeAssistant:
            let entity = (entityID ?? "").trimmingCharacters(in: .whitespaces)
            if let on {
                // homeassistant.turn_on/off works for switch, light, fan and input_boolean alike.
                guard let url = URL(string: base() + "/api/services/homeassistant/turn_\(on ? "on" : "off")") else { return nil }
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": entity])
                request = r
            } else {
                let path = entity.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entity
                request = URL(string: base() + "/api/states/\(path)").map { URLRequest(url: $0) }
            }
            if let secret, !secret.isEmpty { request?.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        case .http:
            guard let on else { return nil }
            let raw = (on ? onURL : offURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            request = URL(string: raw).map { URLRequest(url: $0) }
        }
        request?.timeoutInterval = 6
        request?.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Reads "on" out of a device's reply. Nil when the reply does not say.
    static func parseState(kind: Kind, channel: Int, data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func word(_ value: Any?) -> Bool? {
            switch value {
            case let text as String:
                switch text.lowercased() { case "on", "true", "1": return true; case "off", "false", "0": return false; default: return nil }
            case let number as NSNumber: return number.boolValue
            default: return nil
            }
        }
        switch kind {
        case .tasmota: return word(object["POWER\(channel)"]) ?? (channel == 1 ? word(object["POWER"]) : nil)
        case .shelly: return word(object["ison"])
        case .shellyRPC: return word(object["output"])
        case .homeAssistant: return word(object["state"])
        case .http: return nil
        }
    }
}

enum SmartPlugError: LocalizedError {
    case notConfigured(String)
    case http(Int)
    case unauthorized
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let why): why
        case .http(let code): Localization.t("The socket answered with HTTP {0}.", code)
        case .unauthorized: Localization.t("The socket refused the login. Check the password or token.")
        case .transport(let message): message
        }
    }
}

/// Sends the request, answering an HTTP auth challenge (basic for Shelly Gen1, digest for Gen2+)
/// with the saved login.
final class SmartPlugClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let plug: SmartPlug
    private let secret: String?

    init(plug: SmartPlug, secret: String?) { self.plug = plug; self.secret = secret }

    /// Switches the socket and returns the state it reports afterwards, when it reports one.
    @discardableResult
    func set(_ on: Bool) async throws -> Bool? {
        if let problem = plug.problem { throw SmartPlugError.notConfigured(problem) }
        guard let request = plug.request(on: on, secret: secret) else { throw SmartPlugError.notConfigured(Localization.t("The address is not a valid URL.")) }
        let data = try await send(request)
        return SmartPlug.parseState(kind: plug.kind, channel: plug.channel, data: data)
    }

    func state() async throws -> Bool? {
        if let problem = plug.problem { throw SmartPlugError.notConfigured(problem) }
        guard let request = plug.request(on: nil, secret: secret) else { return nil }
        return SmartPlug.parseState(kind: plug.kind, channel: plug.channel, data: try await send(request))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            if code == 401 || code == 403 { throw SmartPlugError.unauthorized }
            guard (200..<300).contains(code) else { throw SmartPlugError.http(code) }
            return data
        } catch let error as SmartPlugError {
            throw error
        } catch {
            throw SmartPlugError.transport(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              challenge.previousFailureCount == 0, let secret, !secret.isEmpty else {
            return (.performDefaultHandling, nil)
        }
        let user = plug.username?.isEmpty == false ? plug.username! : "admin"
        return (.useCredential, URLCredential(user: user, password: secret, persistence: .forSession))
    }
}

/// Where sockets are kept. The secret goes to `AccessCodeStore` under its own key, so it is in the
/// Keychain (or the local store) exactly like a printer's access code.
@MainActor
final class SmartPlugStore {
    static let shared = SmartPlugStore()
    static let didChange = Notification.Name("GantrySmartPlugsDidChange")
    private let key = "smart-plugs-v1"
    private var all: [String: SmartPlug] = [:]

    private init() {
        if let data = BambuDefaults.shared.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: SmartPlug].self, from: data) { all = decoded }
    }

    func plug(for serial: String) -> SmartPlug? { all[serial] }
    var serials: [String] { Array(all.keys) }
    var isEmpty: Bool { all.isEmpty }

    func set(_ plug: SmartPlug?, secret: String?, for serial: String) {
        if let plug { all[serial] = plug } else { all.removeValue(forKey: serial) }
        if let data = try? JSONEncoder().encode(all) { BambuDefaults.shared.set(data, forKey: key) }
        let secretKey = Self.secretKey(serial)
        if let secret, !secret.isEmpty, plug != nil { try? AccessCodeStore.save(accessCode: secret, for: secretKey) }
        else { AccessCodeStore.delete(for: secretKey) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func secret(for serial: String) -> String? { AccessCodeStore.accessCode(for: Self.secretKey(serial)) }

    func client(for serial: String) -> SmartPlugClient? {
        all[serial].map { SmartPlugClient(plug: $0, secret: secret(for: serial)) }
    }

    /// Kept apart from printer serials so removing a printer's code never touches it, and the reverse.
    static func secretKey(_ serial: String) -> String { "smart-plug:\(serial)" }
}
