import Foundation
import Network
import Security
import CCommonCrypto

enum AnycubicStatusParser {
    static func parse(_ data: Data, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var value = previous; var changed = false
        let type = root["type"] as? String ?? ""
        let body = root["data"] as? [String: Any] ?? [:]
        func number(_ item: Any?) -> Double? { (item as? NSNumber)?.doubleValue ?? Double(item as? String ?? "") }
        func integer(_ item: Any?) -> Int? { number(item).map(Int.init) }
        func state(_ item: Any?) -> PrinterState {
            switch String(describing: item ?? "").lowercased() {
            case "printing", "running", "prepare", "working": return .printing
            case "pause", "paused", "pausing": return .paused
            case "done", "finished", "complete", "completed", "success": return .finished
            case "error", "failed", "failure", "abnormal": return .error
            default: return .idle
            }
        }
        func project(_ item: [String: Any], reportState: Any?) {
            value.state = state(reportState)
            if let progress = integer(item["progress"]) { value.progress = max(0, min(100, progress)) }
            // Kobra S1 reports both print_time and remain_time in minutes.
            if let minutes = integer(item["remain_time"]) { value.remainingMinutes = max(0, minutes) }
            if item.keys.contains("curr_layer") { value.currentLayer = integer(item["curr_layer"]) }
            if item.keys.contains("total_layers") { value.totalLayers = integer(item["total_layers"]) }
            if item.keys.contains("filename") { value.jobName = (item["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            changed = true
        }
        if type == "info" {
            value.state = state(body["state"]); changed = true
            let temp = body["temp"] as? [String: Any] ?? [:]
            if temp.keys.contains("curr_nozzle_temp") { value.nozzleTemperature = number(temp["curr_nozzle_temp"]) }
            if temp.keys.contains("target_nozzle_temp") { value.nozzleTargetTemperature = number(temp["target_nozzle_temp"]) }
            if temp.keys.contains("curr_hotbed_temp") { value.bedTemperature = number(temp["curr_hotbed_temp"]) }
            if temp.keys.contains("target_hotbed_temp") { value.bedTargetTemperature = number(temp["target_hotbed_temp"]) }
            if temp.keys.contains("curr_chamber_temp") { value.chamberTemperature = number(temp["curr_chamber_temp"]) }
            if let fan = integer(body["fan_speed_pct"]) { value.partFanPercent = fan }
            if let fan = integer(body["aux_fan_speed_pct"]) { value.auxFanPercent = fan }
            if let fan = integer(body["box_fan_level"]) { value.chamberFanPercent = fan }
            if let speed = integer(body["print_speed_mode"]) { value.speedLevel = speed }
            if let job = body["project"] as? [String: Any] { project(job, reportState: body["state"]) }
        } else if type == "tempature" {
            if body.keys.contains("curr_nozzle_temp") { value.nozzleTemperature = number(body["curr_nozzle_temp"]); changed = true }
            if body.keys.contains("target_nozzle_temp") { value.nozzleTargetTemperature = number(body["target_nozzle_temp"]); changed = true }
            if body.keys.contains("curr_hotbed_temp") { value.bedTemperature = number(body["curr_hotbed_temp"]); changed = true }
            if body.keys.contains("target_hotbed_temp") { value.bedTargetTemperature = number(body["target_hotbed_temp"]); changed = true }
        } else if type == "print" { project(body, reportState: root["state"]) }
        else if type == "fan" {
            if let fan = integer(body["fan_speed_pct"]) { value.partFanPercent = fan; changed = true }
            if let fan = integer(body["aux_fan_speed_pct"]) { value.auxFanPercent = fan; changed = true }
            if let fan = integer(body["box_fan_level"]) { value.chamberFanPercent = fan; changed = true }
        }
        else if type == "multiColorBox", let boxes = body["multi_color_box"] as? [[String: Any]] {
            var groups: [FilamentGroup] = []
            for (boxIndex, box) in boxes.enumerated() {
                let loaded = integer(box["loaded_slot"]), rawSlots = box["slots"] as? [[String: Any]] ?? []
                var indexed: [Int: [String: Any]] = [:]
                for slot in rawSlots { indexed[integer(slot["index"]) ?? 0] = slot }
                // Current ACE Pro reports four positions; accepting the highest reported index also
                // keeps Gantry compatible with firmware variants that expose a larger box.
                let capacity = max(4, (indexed.keys.max() ?? -1) + 1)
                let slots = (0..<capacity).map { slotIndex -> FilamentSlot in
                    let slot = indexed[slotIndex] ?? [:], present = (integer(slot["status"]) ?? 0) > 0
                    var color: String?
                    if let rgb = slot["color"] as? [NSNumber], rgb.count >= 3 {
                        color = String(format: "%02X%02X%02XFF", rgb[0].intValue, rgb[1].intValue, rgb[2].intValue)
                    }
                    let prefix = boxIndex < 26 ? String(UnicodeScalar(65 + boxIndex)!) : "B\(boxIndex + 1)-"
                    return FilamentSlot(id: "ace-\(boxIndex)-\(slotIndex)", label: "\(prefix)\(slotIndex + 1)",
                        material: present ? slot["type"] as? String : nil, colorHex: present ? color : nil,
                        remainingPercent: nil, isActive: present && loaded == slotIndex)
                }
                groups.append(FilamentGroup(id: "ace-\(boxIndex)", sourceType: .ams,
                    displayName: boxIndex == 0 ? "ACE Pro" : "ACE Pro \(boxIndex + 1)", declaredCapacity: capacity,
                    humidityPercent: nil, temperatureCelsius: number(box["temp"]), isExternal: false, slots: slots))
            }
            if !groups.isEmpty { value.filamentGroups = groups; value.amsSlots = groups.flatMap(\.legacyAMSSlots); changed = true }
        }
        value.nozzles = []
        return changed ? value : nil
    }
}

private struct AnycubicCredentials: Sendable {
    let broker: String, username: String, password: String, modeID: String, deviceID: String
}

private enum AnycubicBootstrap {
    static func discover(host: String, port: Int) async throws -> AnycubicCredentials {
        guard let infoURL = URL(string: "http://\(host):\(port)/info") else { throw Error.badResponse }
        let (infoData, _) = try await URLSession.shared.data(from: infoURL)
        guard let info = try JSONSerialization.jsonObject(with: infoData) as? [String: Any] else { throw Error.badResponse }
        if info["ctrlType"] as? String == "cloud" { throw Error.lanMode }
        guard let token = info["token"] as? String, token.count >= 32,
              let control = info["ctrlInfoUrl"] as? String, var parts = URLComponents(string: control) else { throw Error.badResponse }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000), nonce = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let first = md5(String(token.prefix(16))), sign = md5("\(first)\(timestamp)\(nonce)")
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "ts", value: "\(timestamp)"),
            URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "did", value: UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased())]
        guard let url = parts.url else { throw Error.badResponse }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data()
        let (controlData, _) = try await URLSession.shared.data(for: request)
        guard let response = try JSONSerialization.jsonObject(with: controlData) as? [String: Any],
              (response["code"] as? NSNumber)?.intValue == 200,
              let body = response["data"] as? [String: Any], let encrypted = body["info"] as? String,
              let localToken = body["token"] as? String,
              let clear = decrypt(encrypted: encrypted, key: String(token.dropFirst(16).prefix(16)), iv: localToken),
              let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any],
              let broker = object["broker"] as? String, let username = object["username"] as? String,
              let password = object["password"] as? String, let deviceID = object["deviceId"] as? String,
              let modeID = (object["modeId"] ?? object["modelId"]) as? String else { throw Error.badResponse }
        return AnycubicCredentials(broker: broker, username: username, password: password, modeID: modeID, deviceID: deviceID)
    }

    private static func md5(_ string: String) -> String {
        let data = Data(string.utf8); var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func decrypt(encrypted: String, key: String, iv: String) -> Data? {
        guard let input = Data(base64Encoded: encrypted) else { return nil }
        let keyData = Data(key.utf8), ivData = Data(iv.utf8.prefix(16)) + Data(repeating: 0, count: max(0, 16 - iv.utf8.count))
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity), length = 0
        let status = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in keyData.withUnsafeBytes { keyBytes in ivData.withUnsafeBytes { ivBytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress, source.baseAddress, input.count,
                    out.baseAddress, capacity, &length)
        }}}}
        guard status == kCCSuccess else { return nil }; output.count = length; return output
    }

    enum Error: LocalizedError { case lanMode, badResponse
        var errorDescription: String? { self == .lanMode ? "Włącz tryb LAN w ustawieniach drukarki Anycubic." : "Nie udało się pobrać konfiguracji LAN Anycubic." }
    }
}

