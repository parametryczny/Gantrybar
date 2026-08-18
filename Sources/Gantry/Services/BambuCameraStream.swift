import Foundation
import Network
import AppKit

/// Live chamber-camera stream for Bambu printers in LAN mode.
///
/// Protocol (OpenBambuAPI): open a TLS socket to the printer on port 6000 (self-signed cert, so we
/// accept it without validation), send an 80-byte auth payload (`bblp` + the access code), then read
/// a sequence of messages — each a 16-byte header whose first 4 bytes are the little-endian JPEG
/// length, followed by that many bytes of JPEG. Not every model/firmware enables the local camera
/// (P1/A1 need "LAN Mode Live View"); when it isn't available the connection simply never delivers
/// frames, so callers should show a fallback after a timeout.
/// Network callbacks run on the private `queue`; that serialization is what makes the mutable state
/// safe, hence `@unchecked Sendable`.
final class BambuCameraStream: @unchecked Sendable {
    enum State: Sendable { case connecting, streaming, failed(String) }

    private let host: String
    private let accessCode: String
    private let port: NWEndpoint.Port = 6000
    private let onFrame: @Sendable (Data) -> Void
    private let onState: @Sendable (State) -> Void

    private let queue = DispatchQueue(label: "pl.gantry.camera")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false

    init(host: String, accessCode: String,
         onFrame: @escaping @Sendable (Data) -> Void,
         onState: @escaping @Sendable (State) -> Void) {
        self.host = host
        self.accessCode = accessCode
        self.onFrame = onFrame
        self.onState = onState
    }

    func start() {
        onState(.connecting)
        let tls = NWProtocolTLS.Options()
        // The printer presents a self-signed certificate; accept it (this is a LAN-only device stream).
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let params = NWParameters(tls: tls)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendAuth()
                self.receiveLoop()
            case .failed(let error):
                self.onState(.failed(error.localizedDescription))
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
    }

    private func sendAuth() {
        var payload = Data()
        func appendLE(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { payload.append(contentsOf: $0) }
        }
        // 16-byte header (four little-endian UInt32) then username (32B) + access code (32B) = 80B.
        appendLE(0x40)      // payload type
        appendLE(0x3000)    // request type
        appendLE(0)
        appendLE(0)
        payload.append(fixedField("bblp"))
        payload.append(fixedField(accessCode))
        connection?.send(content: payload, completion: .contentProcessed { _ in })
    }

    /// A 32-byte, NUL-padded field for the username / access code.
    private func fixedField(_ text: String) -> Data {
        var data = Data(text.utf8.prefix(32))
        if data.count < 32 { data.append(Data(repeating: 0, count: 32 - data.count)) }
        return data
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if let error {
                self.onState(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onState(.failed("Połączenie zamknięte"))
                return
            }
            self.receiveLoop()
        }
    }

    private static let soi = Data([0xFF, 0xD8])   // JPEG start-of-image
    private static let eoi = Data([0xFF, 0xD9])   // JPEG end-of-image

    /// Extract complete JPEG frames by scanning for SOI…EOI markers. This is robust to the exact
    /// per-frame header format (which varies across models/firmware) — we simply carve out each
    /// FFD8…FFD9 image and hand it over.
    private func drainFrames() {
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }   // desync guard
        while true {
            guard let start = buffer.range(of: Self.soi) else {
                // No image start yet; drop leading noise but keep the last byte (a split FF marker).
                if buffer.count > 1 { buffer.removeFirst(buffer.count - 1) }
                return
            }
            if start.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<start.lowerBound)
            }
            let searchFrom = buffer.index(buffer.startIndex, offsetBy: 2)
            guard let end = buffer.range(of: Self.eoi, in: searchFrom..<buffer.endIndex) else {
                return   // incomplete frame; wait for more bytes
            }
            let frame = buffer.subdata(in: buffer.startIndex..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            onFrame(frame)
            onState(.streaming)
        }
    }
}
