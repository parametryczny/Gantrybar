import Foundation

enum MQTTCodec {
    static func connect(clientID: String, username: String, password: String) -> Data {
        var body = Data([0, 4])
        body.append(contentsOf: "MQTT".utf8)
        body.append(4)
        body.append(0xC2) // username, password, clean session
        body.append(contentsOf: [0, 60])
        body.append(mqttString(clientID))
        body.append(mqttString(username))
        body.append(mqttString(password))
        return packet(header: 0x10, body: body)
    }

    static func subscribe(topic: String, packetID: UInt16 = 1) -> Data {
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xff)])
        body.append(mqttString(topic))
        body.append(0)
        return packet(header: 0x82, body: body)
    }

    static func publish(topic: String, payload: Data) -> Data {
        var body = mqttString(topic)
        body.append(payload)
        return packet(header: 0x30, body: body)
    }

    static func ping() -> Data { Data([0xC0, 0]) }

    static func extractPackets(from buffer: inout Data) -> [(type: UInt8, body: Data)] {
        var packets: [(UInt8, Data)] = []
        while buffer.count >= 2 {
            var multiplier = 1
            var remaining = 0
            var index = 1
            var finishedLength = false
            while index < buffer.count && index <= 4 {
                let byte = Int(buffer[index])
                remaining += (byte & 127) * multiplier
                index += 1
                if byte & 128 == 0 { finishedLength = true; break }
                multiplier *= 128
            }
            guard finishedLength, buffer.count >= index + remaining else { break }
            packets.append((buffer[0], buffer.subdata(in: index..<(index + remaining))))
            buffer.removeSubrange(0..<(index + remaining))
        }
        return packets
    }

    static func publishPayload(header: UInt8, body: Data) -> Data? {
        guard header >> 4 == 3, body.count >= 2 else { return nil }
        let topicLength = Int(body[0]) << 8 | Int(body[1])
        var offset = 2 + topicLength
        let qos = (header >> 1) & 0x03
        if qos > 0 { offset += 2 }
        guard offset <= body.count else { return nil }
        return body.subdata(in: offset..<body.count)
    }

    static func publishTopic(header: UInt8, body: Data) -> String? {
        guard header >> 4 == 3, body.count >= 2 else { return nil }
        let length = Int(body[0]) << 8 | Int(body[1])
        guard body.count >= 2 + length else { return nil }
        return String(data: body.subdata(in: 2..<(2 + length)), encoding: .utf8)
    }

    private static func packet(header: UInt8, body: Data) -> Data {
        var result = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 128 }
            result.append(byte)
        } while length > 0
        result.append(body)
        return result
    }

    private static func mqttString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var result = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)])
        result.append(bytes)
        return result
    }
}
