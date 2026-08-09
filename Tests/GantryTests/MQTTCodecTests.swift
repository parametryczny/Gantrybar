import Testing
import Foundation
@testable import Gantry

@Suite struct MQTTCodecTests {
    @Test func connectPacketHeaderAndProtocol() {
        let packet = MQTTCodec.connect(clientID: "c", username: "u", password: "p")
        #expect(packet.first == 0x10) // CONNECT fixed header
        let ascii = String(decoding: packet, as: UTF8.self)
        #expect(ascii.contains("MQTT"))
    }

    @Test func subscribePacketHeader() {
        let packet = MQTTCodec.subscribe(topic: "device/123/report")
        #expect(packet.first == 0x82) // SUBSCRIBE header with QoS1 flag
    }

    @Test func pingPacket() {
        #expect(MQTTCodec.ping() == Data([0xC0, 0]))
    }

    @Test func publishRoundTripPayloadExtraction() {
        let payload = Data("{\"hello\":1}".utf8)
        let packet = MQTTCodec.publish(topic: "device/1/report", payload: payload)
        var buffer = packet
        let packets = MQTTCodec.extractPackets(from: &buffer)
        #expect(packets.count == 1)
        #expect(buffer.isEmpty) // buffer fully consumed
        let extracted = MQTTCodec.publishPayload(header: packets[0].type, body: packets[0].body)
        #expect(extracted == payload)
    }

    @Test func extractPacketsHandlesPartialBuffer() {
        let packet = MQTTCodec.publish(topic: "t", payload: Data("abc".utf8))
        var partial = Data(packet.prefix(packet.count - 1)) // one byte short
        #expect(MQTTCodec.extractPackets(from: &partial).isEmpty)
        #expect(partial.count == packet.count - 1) // partial bytes retained
        var full = packet
        #expect(MQTTCodec.extractPackets(from: &full).count == 1)
    }

    @Test func extractPacketsHandlesMultiplePacketsInOneBuffer() {
        var buffer = Data()
        buffer.append(MQTTCodec.publish(topic: "t1", payload: Data("a".utf8)))
        buffer.append(MQTTCodec.publish(topic: "t2", payload: Data("b".utf8)))
        let packets = MQTTCodec.extractPackets(from: &buffer)
        #expect(packets.count == 2)
        #expect(buffer.isEmpty)
    }

    @Test func largePayloadUsesMultiByteRemainingLength() {
        let payload = Data(repeating: 0x41, count: 500) // >127 forces 2-byte length
        let packet = MQTTCodec.publish(topic: "t", payload: payload)
        var buffer = packet
        let packets = MQTTCodec.extractPackets(from: &buffer)
        #expect(packets.count == 1)
        #expect(MQTTCodec.publishPayload(header: packets[0].type, body: packets[0].body) == payload)
    }

    @Test func publishPayloadRejectsNonPublishHeader() {
        #expect(MQTTCodec.publishPayload(header: 0x20, body: Data([0, 0])) == nil)
    }
}
