import Foundation
import Network
import OSLog
import Security

final class MQTTClient: PrinterConnection, @unchecked Sendable {
    private static let logger = Logger(subsystem: "pl.bambubar.app", category: "MQTT")
    enum Event: Sendable {
        case connected
        case telemetry(PrinterTelemetry)
        case disconnected(String?)
        case localNetworkDenied
    }

    private let printer: SavedPrinter
    private let accessCode: String
    private let queue: DispatchQueue
    private let onEvent: @Sendable (Event) -> Void
    private var connection: NWConnection?
    private var buffer = Data()
    private var telemetry = PrinterTelemetry()
    private var pingTimer: DispatchSourceTimer?
    private var connectTimeout: DispatchWorkItem?
    private var stopped = false
    private var certificateMismatch = false
    private var disconnectReported = false
    private var telemetryLogged = false

    init(printer: SavedPrinter, accessCode: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.printer = printer
        self.accessCode = accessCode
        self.onEvent = onEvent
        self.queue = DispatchQueue(label: "pl.bambubar.mqtt.\(printer.serial)")
    }

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.connectTimeout?.cancel()
            self.connectTimeout = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        stopped = false
        certificateMismatch = false
        disconnectReported = false
        telemetryLogged = false
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trustReference, completion in
            guard let self else { completion(false); return }
            let trust = sec_trust_copy_ref(trustReference).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                completion(false)
                return
            }
            let certificateData = SecCertificateCopyData(leaf) as Data
            let validation = CertificatePinStore.shared.validate(
                certificateData: certificateData,
                for: self.printer.serial
            )
            self.certificateMismatch = validation == .mismatch
            completion(validation.accepted)
        }, queue)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.serviceClass = .responsiveData
        // Default MQTTs port 8883, or a custom one (e.g. a socat tunnel forwarding several printers
        // through one host on different ports). TLS/cert pinning is unaffected — the tunnel just
        // forwards TCP, so the printer still presents its own certificate.
        let portValue = UInt16(exactly: printer.port ?? 8883) ?? 8883
        guard let port = NWEndpoint.Port(rawValue: portValue) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(printer.host), port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.reportDisconnected("Przekroczono czas połączenia z drukarką")
            self.connection?.cancel()
        }
        connectTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            Self.logger.notice("TLS ready")
            let clientID = "BambuBar-\(UUID().uuidString.prefix(8))"
            send(MQTTCodec.connect(clientID: clientID, username: "bblp", password: accessCode))
            receiveNext()
        case .failed(let error):
            connectTimeout?.cancel()
            reportDisconnected(certificateMismatch ? certificateMismatchMessage : error.localizedDescription)
        case .waiting(let error):
            connectTimeout?.cancel()
            if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                Self.logger.error("Local network permission denied")
                disconnectReported = true
                onEvent(.localNetworkDenied)
            } else {
                reportDisconnected(certificateMismatch ? certificateMismatchMessage : "Brak połączenia: \(error.localizedDescription)")
            }
            connection?.cancel()
        case .cancelled:
            if !stopped { reportDisconnected(nil) }
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.handlePackets() }
            if let error {
                self.reportDisconnected(error.localizedDescription)
                return
            }
            if complete {
                self.reportDisconnected(nil)
                return
            }
            self.receiveNext()
        }
    }

    private func handlePackets() {
        for packet in MQTTCodec.extractPackets(from: &buffer) {
            switch packet.type >> 4 {
            case 2: // CONNACK
                guard packet.body.count >= 2, packet.body[1] == 0 else {
                    let result = packet.body.count >= 2 ? packet.body[1] : 255
                    Self.logger.error("MQTT authentication rejected, CONNACK=\(result, privacy: .public)")
                    connectTimeout?.cancel()
                    reportDisconnected("Drukarka odrzuciła kod dostępu")
                    connection?.cancel()
                    return
                }
                connectTimeout?.cancel()
                connectTimeout = nil
                Self.logger.notice("MQTT connected")
                onEvent(.connected)
                let reportTopic = "device/\(printer.serial)/report"
                let requestTopic = "device/\(printer.serial)/request"
                send(MQTTCodec.subscribe(topic: reportTopic))
                let request = Data(#"{"pushing":{"sequence_id":"0","command":"pushall"}}"#.utf8)
                send(MQTTCodec.publish(topic: requestTopic, payload: request))
                startPingTimer()
            case 3: // PUBLISH
                guard let payload = MQTTCodec.publishPayload(header: packet.type, body: packet.body) else { continue }
                guard
                      let updated = BambuStatusParser.telemetry(from: payload, previous: telemetry) else { continue }
                telemetry = updated
                if !telemetryLogged {
                    telemetryLogged = true
                    Self.logger.notice("Printer telemetry received")
                }
                onEvent(.telemetry(updated))
            default:
                break
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(MQTTCodec.ping()) }
        timer.resume()
        pingTimer = timer
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.reportDisconnected(error.localizedDescription) }
        })
    }

    private func reportDisconnected(_ reason: String?) {
        guard !disconnectReported else { return }
        disconnectReported = true
        Self.logger.error("MQTT disconnected: \(reason ?? "connection closed", privacy: .private)")
        onEvent(.disconnected(reason))
    }

    private var certificateMismatchMessage: String {
        "Certyfikat drukarki zmienił się. Połączenie zablokowano; sprawdź sieć, a następnie usuń i dodaj drukarkę ponownie."
    }

}
