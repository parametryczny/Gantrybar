import Foundation
import Compression

/// One filament entry from a Bambu `.gcode.3mf` (`Metadata/slice_info.config`), as computed by the
/// slicer. `usedGrams` is the value we subtract from the assigned spool after a finished print.
struct SlicedFilament: Equatable, Sendable {
    let id: Int            // 1-based filament index in the plate
    let usedGrams: Double
    let usedMeters: Double
    let type: String       // PLA / PETG / ...
    let colorHex: String   // 6-hex, no '#'
}

/// Reads per-filament `used_g` straight out of a Bambu `.gcode.3mf` (a ZIP). Fully local: no cloud, no
/// account. Validated against real slicer output. Used to decrement physical spools after a print.
enum ThreeMFReader {
    static func filaments(fromFile url: URL) -> [SlicedFilament] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return filaments(fromData: data)
    }

    static func filaments(fromData data: Data) -> [SlicedFilament] {
        guard let config = entry(named: "Metadata/slice_info.config", in: data) else { return [] }
        return SliceInfoParser.parse(config)
    }

    // MARK: Minimal ZIP reader (one named entry) — 3mf entries are stored or raw-deflate.

    private static func entry(named name: String, in data: Data) -> Data? {
        let count = data.count
        guard count >= 22 else { return nil }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }

        // Locate the End Of Central Directory record, scanning back from the tail.
        var eocd = -1
        let lowerBound = max(0, count - 22 - 65536)
        var i = count - 22
        while i >= lowerBound {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let cdOffset = u32(eocd + 16)
        let total = u16(eocd + 10)

        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= count, u32(p) == 0x02014b50 else { return nil }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let fnLen = u16(p + 28), exLen = u16(p + 30), cmLen = u16(p + 32)
            let localOff = u32(p + 42)
            guard p + 46 + fnLen <= count else { return nil }
            let fn = String(bytes: data[(p + 46)..<(p + 46 + fnLen)], encoding: .utf8) ?? ""
            if fn == name {
                guard localOff + 30 <= count else { return nil }
                let lfn = u16(localOff + 26), lex = u16(localOff + 28)
                let start = localOff + 30 + lfn + lex
                guard start + compSize <= count else { return nil }
                let comp = data.subdata(in: start..<(start + compSize))
                if method == 0 { return comp }   // stored
                return inflate(comp, hint: max(compSize * 20, 65536))
            }
            p += 46 + fnLen + exLen + cmLen
        }
        return nil
    }

    private static func inflate(_ comp: Data, hint: Int) -> Data? {
        var capacity = hint
        for _ in 0..<4 {   // grow if the guess was too small
            var dst = Data(count: capacity)
            let n = dst.withUnsafeMutableBytes { dptr -> Int in
                comp.withUnsafeBytes { sptr -> Int in
                    guard let d = dptr.bindMemory(to: UInt8.self).baseAddress,
                          let s = sptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, capacity, s, comp.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0, n < capacity { return dst.prefix(n) }
            capacity *= 4
        }
        return nil
    }
}

/// Pulls `<filament ... used_g=... type=... color=.../>` rows out of slice_info.config.
private final class SliceInfoParser: NSObject, XMLParserDelegate {
    private var result: [SlicedFilament] = []

    static func parse(_ data: Data) -> [SlicedFilament] {
        let parser = XMLParser(data: data)
        let delegate = SliceInfoParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        guard name == "filament" else { return }
        let id = Int(attrs["id"] ?? "") ?? (result.count + 1)
        let usedG = Double(attrs["used_g"] ?? "") ?? 0
        let usedM = Double(attrs["used_m"] ?? "") ?? 0
        let type = attrs["type"] ?? ""
        let color = (attrs["color"] ?? "").replacingOccurrences(of: "#", with: "").uppercased()
        result.append(SlicedFilament(id: id, usedGrams: usedG, usedMeters: usedM, type: type, colorHex: color))
    }
}
