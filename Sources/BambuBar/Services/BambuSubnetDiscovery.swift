import Darwin
import Foundation
import Network
import Security

/// Finds Bambu printers even when their UDP multicast announcements are filtered.
/// A Bambu MQTTs certificate exposes the printer serial number as its subject CN.
final class BambuSubnetDiscovery: @unchecked Sendable {
    /// Overall budget so a large custom range can't keep probing in the background long after the UI
    /// has given up: once it elapses, no new probes are launched and in-flight ones finish (≤2 s).
    private static let budget: TimeInterval = 9

    func scan(extraTargets: String = "") async -> [DiscoveredPrinter] {
        var hostSet = Set(localIPv4Prefixes().flatMap { prefix in (1...254).map { "\(prefix).\($0)" } })
        if case .ok(let custom) = SubnetTargets.expand(extraTargets) { hostSet.formUnion(custom) }
        let uniqueHosts = Array(hostSet)
        guard !uniqueHosts.isEmpty else { return [] }

        let deadline = Date().addingTimeInterval(Self.budget)
        return await withTaskGroup(of: DiscoveredPrinter?.self) { group in
            var iterator = uniqueHosts.makeIterator()
            for _ in 0..<min(128, uniqueHosts.count) {
                if let host = iterator.next() {
                    group.addTask { await self.probe(host: host) }
                }
            }
            var found: [String: DiscoveredPrinter] = [:]
            while let result = await group.next() {
                if let result { found[result.serial] = result }
                if Date() < deadline, let host = iterator.next() {
                    group.addTask { await self.probe(host: host) }
                }
            }
            return found.values.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
        }
    }

    private func probe(host: String) async -> DiscoveredPrinter? {
        await withCheckedContinuation { (continuation: CheckedContinuation<DiscoveredPrinter?, Never>) in
            let queue = DispatchQueue(label: "pl.bambubar.probe.\(host)")
            let box = ProbeBox { serial in
                guard let serial, serial.count >= 10,
                      serial.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: DiscoveredPrinter(
                    serial: serial,
                    name: "Bambu \(serial.suffix(4))",
                    model: "Bambu Lab",
                    host: host
                ))
            }

            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let certificates = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                   let certificate = certificates.first,
                   let summary = SecCertificateCopySubjectSummary(certificate) as String? {
                    box.setSerial(summary.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                complete(true)
            }, queue)

            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: 8883)!,
                using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            )
            box.connection = connection
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish()
                case .failed, .cancelled: box.finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.0) { box.finish() }
        }
    }

    private func localIPv4Prefixes() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var prefixes = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }

            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &socketAddress, &buffer, socklen_t(INET_ADDRSTRLEN))
            let nullIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let host = String(decoding: buffer[..<nullIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
            let parts = host.split(separator: ".")
            if parts.count == 4 { prefixes.insert(parts.prefix(3).joined(separator: ".")) }
        }
        return Array(prefixes)
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (String?) -> Void
    var connection: NWConnection?
    private var serial: String?

    init(completion: @escaping @Sendable (String?) -> Void) {
        self.completion = completion
    }

    func setSerial(_ value: String) {
        lock.lock()
        serial = value
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let result = serial
        let connection = connection
        lock.unlock()
        connection?.cancel()
        completion(result)
    }
}
