import Foundation
import Compression

struct FarmError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct FarmFilament: Codable, Sendable, Equatable {
    var id: Int; var material: String; var color: String; var grams: Double
}
struct FarmPlate: Codable, Sendable, Equatable {
    var index: Int
    var filaments: [FarmFilament] = []
    var seconds: Int?
    var printerModel: String?
    var nozzle: Double?
}
struct FarmFile: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var bytes: Int
    var plates: [FarmPlate]
    var importedAt: Date
    /// "gcode" or "bgcode" for files printed on Klipper, PrusaLink and OctoPrint; nil for a Bambu 3MF.
    var format: String? = nil
    var fileExtension: String { format ?? "3mf" }
    var isGcode: Bool { format != nil }
}
struct FarmJob: Codable, Identifiable, Sendable {
    enum State: String, Codable { case uploading, uploaded, awaitingStart, printing, finished, failed, uncertain }
    var id: UUID
    var fileID: UUID
    var fileName: String
    var serial: String
    var printerName: String
    var plate: FarmPlate
    var mapping: [Int]
    var remoteName: String
    var state: State
    var message: String
    var createdAt: Date
    var startRequestedAt: Date?
    var updatedAt: Date
    var bedLeveling = true
    /// Queue entry this job was dispatched from; nil for jobs sent by hand.
    var queueItemID: UUID? = nil
    /// Dispatched by the queue to an armed printer: starts by itself once the upload lands.
    var autoStart: Bool? = nil
    /// A G-code job, started over HTTP; a 3MF job is a Bambu project_file start.
    var isGcode: Bool { !remoteName.lowercased().hasSuffix(".3mf") }
}
/// A plate waiting for a free printer. Copies are dispatched one per printer, each only to a printer
/// the user marked as having an empty bed, with the file's filaments already loaded in its AMS.
struct FarmQueueItem: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var fileID: UUID
    var fileName: String
    var plate: FarmPlate
    var copies: Int
    /// Serials allowed to take this item; empty means any Bambu Lab printer. G-code items always name
    /// their printers: G-code is sliced for one machine and must not wander to another.
    var printers: [String]
    var createdAt: Date
    var format: String? = nil
}

/// Reads what a slicer writes into a G-code file's comments: time, filaments, nozzle, printer, and the
/// embedded PNG thumbnail. Only the head and tail are scanned, never the whole toolpath.
enum FarmGcode {
    static let extensions: Set<String> = ["gcode", "gco", "g", "bgcode"]

