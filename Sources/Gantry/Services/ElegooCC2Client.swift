import Foundation
import Network

final class ElegooCC2Client: PrinterConnection, @unchecked Sendable {
    private let printer: SavedPrinter
    private let accessCode: String
    private let onEvent: @Sendable (MQTTClient.Event) -> Void
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Data(), telemetry = PrinterTelemetry(), status: [String: Any] = [:]
    private var timer: DispatchSourceTimer?, stopped = false, registered = false
    private var sequence = 0
    private var lastStatusID: Int?, statusGaps = 0, heartbeatTicks = 0
    private let clientID: String
    private let requestID: String

    init(printer: SavedPrinter, accessCode: String, onEvent: @escaping @Sendable (MQTTClient.Event) -> Void) {
        self.printer = printer; self.accessCode = accessCode.isEmpty ? "123456" : accessCode; self.onEvent = onEvent
        queue = DispatchQueue(label: "pl.gantry.elegoo.cc2.\(printer.serial)")
        clientID = "1_PC_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))"
        requestID = "\(clientID)_req"
    }

    func start() { queue.async { [weak self] in self?.connect() } }
    func stop() { queue.async { [weak self] in self?.stopped = true; self?.timer?.cancel(); self?.timer = nil; self?.connection?.cancel(); self?.connection = nil } }

    func sendMethod(_ method: Int, params: [String: Any] = [:]) {
        guard let parameters = try? JSONSerialization.data(withJSONObject: params) else { return }
        queue.async { [weak self] in
            guard let self, registered else { return }
            let decoded = (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? [:]
            sequence += 1
            publish(topic: "elegoo/\(printer.serial)/\(clientID)/api_request", object: ["id": sequence, "method": method, "params": decoded])
        }
    }

    private func connect() {
        stopped = false; registered = false
        guard let port = NWEndpoint.Port(rawValue: UInt16(printer.port ?? 1883)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(printer.host), port: port, using: .tcp); self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(MQTTCodec.connect(clientID: self.clientID, username: "elegoo", password: self.accessCode)); self.receive()
            case .failed(let error), .waiting(let error): if !self.stopped { self.onEvent(.disconnected(error.localizedDescription)) }
            case .cancelled: if !self.stopped { self.onEvent(.disconnected(nil)) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.handlePackets() }
            if let error { if !self.stopped { self.onEvent(.disconnected(error.localizedDescription)) }; return }
            if complete { if !self.stopped { self.onEvent(.disconnected(nil)) }; return }
            self.receive()
        }
    }

    private func handlePackets() {
        for packet in MQTTCodec.extractPackets(from: &buffer) {
            switch packet.type >> 4 {
            case 2:
                guard packet.body.count >= 2, packet.body[1] == 0 else { onEvent(.disconnected("Drukarka Elegoo odrzuciła kod dostępu")); connection?.cancel(); return }
                send(MQTTCodec.subscribe(topic: "elegoo/\(printer.serial)/\(requestID)/register_response"))
                publish(topic: "elegoo/\(printer.serial)/api_register", object: ["client_id": clientID, "request_id": requestID])
            case 3:
                guard let topic = MQTTCodec.publishTopic(header: packet.type, body: packet.body),
                      let payload = MQTTCodec.publishPayload(header: packet.type, body: packet.body),
                      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                if topic.hasSuffix("/register_response") {
                    let error = object["error"] as? String ?? "fail"
                    guard error == "ok" else { onEvent(.disconnected(error.contains("too many") ? "Limit klientów Elegoo został przekroczony" : "Rejestracja Elegoo: \(error)")); connection?.cancel(); return }
                    registered = true
                    send(MQTTCodec.subscribe(topic: "elegoo/\(printer.serial)/api_status", packetID: 2))
                    send(MQTTCodec.subscribe(topic: "elegoo/\(printer.serial)/\(clientID)/api_response", packetID: 3))
                    onEvent(.connected); startTimer(); sendMethod(1002); sendMethod(2005)
                } else { handle(object) }
            default: break
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        guard let method = (object["method"] as? NSNumber)?.intValue,
              let result = object["result"] as? [String: Any] else { return }
        if method == 6000 || method == 6008 || method == 1002 {
            if method == 6000 || method == 6008, let eventID = (object["id"] as? NSNumber)?.intValue {
                if let lastStatusID {
                    statusGaps = eventID == lastStatusID + 1 ? 0 : statusGaps + 1
                    if statusGaps >= 5 { sendMethod(1002); statusGaps = 0 }
                }
                lastStatusID = eventID
            }
            status = ElegooStatusParser.deepMerge(status, result)
            telemetry = ElegooStatusParser.cc2(result: status, previous: telemetry); onEvent(.telemetry(telemetry))
        } else if method == 2005 {
            telemetry = ElegooStatusParser.canvas(result: result, previous: telemetry); onEvent(.telemetry(telemetry))
        }
    }

    private func startTimer() {
        timer?.cancel(); let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publish(topic: "elegoo/\(self.printer.serial)/\(self.clientID)/api_request", object: ["type": "PING"])
            self.heartbeatTicks += 1
            if self.heartbeatTicks % 10 == 0 { self.sendMethod(1002); self.sendMethod(2005) }
        }
        timer.resume(); self.timer = timer
    }
    private func publish(topic: String, object: [String: Any]) { guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }; send(MQTTCodec.publish(topic: topic, payload: data)) }
    private func send(_ data: Data) { connection?.send(content: data, completion: .contentProcessed { _ in }) }
}
