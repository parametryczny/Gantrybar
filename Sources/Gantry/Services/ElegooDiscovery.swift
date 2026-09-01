import Darwin
import Foundation

final class ElegooDiscovery: @unchecked Sendable {
    func scan(seconds: TimeInterval = 3.5) async -> [DiscoveredPrinter] {
        await withTaskGroup(of: [DiscoveredPrinter].self) { group in
            group.addTask { self.scan(kind: .elegooCC1, seconds: seconds) }
            group.addTask { self.scan(kind: .elegooCC2, seconds: seconds) }
            var values: [DiscoveredPrinter] = []
            for await result in group { values += result }
            return values
        }
    }

    private func scan(kind: PrinterKind, seconds: TimeInterval) -> [DiscoveredPrinter] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [] }; defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(kind == .elegooCC1 ? 3000 : 52700).bigEndian
        inet_pton(AF_INET, "255.255.255.255", &address.sin_addr)
        let message = Data((kind == .elegooCC1 ? "M99999" : #"{"id":0,"method":7000}"#).utf8)
        message.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }}
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let deadline = Date().addingTimeInterval(seconds); var found: [String: DiscoveredPrinter] = [:]
        while Date() < deadline {
            var bytes = [UInt8](repeating: 0, count: 16_384), sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, &bytes, bytes.count, 0, $0, &length)
            }}
            guard count > 0 else { continue }
            var hostBytes = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)), senderAddress = sender.sin_addr
            inet_ntop(AF_INET, &senderAddress, &hostBytes, socklen_t(INET_ADDRSTRLEN))
            let host = String(decoding: hostBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let printer = Self.parse(Data(bytes.prefix(count)), host: host, kind: kind) { found[printer.serial] = printer }
        }
        return Array(found.values)
    }

    static func parse(_ data: Data, host: String, kind: PrinterKind) -> DiscoveredPrinter? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if kind == .elegooCC2 {
            guard let dictionary = root as? [String: Any], let result = dictionary["result"] as? [String: Any],
                  let serial = result["sn"] as? String, !serial.isEmpty else { return nil }
            let name = result["host_name"] as? String ?? "Centauri Carbon 2"
            let model = result["machine_model"] as? String ?? "Centauri Carbon 2"
            return DiscoveredPrinter(serial: serial, name: name, model: "Elegoo \(model)", host: host, kind: kind)
        }
        guard let serial = recursive(root, keys: ["mainboardid", "mainboard_id", "serialnumber", "sn"]), !serial.isEmpty else { return nil }
        let name = recursive(root, keys: ["machinename", "devicename", "name"]) ?? "Centauri Carbon \(serial.suffix(4))"
        let model = recursive(root, keys: ["machinemodel", "model"]) ?? "Centauri Carbon"
        return DiscoveredPrinter(serial: serial, name: name, model: "Elegoo \(model)", host: host, kind: kind)
    }

    private static func recursive(_ value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary where keys.contains(key.lowercased()) { return String(describing: child) }
            for child in dictionary.values { if let found = recursive(child, keys: keys) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = recursive(child, keys: keys) { return found } }
        }
        return nil
    }
}
