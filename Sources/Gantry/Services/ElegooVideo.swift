import Foundation

/// The Centauri Carbon (CC1) camera is not just a URL. Its MJPEG server on port 3031 only serves pictures
/// after Cmd 386 `{"Enable":1}`, the printer answers that command with an Ack (0 started, 1 too many
/// viewers, 2 no camera, 3 unknown) and it allows a single stream at a time. A stream enabled and never
/// disabled keeps that one slot taken, so the Elegoo app, the slicer or Gantry's next viewer is refused
/// until the printer restarts.
///
/// One gate per CC1 connection, shared by every viewer of that printer (details, edge dock, Telegram
/// snapshots). The first viewer enables the stream and waits for the Ack; later viewers ride on it; the
/// last one to leave disables it after a short grace, so a watchdog restart does not toggle the camera.
/// Every `acquire` must be matched by exactly one `release`, whatever the Ack was.
final class ElegooVideoGate: @unchecked Sendable {
    typealias Send = @Sendable (_ enable: Bool, _ requestID: String) -> Void

    private let send: Send
    private let replyTimeout: TimeInterval
    private let resendInterval: TimeInterval
    private let releaseGrace: TimeInterval
    private let lock = NSLock()
    private var holders = 0
    private var enabled = false
    private var waiters: [@Sendable (Int?) -> Void] = []
    private var requestIDs: Set<String> = []
    private var attempt = 0
    private var releaseGeneration = 0

    init(replyTimeout: TimeInterval = 6, resendInterval: TimeInterval = 1.5, releaseGrace: TimeInterval = 5,
         send: @escaping Send) {
        self.replyTimeout = replyTimeout; self.resendInterval = resendInterval
        self.releaseGrace = releaseGrace; self.send = send
    }

    /// Counts the caller as a viewer at once and reports the Ack later: nil when the printer did not
    /// answer in time (older firmware, a socket still connecting), which is not a refusal.
    func acquire(_ completion: @escaping @Sendable (Int?) -> Void) {
        lock.lock()
        holders += 1; releaseGeneration += 1
        if enabled { lock.unlock(); completion(0); return }
        waiters.append(completion)
        let starting = waiters.count == 1
        if starting { attempt += 1; requestIDs.removeAll() }
        let current = attempt
        lock.unlock()
        if starting { request(attempt: current, deadline: Date().addingTimeInterval(replyTimeout)) }
    }

    func release() {
        lock.lock()
        holders = max(0, holders - 1)
        let generation = holders == 0 && enabled ? nextReleaseGeneration() : nil
        lock.unlock()
        if let generation { scheduleDisable(generation) }
    }

    /// A Cmd 386 response. Replies to requests this gate did not send (an Elegoo app on the same printer,
    /// an earlier disable) are ignored; a reply without a RequestID is taken at its word.
    func handleReply(requestID: String?, ack: Int) {
        lock.lock()
        let matches = !waiters.isEmpty && (requestID == nil || requestIDs.contains(requestID!))
        let current = attempt
        lock.unlock()
        if matches { finish(ack, attempt: current) }
    }

    /// The connection dropped: whatever the printer had enabled may be gone with it.
    func reset() { lock.lock(); enabled = false; lock.unlock() }

    static func refusalMessage(ack: Int?) -> String? {
        switch ack {
        case nil, 0: nil
        case 1: Localization.t("The printer allows one camera viewer at a time. Close the camera in Elegoo Slicer or the Elegoo app, or restart the printer.")
        case 2: Localization.t("The printer reports that it has no camera.")
        default: Localization.t("The printer could not start the camera (code {0}).", ack!)
        }
    }