    static func isGcode(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static func format(_ url: URL) -> String { url.pathExtension.lowercased() == "bgcode" ? "bgcode" : "gcode" }

    private static func comments(_ data: Data) -> String {
        let window = 512 * 1024
        let head = data.prefix(window), tail = data.count > window ? data.suffix(window) : Data()
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    /// Key/value comments such as `; filament_type = PLA;PETG` or `;TIME:3600`.
    static func settings(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(";") else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let separator = body.firstIndex(of: "=") ?? body.firstIndex(of: ":")
            guard let separator else { continue }
            let key = body[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count < 80, result[key] == nil else { continue }
            result[key] = value
        }
        return result
    }

    /// "1d 2h 3m 4s" (PrusaSlicer, Orca), or plain seconds.
    static func seconds(_ text: String) -> Int? {
        if let plain = Int(text) { return plain }
        var total = 0, number = "", found = false
        for character in text {
            if character.isNumber { number.append(character); continue }
            guard let value = Int(number) else { number = ""; continue }
            switch character {
            case "d": total += value * 86_400; found = true
            case "h": total += value * 3_600; found = true
            case "m": total += value * 60; found = true
            case "s": total += value; found = true
            default: break
            }
            number = ""
        }
        return found ? total : nil
    }

    static func plate(_ data: Data) -> FarmPlate {
        let values = settings(comments(data))
        var plate = FarmPlate(index: 1)
        plate.seconds = values["estimated printing time (normal mode)"].flatMap(seconds)
            ?? values["time"].flatMap(seconds)
            ?? values["total estimated time"].flatMap(seconds)
        plate.printerModel = values["printer_model"] ?? values["printer_settings_id"]
        plate.nozzle = values["nozzle_diameter"]?.split(separator: ",").first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        func list(_ key: String) -> [String] {
            (values[key] ?? "").split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let materials = list("filament_type"), colours = list("filament_colour"),
            grams = list("filament used [g]").isEmpty ? list("total filament used [g]") : list("filament used [g]")
        for (index, material) in materials.enumerated() where !material.isEmpty {
            let used = index < grams.count ? Double(grams[index]) ?? 0 : 0
            // Unused extruders of a multi-tool profile carry a material but no weight.
            if materials.count > 1, used == 0, !grams.isEmpty { continue }
            plate.filaments.append(FarmFilament(id: index + 1, material: material,
                                                color: index < colours.count ? colours[index] : "", grams: used))
        }
        return plate
    }

    /// The largest `; thumbnail begin WxH N` PNG block (PrusaSlicer, Orca, Cura with the plug-in).
    static func thumbnail(_ data: Data) -> Data? {
        let text = String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self)
        var best: (Int, Data)?
        var collecting: (Int, String)?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("; thumbnail begin") {
                let size = line.split(separator: " ").dropFirst(3).first.map(String.init) ?? ""
                let area = size.split(separator: "x").compactMap { Int($0) }.reduce(1, *)
                collecting = (area, "")
            } else if line.hasPrefix("; thumbnail end") {
                if case let (area, base64)? = collecting, let png = Data(base64Encoded: base64), area > (best?.0 ?? 0) { best = (area, png) }
                collecting = nil
            } else if collecting != nil, line.hasPrefix(";") {
                collecting?.1 += line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
        }
        return best?.1
    }
}

/// Reads only bounded metadata and thumbnails; never expands the plate's G-code to build a preview.
struct FarmArchive {
    struct Entry { let name: String; let offset: Int; let compressed: Int; let size: Int; let method: Int }
    let data: Data
    let entries: [Entry]
    init(data: Data) throws {
        guard data.count >= 22, data.count <= 512 * 1024 * 1024 else { throw FarmError(message: "Plik musi mieć mniej niż 512 MB i być archiwum 3MF.") }
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p+1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p+2) << 16 }
        guard let end = stride(from: data.count-22, through: max(0,data.count-65557), by: -1).first(where: {
            u32($0) == 0x06054b50 && $0 + 22 + u16($0+20) == data.count
        }), u16(end+4) == 0, u16(end+6) == 0, u16(end+10) < 10000 else { throw FarmError(message: "Nieprawidłowe lub nieobsługiwane archiwum 3MF.") }
        var result: [Entry] = []; var p = u32(end+16)
        for _ in 0..<u16(end+10) {
            guard p >= 0, p+46 <= end, u32(p) == 0x02014b50 else { throw FarmError(message: "Uszkodzony spis plików 3MF.") }
            let length=u16(p+28), next=p+46+length+u16(p+30)+u16(p+32)
            guard next <= end, let name=String(data:data.subdata(in:p+46..<p+46+length),encoding:.utf8), u16(p+8)&1 == 0 else { throw FarmError(message: "Nieobsługiwany wpis 3MF.") }
            let local=u32(p+42)
            guard local+30 <= data.count, u32(local)==0x04034b50 else { throw FarmError(message:"Uszkodzony nagłówek 3MF.") }
            let offset=local+30+u16(local+26)+u16(local+28), size=u32(p+20)
            guard offset+size <= data.count, !result.contains(where:{$0.name==name}) else { throw FarmError(message:"Uszkodzony lub powielony wpis 3MF.") }
            result.append(Entry(name:name,offset:offset,compressed:size,size:u32(p+24),method:u16(p+10))); p=next
        }
        self.data=data; entries=result
    }
    func read(_ name: String) -> Data? {
        guard let e=entries.first(where:{$0.name==name}), e.size>0, e.size<=16*1024*1024, e.compressed<=16*1024*1024 else { return nil }
        let input=data.subdata(in:e.offset..<e.offset+e.compressed)
        if e.method==0 { return input.count==e.size ? input : nil }
        guard e.method==8 else { return nil }
        var output=Data(count:e.size+1)
        let n=output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,e.size+1,src.bindMemory(to:UInt8.self).baseAddress!,input.count,nil,COMPRESSION_ZLIB)
        } }
        return n==e.size ? Data(output.prefix(n)) : nil
    }
    func plates() throws -> [FarmPlate] {
        let indices=entries.compactMap { entry -> Int? in
            guard entry.name.hasPrefix("Metadata/plate_"),entry.name.hasSuffix(".gcode"),entry.size>0 else { return nil }
            return Int(entry.name.dropFirst("Metadata/plate_".count).dropLast(6))
        }.filter{$0>0 && $0<1000}.sorted()
        guard !indices.isEmpty else { throw FarmError(message:"To nie jest pocięty plik. W Bambu Studio wybierz eksport pociętej płyty (.3mf).") }
        let metadata=read("Metadata/slice_info.config").map(FarmSliceParser.parse) ?? []
        return indices.map { i in metadata.first(where:{$0.index==i}) ?? FarmPlate(index:i) }
    }
    func preview(_ plate: Int) -> Data? { read("Metadata/plate_\(plate).png") ?? read("Metadata/top_\(plate).png") }
}
private final class FarmSliceParser: NSObject, XMLParserDelegate {
    var plates:[FarmPlate]=[]; var current:FarmPlate?
    static func parse(_ data:Data)->[FarmPlate] { let d=FarmSliceParser(); let p=XMLParser(data:data); p.shouldResolveExternalEntities=false;p.delegate=d;return p.parse() ? d.plates : [] }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        if name=="plate" { current=FarmPlate(index:-1) }
        guard current != nil else { return }
        if name=="metadata",let value=a["value"] {
            switch a["key"] {
            case "index": current?.index=Int(value) ?? -1
            case "prediction":current?.seconds=Int(value)
            case "printer_model_id":current?.printerModel=value
            case "nozzle_diameters":current?.nozzle=Double(value)
            default:break
            }
        }
        if name=="filament",let id=a["id"].flatMap(Int.init),id>0,id<=64 {
            current?.filaments.append(FarmFilament(id:id,material:a["type"] ?? "?",color:a["color"] ?? "",grams:Double(a["used_g"] ?? "") ?? 0))
        }
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) { if name=="plate",let c=current { plates.append(c);current=nil } }
}

