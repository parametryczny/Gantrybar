import Foundation
import Network

/// The P1/A1 chamber camera: a TLS socket on port 6000 that answers with a continuous stream of JPEG
/// frames after an 80-byte handshake built from the printer's access code.
///
/// The X1 family serves RTSP(S) on 322/554, which `RTSPCameraStream` handles. The P1 and A1 have no
/// RTSP endpoint at all, so on those machines RTSP simply fails and, before this existed, macOS and
/// Linux showed the generic "enable LAN Only Mode" hint even though the real problem was that Gantry
/// never spoke their protocol. The Windows client has done this since day one
/// (Services/BambuCameraStream.cs, TryJpegAsync); this is the same wire format.
final class BambuJPEGCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, playing, failed(String) }

    private let host: String
    private let accessCode: String
    private let onState: @Sendable (State) -> Void
    private let onFrame: @Sendable (Data) -> Void

    private let queue = DispatchQueue(label: "pl.gantry.bambu-jpeg")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false
    private var announced = false

    init(host: String, accessCode: String,
         onState: @escaping @Sendable (State) -> Void,
         onFrame: @escaping @Sendable (Data) -> Void) {
        self.host = host
        self.accessCode = accessCode
        self.onState = onState
        self.onFrame = onFrame
    }

    /// 80 bytes: a 0x40 header, 0x3000 at offset 4, the fixed "bblp" user at 16 and the access code at 48.
    private static func authPacket(accessCode: String) -> Data {
        var packet = Data(count: 80)
        packet[0] = 0x40
        packet[4] = 0x00
        packet[5] = 0x30
        for (index, byte) in Array("bblp".utf8).enumerated() where 16 + index < 80 {
            packet[16 + index] = byte
        }
        for (index, byte) in Array(accessCode.utf8).enumerated() where 48 + index < 80 {
            packet[48 + index] = byte
        }
        return packet
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onState(.connecting)
            // The printer presents a self-signed certificate, so verification is disabled here just as
            // it is for the RTSPS path; the access code is what actually authenticates the session.
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions,
                                                  { _, _, complete in complete(true) }, self.queue)
            let parameters = NWParameters(tls: options)
            guard let port = NWEndpoint.Port(rawValue: 6000) else { return }
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    connection.send(content: Self.authPacket(accessCode: self.accessCode),
                                    completion: .contentProcessed { _ in })
                    self.receive()
                case .failed(let error):
                    self.onState(.failed(error.localizedDescription))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
            self.buffer.removeAll()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
                // Never let a stalled stream grow without bound.
                if self.buffer.count > 8 * 1024 * 1024 {
                    self.buffer.removeFirst(self.buffer.count - 2 * 1024 * 1024)
                }
            }
            if isComplete || error != nil {
                self.onState(.failed(error?.localizedDescription
                                     ?? NSLocalizedString("Połączenie zamknięte", comment: "")))
                return
            }
            self.receive()
        }
    }

    /// Split whole JPEGs out of the accumulated bytes on the SOI/EOI markers.
    private func drainFrames() {
        while true {
            guard let start = buffer.range(of: Data([0xFF, 0xD8])) else {
                buffer.removeAll()
                return
            }
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex ..< start.lowerBound) }
            guard let end = buffer.range(of: Data([0xFF, 0xD9]),
                                         in: buffer.index(buffer.startIndex, offsetBy: 2) ..< buffer.endIndex) else {
                return   // frame still arriving
            }
            let frame = buffer.subdata(in: buffer.startIndex ..< end.upperBound)
            buffer.removeSubrange(buffer.startIndex ..< end.upperBound)
            if !announced {
                announced = true
                onState(.playing)
            }
            onFrame(frame)
        }
    }
}
