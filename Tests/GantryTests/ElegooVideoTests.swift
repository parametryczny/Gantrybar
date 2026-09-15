import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Gantry

@Suite struct ElegooVideoTests {
    /// Collects what the gate sends, standing in for the SDCP socket.
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(enable: Bool, id: String)] = []
        var all: [(enable: Bool, id: String)] { lock.lock(); defer { lock.unlock() }; return sent }
        func record(_ enable: Bool, _ id: String) { lock.lock(); sent.append((enable, id)); lock.unlock() }
        func waitFor(_ count: Int, seconds: Double = 2) async -> [(enable: Bool, id: String)] {
            let deadline = Date().addingTimeInterval(seconds)
            while all.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            return all
        }
    }

    private func acquire(_ gate: ElegooVideoGate) async -> Int? {
        await withCheckedContinuation { cont in gate.acquire { cont.resume(returning: $0) } }
    }

    @Test func videoReplyIsReadOnlyFromCmd386() {
        let reply = ElegooStatusParser.cc1VideoReply(data: Data(#"{"Id":"x","Data":{"Cmd":386,"Data":{"Ack":1,"VideoUrl":""},"RequestID":"abc","MainboardID":"M"},"Topic":"sdcp/response/M"}"#.utf8))
        #expect(reply?.ack == 1)
        #expect(reply?.requestID == "abc")
        #expect(ElegooStatusParser.cc1VideoReply(data: Data(#"{"Data":{"Cmd":403,"Data":{"Ack":0}}}"#.utf8)) == nil)
        #expect(ElegooStatusParser.cc1VideoReply(data: Data(#"{"Data":{"Status":{"TempOfNozzle":200}}}"#.utf8)) == nil)
    }

    @Test func firstViewerWaitsForAckOthersShareAndLastOneDisables() async {
        let wire = Wire()
        let gate = ElegooVideoGate(replyTimeout: 2, resendInterval: 5, releaseGrace: 0.1) { wire.record($0, $1) }
        async let first = acquire(gate)
        let sent = await wire.waitFor(1)
        #expect(sent.first?.enable == true)
        gate.handleReply(requestID: "somebody-else", ack: 1)
        gate.handleReply(requestID: sent[0].id, ack: 0)
        #expect(await first == 0)
        #expect(await acquire(gate) == 0)
        #expect(wire.all.count == 1, "A second viewer enabled the stream again")
        gate.release()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(wire.all.count == 1, "The stream was disabled while a viewer still watched")
        gate.release()
        let afterLast = await wire.waitFor(2)
        #expect(afterLast.count == 2 && afterLast[1].enable == false)
    }

    @Test func restartWithinGraceKeepsTheStream() async {
        let wire = Wire()
        let gate = ElegooVideoGate(replyTimeout: 2, resendInterval: 5, releaseGrace: 0.2) { wire.record($0, $1) }
        async let first = acquire(gate)
        let sent = await wire.waitFor(1)
        gate.handleReply(requestID: sent[0].id, ack: 0)
        _ = await first
        gate.release()
        #expect(await acquire(gate) == 0)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(wire.all.count == 1)
        gate.release()
    }

    @Test func silentPrinterIsRetriedThenReportedAsNoAnswer() async {
        let wire = Wire()
        let gate = ElegooVideoGate(replyTimeout: 0.35, resendInterval: 0.1, releaseGrace: 0.05) { wire.record($0, $1) }
        #expect(await acquire(gate) == nil)
        #expect(wire.all.count >= 3)
        #expect(ElegooVideoGate.refusalMessage(ack: nil) == nil)
        #expect(ElegooVideoGate.refusalMessage(ack: 1) != nil)
        gate.release()
    }

    @Test func ackArrivingAfterEveryViewerLeftStillDisables() async {
        let wire = Wire()
        let gate = ElegooVideoGate(replyTimeout: 2, resendInterval: 5, releaseGrace: 0.05) { wire.record($0, $1) }
        gate.acquire { _ in }
        let sent = await wire.waitFor(1)
        gate.release()
        gate.handleReply(requestID: sent[0].id, ack: 0)
        let after = await wire.waitFor(2)
        #expect(after.count == 2 && after[1].enable == false)
    }

    @Test func splitterCutsFramesAcrossChunks() {
        var splitter = MJPEGFrameSplitter()
        let stream: [UInt8] = [0x00, 0xFF, 0xD8, 0x01, 0xFF, 0x00, 0xFF, 0xD9, 0x42, 0xFF, 0xD8, 0x02, 0xFF, 0xD9]
        let frames = stream.compactMap { splitter.push($0) }
        #expect(frames == [Data([0xFF, 0xD8, 0x01, 0xFF, 0x00, 0xFF, 0xD9]), Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9])])
    }

    @Test func missingHuffmanTablesAreRestoredBeforeTheScan() throws {
        let original = try jpeg()
        let stripped = removingSegments(0xC4, from: original)
        #expect(!containsMarker(0xC4, stripped))
        let repaired = JPEGHuffman.ensureTables(stripped)
        #expect(repaired.count == stripped.count + 420)
        #expect(markerOffset(0xC4, repaired)! < markerOffset(0xDA, repaired)!)
        let source = try #require(CGImageSourceCreateWithData(repaired as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32)
        #expect(JPEGHuffman.ensureTables(original) == original)
        #expect(JPEGHuffman.ensureTables(Data([1, 2, 3])) == Data([1, 2, 3]))
    }

    private func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Segment walk up to the scan, the part of a JPEG where markers are not entropy-coded data.
    private func segments(_ data: Data) -> [(marker: UInt8, range: Range<Int>)] {
        let bytes = [UInt8](data); var result: [(UInt8, Range<Int>)] = []; var index = 2
        while index + 3 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            let length = 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
            result.append((marker, index..<(index + length)))
            if marker == 0xDA { break }
            index += length
        }
        return result
    }
    private func removingSegments(_ marker: UInt8, from data: Data) -> Data {
        var bytes = [UInt8](data)
        for segment in segments(data).reversed() where segment.marker == marker { bytes.removeSubrange(segment.range) }
        return Data(bytes)
    }
    private func markerOffset(_ marker: UInt8, _ data: Data) -> Int? { segments(data).first { $0.marker == marker }?.range.lowerBound }
    private func containsMarker(_ marker: UInt8, _ data: Data) -> Bool { markerOffset(marker, data) != nil }
}