final class AnycubicS1Client: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter, onEvent: @Sendable (MQTTClient.Event) -> Void
    private let queue: DispatchQueue; private var connection: NWConnection?, buffer = Data(), telemetry = PrinterTelemetry()
    private var timer: DispatchSourceTimer?, stopped = false, baseTopic = ""
    init(printer: SavedPrinter, onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer; self.onEvent = onEvent; queue = DispatchQueue(label: "pl.gantry.anycubic.\(printer.serial)")
    }
    func start() { stopped = false; Task { [weak self] in
        guard let self else { return }
        do { let credentials = try await AnycubicBootstrap.discover(host: printer.host, port: printer.port ?? 18910); queue.async { self.connect(credentials) } }
        catch { onEvent(.disconnected(error.localizedDescription)) }
    }}
    func stop() { queue.async { [weak self] in self?.stopped = true; self?.timer?.cancel(); self?.connection?.cancel(); self?.connection = nil } }
    func sendPrint(_ action: String) { publish(type: "print", action: action) }
    func setLight(_ enabled: Bool) { publish(type: "light", action: "control", data: ["type": 2, "status": enabled ? 1 : 0, "brightness": 100]) }

    private func connect(_ credentials: AnycubicCredentials) {
        guard let url = URL(string: credentials.broker), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 9883)) else { onEvent(.disconnected("Nieprawidłowy broker MQTT Anycubic")); return }
        let tls = NWProtocolTLS.Options(); sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())); self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.send(MQTTCodec.connect(clientID: "Gantry-\(UUID().uuidString.prefix(8))", username: credentials.username, password: credentials.password)); self.receive() }
            if case .failed(let error) = state, !self.stopped { self.onEvent(.disconnected(error.localizedDescription)) }
        }
        baseTopic = "anycubic/anycubicCloud/v1/web/printer/\(credentials.modeID)/\(credentials.deviceID)"
        connection.start(queue: queue)
    }
    private func receive() { connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
        guard let self else { return }; if let data { buffer.append(data); handlePackets() }
        if let error, !stopped { onEvent(.disconnected(error.localizedDescription)); return }; if complete { return }; receive()
    }}
    private func handlePackets() { for packet in MQTTCodec.extractPackets(from: &buffer) {
        switch packet.type >> 4 {
        case 2:
            guard packet.body.count >= 2, packet.body[1] == 0 else { onEvent(.disconnected("Anycubic odrzucił połączenie MQTT")); return }
            let suffix = baseTopic.split(separator: "/"); guard suffix.count >= 2 else { return }
            let mode = suffix[suffix.count - 2], device = suffix.last!
            send(MQTTCodec.subscribe(topic: "anycubic/anycubicCloud/v1/printer/+/\(mode)/\(device)/#"))
            send(MQTTCodec.subscribe(topic: "anycubic/anycubicCloud/v1/+/public/\(mode)/\(device)/+/report", packetID: 2))
            onEvent(.connected); queryAll(); startTimer()
        case 3:
            if let payload = MQTTCodec.publishPayload(header: packet.type, body: packet.body), let updated = AnycubicStatusParser.parse(payload, previous: telemetry) { telemetry = updated; onEvent(.telemetry(updated)) }
        default: break
        }
    }}
    private func queryAll() { publish(type: "info", action: "query"); publish(type: "light", action: "query"); publish(type: "multiColorBox", action: "getInfo"); publish(type: "video", action: "startCapture") }
    private func publish(type: String, action: String, data: Any? = nil) {
        let object: [String: Any] = ["type": type, "action": action, "timestamp": Int64(Date().timeIntervalSince1970 * 1000), "msgid": UUID().uuidString, "data": data ?? NSNull()]
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        queue.async { [weak self] in guard let self, !baseTopic.isEmpty else { return }; send(MQTTCodec.publish(topic: "\(baseTopic)/\(type)", payload: payload)) }
    }
    private func startTimer() { let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now() + 30, repeating: 30); timer.setEventHandler { [weak self] in self?.send(MQTTCodec.ping()) }; timer.resume(); self.timer = timer }
    private func send(_ data: Data) { connection?.send(content: data, completion: .contentProcessed { _ in }) }
}
