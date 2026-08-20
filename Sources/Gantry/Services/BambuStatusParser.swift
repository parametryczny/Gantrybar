import Foundation

enum BambuStatusParser {
    static func telemetry(from data: Data, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = (root["print"] ?? root["pushing"]) as? [String: Any] else { return nil }

        var result = previous
        if let state = string(report["gcode_state"]) { result.state = mapState(state) }
        if let value = integer(report["mc_percent"]) { result.progress = min(max(value, 0), 100) }
        if let value = integer(report["mc_remaining_time"]) { result.remainingMinutes = value }
        if let value = number(report["nozzle_temper"]) { result.nozzleTemperature = value }
        if let value = number(report["nozzle_target_temper"]) { result.nozzleTargetTemperature = value }
        if let value = number(report["bed_temper"]) { result.bedTemperature = value }
        if let value = number(report["bed_target_temper"]) { result.bedTargetTemperature = value }
        // Dual-nozzle printers (H2D / X2D) report each extruder under device.extruder.info as
        // {id, temp}, where temp packs current in the low 16 bits and target in the high 16 bits.
        // On this hardware the LEFT (main) nozzle is id 1 and the RIGHT is id 0 — so the primary
        // reading (nozzleTemperature, shown as "L") comes from id 1. Single-nozzle machines omit
        // this and keep using nozzle_temper above.
        if let device = report["device"] as? [String: Any],
           let extruder = device["extruder"] as? [String: Any],
           let info = extruder["info"] as? [[String: Any]] {
            var byID: [Int: (current: Double, target: Double)] = [:]
            for item in info {
                guard let id = integer(item["id"]), let packed = integer(item["temp"]) else { continue }
                byID[id] = (Double(packed & 0xFFFF), Double((packed >> 16) & 0xFFFF))
            }
            if let left = byID[1] {
                result.nozzleTemperature = left.current           // left / main nozzle
                result.nozzleTargetTemperature = left.target
                result.nozzleTemperature2 = byID[0]?.current       // right nozzle
                result.nozzleTargetTemperature2 = byID[0]?.target
            } else if let only = byID[0] {
                result.nozzleTemperature = only.current
                result.nozzleTargetTemperature = only.target
            }
        }
        // Modern firmware reports the real chamber temperature under device.ctc.info.temp;
        // printers without a chamber sensor (A1, P1) omit it. The legacy chamber_temper field is
        // only a fixed placeholder on those models, so accept it only as a plausible fallback.
        if let device = report["device"] as? [String: Any],
           let info = (device["ctc"] as? [String: Any])?["info"] as? [String: Any],
           let value = number(info["temp"]) {
            result.chamberTemperature = value
        } else if let value = number(report["chamber_temper"]), value > 10 {
            result.chamberTemperature = value
        }
        if let value = integer(report["layer_num"]) { result.currentLayer = value }
        if let value = integer(report["total_layer_num"]) { result.totalLayers = value }
        // Fans (part / aux / chamber), speed level+magnitude and nozzle diameter. Not every model
        // reports each field, so keep the previous value when a key is missing.
        if let value = fanPercent(report["cooling_fan_speed"]) { result.partFanPercent = value }
        if let value = fanPercent(report["big_fan1_speed"]) { result.auxFanPercent = value }
        if let value = fanPercent(report["big_fan2_speed"]) { result.chamberFanPercent = value }
        if let value = integer(report["spd_lvl"]) { result.speedLevel = value }
        if let value = integer(report["spd_mag"]) { result.speedPercent = value }
        if let value = number(report["nozzle_diameter"]), value > 0 { result.nozzleDiameter = value }
        if let stage = report["stage"] as? [String: Any], let value = integer(stage["_id"]) {
            result.currentStage = value
        } else if let value = integer(report["stg_cur"]) {
            result.currentStage = value
        }
        if string(report["print_type"])?.lowercased() == "idle", result.currentStage == 0 {
            result.currentStage = 255
        }
        if let value = string(report["subtask_name"]), !value.isEmpty { result.jobName = displayName(value) }
        if let value = uint64(report["print_error"]) { result.errorCode = value }
        if let hms = report["hms"] as? [[String: Any]] {
            result.hmsCodes = hms.compactMap(hmsCode)
        }
        // External spools live in different places across firmwares:
        //  • older models: a single `vt_tray` dict, inside `print.ams` or at the top level;
        //  • H2D family (e.g. printers with AMS HT): a `print.vir_slot` list, one entry per
        //    external feeder/nozzle, holding the same tray_type/tray_color fields.
        // Gather them all and dedupe by tray id (X1 reports the same spool as both vt_tray and
        // vir_slot) so an externally-loaded spool always shows next to the AMS/AMS HT.
        let amsObject = report["ams"] as? [String: Any]
        var externalTrays: [[String: Any]] = []
        var seenExternalIDs = Set<String>()
        func addExternal(_ dict: [String: Any]?) {
            guard let dict else { return }
            let id = string(dict["id"]) ?? integer(dict["id"]).map(String.init) ?? ""
            if !id.isEmpty, !seenExternalIDs.insert(id).inserted { return }
            externalTrays.append(dict)
        }
        for slot in (report["vir_slot"] as? [[String: Any]]) ?? [] { addExternal(slot) }
        addExternal((amsObject?["vt_tray"] as? [String: Any]) ?? (report["vt_tray"] as? [String: Any]))
        if amsObject != nil || !externalTrays.isEmpty {
            let ams = amsObject ?? [:]
            // Dev diagnostic: keep the raw AMS-related JSON so the detail card can show exactly what
            // the printer reports — this distinguishes "printer still remembers the filament" from a
            // display retention bug.
            var raw: [String: Any] = [:]
            if let amsObject { raw["ams"] = amsObject }
            if let vt = report["vt_tray"] { raw["vt_tray"] = vt }
            if let vir = report["vir_slot"] { raw["vir_slot"] = vir }
            if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                result.debugAMS = string
            }
            // Partial status updates during a print often carry only `tray_now` without the tray
            // list. Rebuilding from that alone would blank the modules and drop the active ring, so
            // parseAMSGroups keeps the last known groups and preserves the active slot.
            if let groups = parseAMSGroups(ams, externalTrays: externalTrays, previous: result.filamentGroups) {
                result.filamentGroups = groups
            }
            // Flat compatibility view for notifications / menu bar, plus the legacy humidity/temp
            // fields used by the AMS summary.
            let flat = result.filamentGroups.flatMap(\.legacyAMSSlots)
            if !flat.isEmpty { result.amsSlots = flat }
            if let humidity = result.filamentGroups.compactMap(\.humidityPercent).first {
                result.amsHumidity = humidity
            }
            if let temperature = result.filamentGroups.compactMap(\.temperatureCelsius).first {
                result.amsTemperature = temperature
            }
        }
        // Publish the nozzle collection the dashboard renders. Starting from `previous` means a
        // partial report that omits the second extruder keeps the last known right-nozzle values.
        if result.nozzleTemperature2 != nil || result.nozzleTargetTemperature2 != nil {
            result.nozzles = [
                NozzleTelemetry(position: .left, currentTemperature: result.nozzleTemperature,
                                targetTemperature: result.nozzleTargetTemperature),
                NozzleTelemetry(position: .right, currentTemperature: result.nozzleTemperature2,
                                targetTemperature: result.nozzleTargetTemperature2)
            ]
        } else {
            result.nozzles = [
                NozzleTelemetry(position: .single, currentTemperature: result.nozzleTemperature,
                                targetTemperature: result.nozzleTargetTemperature)
            ]
        }
        if result.errorCode != 0 { result.state = .error }
        result.lastUpdated = Date()
        return result
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.uppercased() {
        case "RUNNING", "PREPARE": .printing
        case "PAUSE", "PAUSED": .paused
        case "FINISH", "FINISHED": .finished
        case "FAILED", "ERROR": .error
        case "IDLE": .idle
        default: .idle
        }
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func displayName(_ raw: String) -> String {
        var value = raw.removingPercentEncoding ?? raw
        if value.contains("Ã") || value.contains("Å") || value.contains("Ä") {
            if let bytes = value.data(using: .windowsCP1252),
               let repaired = String(data: bytes, encoding: .utf8) {
                value = repaired
            }
        }
        return value.precomposedStringWithCanonicalMapping
    }