    private func request(attempt current: Int, deadline: Date) {
        lock.lock()
        guard current == attempt, !waiters.isEmpty else { lock.unlock(); return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { lock.unlock(); finish(nil, attempt: current); return }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        requestIDs.insert(id)
        lock.unlock()
        // Sent again until answered: a command written while the socket is still connecting is dropped,
        // and the printer tolerates a repeated enable.
        send(true, id)
        DispatchQueue.global().asyncAfter(deadline: .now() + min(resendInterval, remaining)) { [weak self] in
            self?.request(attempt: current, deadline: deadline)
        }
    }

    private func finish(_ ack: Int?, attempt current: Int) {
        lock.lock()
        guard current == attempt, !waiters.isEmpty else { lock.unlock(); return }
        let completions = waiters
        waiters.removeAll(); attempt += 1
        if ack == 0 { enabled = true }
        // Every viewer may have left while the Ack was on its way; the stream must not stay on for nobody.
        let generation = ack == 0 && holders == 0 ? nextReleaseGeneration() : nil
        lock.unlock()
        if let generation { scheduleDisable(generation) }
        completions.forEach { $0(ack) }
    }

    private func nextReleaseGeneration() -> Int { releaseGeneration += 1; return releaseGeneration }

    private func scheduleDisable(_ generation: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + releaseGrace) { [weak self] in
            guard let self else { return }
            lock.lock()
            let disable = generation == releaseGeneration && holders == 0 && enabled
            if disable { enabled = false }
            lock.unlock()
            if disable { send(false, UUID().uuidString.replacingOccurrences(of: "-", with: "")) }
        }
    }
}

extension ElegooStatusParser {
    /// The printer's answer to Cmd 386, or nil for any other frame.
    static func cc1VideoReply(data: Data) -> (requestID: String?, ack: Int)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let envelope = root["Data"] as? [String: Any],
              (envelope["Cmd"] as? NSNumber)?.intValue == 386,
              let ack = ((envelope["Data"] as? [String: Any])?["Ack"] as? NSNumber)?.intValue else { return nil }
        return (envelope["RequestID"] as? String, ack)
    }
}

/// Cuts complete JPEG frames out of an MJPEG byte stream, one byte at a time, without rescanning what
/// it has already seen.
struct MJPEGFrameSplitter {
    static let maximumFrameBytes = 4_000_000
    private var frame: [UInt8] = []
    private var inFrame = false
    private var previous: UInt8 = 0

    mutating func push(_ byte: UInt8) -> Data? {
        let afterMarker = previous == 0xFF
        previous = byte
        guard inFrame else {
            if afterMarker && byte == 0xD8 { inFrame = true; frame = [0xFF, 0xD8] }
            return nil
        }
        frame.append(byte)
        if afterMarker && byte == 0xD9 {
            inFrame = false; previous = 0
            defer { frame.removeAll(keepingCapacity: true) }
            return Data(frame)
        }
        if frame.count > Self.maximumFrameBytes { inFrame = false; frame.removeAll(keepingCapacity: true) }
        return nil
    }
}

/// Motion JPEG cameras often leave out the Huffman tables and rely on the decoder knowing the standard
/// ones. Not every decoder does, and a frame that cannot be decoded shows nothing at all, so the standard
/// tables (ITU T.81 Annex K.3) are put back in front of the scan when a frame has none.
enum JPEGHuffman {
    static let standardTables: [UInt8] = hexBytes(
        "ffc401a20000010501010101010100000000000000000102030405060708090a0b100002010303020403050504040000017d0102030004110512213141061351610722711432"
        + "8191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a83"
        + "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8"
        + "f9fa0100030101010101010101010000000000000102030405060708090a0b110002010204040304070504040001027700010203110405213106124151076171132232810814"
        + "4291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a8283"
        + "8485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa")

    static func ensureTables(_ jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return jpeg }
            switch bytes[index + 1] {
            case 0xFF: index += 1
            case 0xC4: return jpeg
            case 0xDA:
                var repaired = Data(bytes[..<index])
                repaired.append(contentsOf: standardTables)
                repaired.append(contentsOf: bytes[index...])
                return repaired
            case 0x01, 0xD0...0xD7: index += 2
            default: index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
            }
        }
        return jpeg
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []; result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}
