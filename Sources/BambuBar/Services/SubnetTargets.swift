import Foundation

/// Parses a user-entered list of extra discovery targets — single IPs, CIDR blocks (`a.b.c.d/n`) or
/// ranges (`a.b.c.d-e.f.g.h`) — into concrete IPv4 hosts to probe alongside the automatic local-subnet
/// scan. This is what lets a printer reached over a VPN (e.g. Tailscale) be discovered even though
/// multicast M-SEARCH never crosses the VPN subnet.
///
/// A block is **rejected** (`.tooLarge`) rather than silently truncated when it would expand past
/// `limit`, so pasting a whole Tailnet (`100.64.0.0/10`) fails loudly instead of quietly scanning
/// only its first slice and "not finding" the printer. Sizes are computed without enumerating, so a
/// huge block is rejected instantly instead of materialising millions of hosts.
enum SubnetTargets {
    static let maxHosts = 1024

    enum Expansion: Equatable {
        case ok([String])
        case invalid
        case tooLarge
    }

    static func expand(_ input: String, limit: Int = maxHosts) -> Expansion {
        var ordered: [String] = []
        var seen = Set<String>()
        for token in tokens(input) {
            let bounds: (first: UInt64, last: UInt64)
            if token.contains("/") {
                guard let cidr = parseCIDR(token) else { return .invalid }
                bounds = cidrBounds(network: cidr.network, prefix: cidr.prefix)
            } else if token.contains("-") {
                guard let range = parseRange(token) else { return .invalid }
                bounds = range
            } else {
                guard let value = parseIPv4(token) else { return .invalid }
                bounds = (value, value)
            }
            let size = bounds.last - bounds.first + 1
            if UInt64(ordered.count) + size > UInt64(limit) { return .tooLarge }
            var value = bounds.first
            while true {
                let host = ipString(value)
                if seen.insert(host).inserted { ordered.append(host) }
                if value == bounds.last { break }
                value += 1
            }
        }
        return .ok(ordered)
    }

    /// Whether the field's current text is safe to save: empty, or a valid expression within the limit.
    static func isValid(_ input: String) -> Bool {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if case .ok = expand(input) { return true }
        return false
    }

    /// True only when the input parses but is rejected purely for being too large (for a precise hint).
    static func isTooLarge(_ input: String) -> Bool { expand(input) == .tooLarge }

    private static func tokens(_ input: String) -> [Substring] {
        input.split(whereSeparator: { ", ;\n\r\t".contains($0) })
    }

    private static func parseIPv4(_ token: some StringProtocol) -> UInt64? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt64 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt64(octet)
        }
        return value
    }

    private static func parseCIDR(_ token: Substring) -> (network: UInt64, prefix: Int)? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let address = parseIPv4(parts[0]),
              let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let mask: UInt64 = prefix == 0 ? 0 : (0xFFFF_FFFF << (32 - prefix)) & 0xFFFF_FFFF
        return (address & mask, prefix)
    }

    private static func parseRange(_ token: Substring) -> (first: UInt64, last: UInt64)? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = parseIPv4(parts[0]), let end = parseIPv4(parts[1]), start <= end else { return nil }
        return (start, end)
    }

    /// Usable host range for a CIDR: network and broadcast are excluded for /30 and larger blocks,
    /// but kept for /31 (point-to-point) and /32 (single host).
    private static func cidrBounds(network: UInt64, prefix: Int) -> (first: UInt64, last: UInt64) {
        if prefix >= 32 { return (network, network) }
        let size: UInt64 = UInt64(1) << (32 - prefix)
        if prefix == 31 { return (network, network + 1) }
        return (network + 1, network + size - 2)
    }

    private static func ipString(_ value: UInt64) -> String {
        "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }
}
