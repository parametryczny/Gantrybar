import Foundation
import Compression
import CoreGraphics
import ImageIO

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

    static func printObjectLayout(fromData data: Data, gcodeFile: String?,
                                  skipped: Set<String>) -> PrintObjectLayout? {
        guard let config = entry(named: "Metadata/slice_info.config", in: data) else { return nil }
        let xmlObjects = SliceObjectParser.parse(config)
        guard !xmlObjects.isEmpty else { return nil }

        let hintedPlate: Int? = gcodeFile.flatMap { value in
            guard let range = value.range(of: #"plate_(\d+)"#, options: .regularExpression) else { return nil }
            return Int(value[range].dropFirst(6))
        }
        let candidates = ([hintedPlate].compactMap { $0 } + Array(1...32)).reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for plate in candidates {
            guard let json = entry(named: "Metadata/plate_\(plate).json", in: data),
                  let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            let map = (root["map"] as? [String: Any]) ?? root
            let boxes = map["bbox_objects"] as? [[String: Any]] ?? []
            var objects: [PrintObject] = []
            for (index, xml) in xmlObjects.enumerated() {
                let box = index < boxes.count ? boxes[index] : [:]
                let raw = box["bbox"] as? [Any] ?? []
                var polygon: [BedPoint] = []
                if raw.count >= 4, let x0 = number(raw[0]), let y0 = number(raw[1]),
                   let x1 = number(raw[2]), let y1 = number(raw[3]) {
                    polygon = [BedPoint(x: x0, y: y0), BedPoint(x: x1, y: y0),
                               BedPoint(x: x1, y: y1), BedPoint(x: x0, y: y1)]
                }
                objects.append(PrintObject(id: xml.id, name: xml.name, polygon: polygon))
            }
            let all = (map["bbox_all"] as? [Any] ?? []).compactMap(number)
            let bounds = all.count >= 4 ? Array(all.prefix(4)) : inferredBounds(objects)
            let preview = entry(named: "Metadata/top_\(plate).png", in: data)
                ?? entry(named: "Metadata/plate_\(plate).png", in: data)
            return PrintObjectLayout(objects: objects, skippedObjectIDs: skipped,
                                     currentObjectID: nil, bedBounds: bounds, previewPNG: preview)
        }
        return PrintObjectLayout(objects: xmlObjects.map { PrintObject(id: $0.id, name: $0.name, polygon: []) },
                                 skippedObjectIDs: skipped, currentObjectID: nil,
                                 bedBounds: [0, 0, 256, 256], previewPNG: nil)
    }

    /// Builds the skip map from the exact three active-project files requested by Bambu Studio's
    /// PartSkipDialog. `pick_N.png` encodes an object id in each object's RGB pixels; its per-id
    /// bounds keep the Gantry preview clickable without needing the complete 3MF archive.
    static func printObjectLayout(sliceInfo: Data, pickPNG: Data, plateIndex: Int,
                                  skipped: Set<String>) -> PrintObjectLayout? {
        let parsed = PlateSliceObjectParser.parse(sliceInfo, plateIndex: plateIndex)
        // Bambu Studio exposes the action only for g-code sliced with per-object labels. Without
        // them the firmware cannot safely associate a visible shape with a skip id.
        guard parsed.labelObjectEnabled != false else { return nil }
        let xmlObjects = parsed.objects.isEmpty ? SliceObjectParser.parse(sliceInfo) : parsed.objects
        guard !xmlObjects.isEmpty else { return nil }
        let imageInfo = PickImageBounds.read(pickPNG, objectIDs: Set(xmlObjects.map(\.id)))
        let objects = xmlObjects.map { object in
            PrintObject(id: object.id, name: object.name, polygon: imageInfo?.bounds[object.id] ?? [])
        }
        let bedBounds: [Double]
        if let imageInfo { bedBounds = [0, 0, Double(imageInfo.width), Double(imageInfo.height)] }
        else { bedBounds = inferredBounds(objects) }
        return PrintObjectLayout(objects: objects, skippedObjectIDs: skipped,
                                 currentObjectID: nil, bedBounds: bedBounds,
                                 previewPNG: imageInfo == nil ? nil : pickPNG)
    }

    // MARK: Minimal ZIP reader (one named entry) — 3mf entries are stored or raw-deflate.

    static func entry(named name: String, in data: Data) -> Data? {
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

    private static func number(_ value: Any) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func inferredBounds(_ objects: [PrintObject]) -> [Double] {
        let points = objects.flatMap(\.polygon)
        guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min(),
              let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else {
            return [0, 0, 256, 256]
        }
        let pad = max(5, max(maxX - minX, maxY - minY) * 0.06)
        return [minX - pad, minY - pad, maxX + pad, maxY + pad]
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

private enum PickImageBounds {
    struct Result {
        let width: Int
        let height: Int
        let bounds: [String: [BedPoint]]
    }

    static func read(_ data: Data, objectIDs: Set<String>) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var extents: [String: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let id = Int(pixels[offset]) | Int(pixels[offset + 1]) << 8 | Int(pixels[offset + 2]) << 16
                let key = String(id)
                guard id > 0, objectIDs.contains(key) else { continue }
                if let old = extents[key] {
                    extents[key] = (min(old.minX, x), min(old.minY, y), max(old.maxX, x), max(old.maxY, y))
                } else {
                    extents[key] = (x, y, x, y)
                }
            }
        }
        let bounds = extents.mapValues { box in
            [BedPoint(x: Double(box.minX), y: Double(box.minY)),
             BedPoint(x: Double(box.maxX), y: Double(box.minY)),
             BedPoint(x: Double(box.maxX), y: Double(box.maxY)),
             BedPoint(x: Double(box.minX), y: Double(box.maxY))]
        }
        return Result(width: width, height: height, bounds: bounds)
    }
}

private final class SliceObjectParser: NSObject, XMLParserDelegate {
    private(set) var objects: [(id: String, name: String)] = []
    static func parse(_ data: Data) -> [(id: String, name: String)] {
        let parser = XMLParser(data: data), delegate = SliceObjectParser()
        parser.delegate = delegate; parser.parse(); return delegate.objects
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        guard name == "object", let id = attrs["identify_id"] else { return }
        objects.append((id, attrs["name"] ?? "Object \(objects.count + 1)"))
    }
}

private final class PlateSliceObjectParser: NSObject, XMLParserDelegate {
    struct Result {
        let objects: [(id: String, name: String)]
        let labelObjectEnabled: Bool?
    }

    private let wantedPlate: Int
    private var inPlate = false
    private var currentPlate: Int?
    private var currentLabelObjectEnabled: Bool?
    private var pending: [(id: String, name: String)] = []
    private var result: [(id: String, name: String)] = []
    private var resultLabelObjectEnabled: Bool?

    private init(wantedPlate: Int) { self.wantedPlate = wantedPlate }

    static func parse(_ data: Data, plateIndex: Int) -> Result {
        let parser = XMLParser(data: data), delegate = PlateSliceObjectParser(wantedPlate: plateIndex)
        parser.delegate = delegate
        parser.parse()
        return Result(objects: delegate.result, labelObjectEnabled: delegate.resultLabelObjectEnabled)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        if name == "plate" {
            inPlate = true; currentPlate = nil; currentLabelObjectEnabled = nil; pending.removeAll()
        } else if name == "metadata", inPlate, attrs["key"] == "index" {
            currentPlate = Int(attrs["value"] ?? "")
        } else if name == "metadata", inPlate, attrs["key"] == "label_object_enabled" {
            currentLabelObjectEnabled = attrs["value"]?.lowercased() == "true"
        } else if name == "object", inPlate, let id = attrs["identify_id"] {
            pending.append((id, attrs["name"] ?? "Object \(pending.count + 1)"))
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "plate", inPlate else { return }
        if currentPlate == wantedPlate {
            result = pending
            resultLabelObjectEnabled = currentLabelObjectEnabled
        }
        inPlate = false
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