    /// Bambu reports fan speeds as a 0–15 gear (some firmwares already send a 0–100 percentage).
    /// Normalise both to a percentage.
    private static func fanPercent(_ value: Any?) -> Int? {
        guard let raw = integer(value) else { return nil }
        if raw > 15 { return min(raw, 100) }
        return Int((Double(raw) / 15.0 * 100).rounded())
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String {
            if let decimal = UInt64(string) { return decimal }
            return UInt64(string.replacingOccurrences(of: "0x", with: ""), radix: 16)
        }
        return nil
    }

    private static func hmsCode(_ item: [String: Any]) -> String? {
        guard let code = uint64(item["code"]) else { return nil }
        let attr = uint64(item["attr"]) ?? 0
        if attr == 0, let raw = item["ecode"] as? String, !raw.isEmpty {
            return raw.replacingOccurrences(of: "_", with: "").uppercased()
        }
        return String(format: "%08llX%08llX", attr, code)
    }

    /// Build one `FilamentGroup` per physical unit (`ams.ams[]`) plus an `EXT` group for `vt_tray`.
    /// Returns `nil` for a pure-partial report so the caller keeps its previous groups untouched.
    private static func parseAMSGroups(_ ams: [String: Any], externalTrays: [[String: Any]], previous: [FilamentGroup]) -> [FilamentGroup]? {
        let hasTrayNow = ams["tray_now"] != nil
        let activeRaw = string(ams["tray_now"]) ?? integer(ams["tray_now"]).map(String.init) ?? ""
        // Only trust `tray_now` as authoritative when it names a real slot. Some reports carry the
        // tray list without a usable `tray_now`; recomputing active from that would wrongly clear
        // the ring, so we fall back to the previously active slot instead.
        let activeAuthoritative = hasTrayNow && !activeRaw.isEmpty && activeRaw != "255"
        let previousActiveID = previous.flatMap(\.slots).first(where: \.isActive)?.id
        func resolveActive(id: String, matches: Bool) -> Bool {
            activeAuthoritative ? matches : (id == previousActiveID)
        }

        var groups: [FilamentGroup] = []

        if let units = ams["ams"] as? [[String: Any]], !units.isEmpty {
            for (unitIndex, unit) in units.enumerated() {
                let unitID = string(unit["id"]) ?? String(unitIndex)
                let letter = String(UnicodeScalar(65 + min(unitIndex, 25))!)
                let trays = unit["tray"] as? [[String: Any]] ?? []
                // A single-spool AMS identifies itself as unit 128. A regular AMS owns four fixed
                // positions, including currently empty ones — capacity never shrinks when spools go.
                let isSingle = unitID == "128" || (trays.count == 1 && unitID != String(unitIndex))
                let capacity = isSingle ? 1 : 4
                var slots: [FilamentSlot] = []
                for trayIndex in 0..<capacity {
                    let tray = trays.indices.contains(trayIndex) ? trays[trayIndex] : [:]
                    let trayID = string(tray["id"]) ?? integer(tray["id"]).map(String.init) ?? String(trayIndex)
                    let rawMaterial = string(tray["tray_type"]) ?? string(tray["tray_sub_brands"])
                    let material = (rawMaterial?.isEmpty == false) ? rawMaterial : nil
                    let slotID = "ams-\(unitID)-\(trayID)"
                    let globalIndex = unitIndex * 4 + trayIndex
                    let matches = activeRaw == String(globalIndex) || activeRaw == "\(unitID)\(trayID)"
                    slots.append(FilamentSlot(
                        id: slotID,
                        label: "\(letter)\(trayIndex + 1)",
                        material: material,
                        colorHex: material != nil ? (string(tray["tray_color"]) ?? "8E8E93FF") : nil,
                        remainingPercent: material != nil ? integer(tray["remain"]) : nil,
                        isActive: resolveActive(id: slotID, matches: matches)
                    ))
                }
                // Mid-print reports often omit the unit's humidity/temperature. Keep the last known
                // values (like the active slot) so the AMS HT header doesn't blank out during a job.
                let previousUnit = previous.first { $0.id == "ams-\(unitID)" }
                groups.append(FilamentGroup(
                    id: "ams-\(unitID)",
                    sourceType: isSingle ? .amsHT : .ams,
                    displayName: unitID == "128" ? "AMS HT" : "AMS \(letter)",
                    declaredCapacity: capacity,
                    humidityPercent: integer(unit["humidity_raw"]) ?? integer(unit["humidity"]) ?? previousUnit?.humidityPercent,
                    temperatureCelsius: number(unit["temp"]) ?? previousUnit?.temperatureCelsius,
                    isExternal: false,
                    slots: slots
                ))
            }
        }

        let multipleExternals = externalTrays.count > 1
        for (externalIndex, external) in externalTrays.enumerated() {
            // An empty external feeder reports `tray_type=""`; a loaded one (even a third-party spool
            // without RFID) sets a real `tray_type`. So `tray_type` alone distinguishes empty vs loaded.
            let rawMaterial = string(external["tray_type"]) ?? string(external["tray_sub_brands"])
            let material = (rawMaterial?.isEmpty == false) ? rawMaterial : nil
            let trayID = string(external["id"]) ?? integer(external["id"]).map(String.init) ?? "254"
            let slotID = "external-\(trayID)"
            let matches = activeRaw == trayID || activeRaw == "254" || activeRaw == "255"
            // Show the external module when a spool is loaded (has a material) OR when the printer
            // is actively feeding from it, even if this partial report hasn't filled in the type yet.
            // A truly idle/absent external tray (no material, not active) stays hidden to avoid clutter.
            guard material != nil || (activeAuthoritative && matches) else { continue }
            // A printer with two external feeders (H2D dual nozzle) numbers them so they stay distinct.
            let label = multipleExternals ? "EXT \(externalIndex + 1)" : "EXT"
            groups.append(FilamentGroup(
                id: slotID,
                sourceType: .external,
                displayName: label,
                declaredCapacity: 1,
                humidityPercent: nil,
                temperatureCelsius: nil,
                isExternal: true,
                slots: [FilamentSlot(
                    id: slotID,
                    label: label,
                    material: material,
                    colorHex: material != nil ? (string(external["tray_color"]) ?? "E8E8E8FF") : nil,
                    remainingPercent: material != nil ? integer(external["remain"]) : nil,
                    isActive: resolveActive(id: slotID, matches: matches)
                )]
            ))
        }

        // Pure-partial report (no unit list, no external): keep the previously known modules so the
        // dock and its active ring survive until the next full report.
        if groups.isEmpty { return previous.isEmpty ? nil : previous }
        return groups
    }

}