enum FarmRules {
    static func slotIndex(_ id:String)->Int? {
        let parts=id.split(separator:"-")
        guard parts.count==3,parts[0]=="ams",let unit=Int(parts[1]),let tray=Int(parts[2]),(0...15).contains(unit),(0...3).contains(tray) else { return nil }
        return unit*4+tray
    }
    static func startBlock(_ t:PrinterTelemetry?,now:Date=Date())->String? {
        guard let t,let updated=t.lastUpdated,now.timeIntervalSince(updated)<30 else { return "Brak świeżego statusu drukarki." }
        guard t.state == .idle || t.state == .finished else { return "Drukarka nie jest gotowa: \(t.state.label)." }
        guard t.errorCode==0 else { return "Drukarka zgłasza błąd." }
        return nil
    }
    static func matches(_ job:FarmJob,_ t:PrinterTelemetry)->Bool {
        let stem=(job.remoteName as NSString).deletingPathExtension
        let reported=t.jobName.map { ($0 as NSString).lastPathComponent }
        return reported==stem || reported==job.remoteName || reported.map { ($0 as NSString).deletingPathExtension==stem } == true
            || t.gcodeFile.map { ($0 as NSString).lastPathComponent == job.remoteName } == true
    }
    static func hexRGB(_ value:String)->(Double,Double,Double)? {
        let hex=value.trimmingCharacters(in:.whitespaces).replacingOccurrences(of:"#",with:"")
        guard hex.count>=6,let v=UInt32(hex.prefix(6),radix:16) else { return nil }
        return (Double(v>>16 & 0xff),Double(v>>8 & 0xff),Double(v & 0xff))
    }
    /// Weighted RGB distance (0…~765); good enough to tell "same spool colour" from "different spool".
    static func colorDistance(_ a:String,_ b:String)->Double? {
        guard let x=hexRGB(a),let y=hexRGB(b) else { return nil }
        let r=(x.0+y.0)/2,dr=x.0-y.0,dg=x.1-y.1,db=x.2-y.2
        return ((2+r/256)*dr*dr+4*dg*dg+(2+(255-r)/256)*db*db).squareRoot()
    }
    /// AMS mapping for a plate from the slots currently loaded: same material, closest colour within
    /// `maxColorDistance`, enough filament when the spool reports its weight. A single-filament plate
    /// may use the external spool (empty mapping). Nil when any filament has no suitable source.
    static func autoMapping(_ plate:FarmPlate,slots:[AMSSlot],maxColorDistance:Double=90)->[Int]? {
        guard !plate.filaments.isEmpty else { return nil }
        func fits(_ s:AMSSlot,_ f:FarmFilament)->Double? {
            guard s.material.caseInsensitiveCompare(f.material) == .orderedSame else { return nil }
            if let grams=s.remainingWeightGrams,grams<f.grams { return nil }
            guard hexRGB(f.color) != nil else { return 0 }
            guard let d=colorDistance(f.color,s.colorHex),d<=maxColorDistance else { return nil }
            return d
        }
        var mapping=Array(repeating:-1,count:plate.filaments.map(\.id).max() ?? 0)
        var complete=true
        for f in plate.filaments {
            let best=slots.compactMap { s->(Int,Double)? in
                guard !s.isExternal,let i=slotIndex(s.id),let d=fits(s,f) else { return nil }
                return (i,d)
            }.min { $0.1<$1.1 }
            if let best { mapping[f.id-1]=best.0 } else { complete=false }
        }
        if complete { return mapping }
        if plate.filaments.count==1,slots.contains(where:{$0.isExternal && fits($0,plate.filaments[0]) != nil}) { return [] }
        return nil
    }
    /// First queue item this printer can take right now, with the AMS mapping to use.
    static func nextQueueItem(_ queue:[FarmQueueItem],serial:String,telemetry t:PrinterTelemetry,accepts:(String?)->Bool={ $0==nil })->(index:Int,mapping:[Int])? {
        for (i,item) in queue.enumerated() where item.copies>0 && (item.printers.isEmpty || item.printers.contains(serial)) && accepts(item.format) {
            if let n=item.plate.nozzle,let a=t.nozzleDiameter,abs(n-a)>0.01 { continue }
            // G-code carries its own filament choice and was sliced for the printers it names.
            if item.format != nil { if item.printers.contains(serial) { return (i,[]) } else { continue } }
            if let m=autoMapping(item.plate,slots:t.amsSlots) { return (i,m) }
        }
        return nil
    }
    static func command(_ job:FarmJob)throws->String {
        let payload:[String:Any] = ["print":["command":"project_file","sequence_id":String(Int(Date().timeIntervalSince1970)),"param":"Metadata/plate_\(job.plate.index).gcode","url":"ftp:///\(job.remoteName)","subtask_name":String(job.remoteName.dropLast(4)),"project_id":"0","profile_id":"0","task_id":"0","subtask_id":"0","file":"","md5":"","bed_type":"auto","bed_levelling":job.bedLeveling,"flow_cali":false,"vibration_cali":false,"timelapse":false,"layer_inspect":false,"use_ams":!job.mapping.isEmpty,"ams_mapping":job.mapping]]
        return String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
    }
}
