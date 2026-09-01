import Foundation

enum ElegooStatusParser {
    static func deepMerge(_ base: [String: Any], _ update: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in update {
            if let old = result[key] as? [String: Any], let new = value as? [String: Any] {
                result[key] = deepMerge(old, new)
            } else { result[key] = value }
        }
        return result
    }

    static func cc2(result: [String: Any], previous: PrinterTelemetry = PrinterTelemetry()) -> PrinterTelemetry {
        var value = previous
        let machine = result["machine_status"] as? [String: Any] ?? [:]
        let print = result["print_status"] as? [String: Any] ?? [:]
        let extruder = result["extruder"] as? [String: Any] ?? [:]
        let bed = result["heater_bed"] as? [String: Any] ?? [:]
        let chamber = result["ztemperature_sensor"] as? [String: Any] ?? result["chamber"] as? [String: Any] ?? [:]
        let fans = result["fans"] as? [String: Any] ?? [:]
        let move = result["gcode_move_inf"] as? [String: Any] ?? result["gcode_move"] as? [String: Any] ?? [:]
        let internalState = string(print["state"]).lowercased()
        let status = int(machine["status"]) ?? 1
        let substatus = int(machine["sub_status"])
        let errors = machine["exception_status"] as? [Any] ?? []
        if internalState == "error" || !errors.isEmpty || status == 14 { value.state = .error }
        else if [2501, 2502, 2505].contains(substatus ?? -1) || internalState.contains("paus") { value.state = .paused }
        else if substatus == 2077 || internalState.contains("complete") { value.state = .finished }
        else if status == 2 || internalState == "printing" || internalState == "resuming" { value.state = .printing }
        else { value.state = .idle }
        if let progress = int(print["progress"] ?? machine["progress"]) { value.progress = max(0, min(100, progress)) }
        if let seconds = int(print["remaining_time_sec"]) { value.remainingMinutes = max(0, Int((Double(seconds) / 60).rounded())) }
        if print.keys.contains("filename") { value.jobName = optionalString(print["filename"]) }
        if print.keys.contains("current_layer") { value.currentLayer = int(print["current_layer"]) }
        if print.keys.contains("total_layer") { value.totalLayers = int(print["total_layer"]) }
        if print.keys.contains("filament_used") { value.filamentUsedMM = double(print["filament_used"]) }
        if extruder.keys.contains("temperature") { value.nozzleTemperature = double(extruder["temperature"]) }
        if extruder.keys.contains("target") { value.nozzleTargetTemperature = double(extruder["target"]) }
        if bed.keys.contains("temperature") { value.bedTemperature = double(bed["temperature"]) }
        if bed.keys.contains("target") { value.bedTargetTemperature = double(bed["target"]) }
        if chamber.keys.contains("temperature") { value.chamberTemperature = double(chamber["temperature"]) }
        value.partFanPercent = fan(fans["fan"], fallback: value.partFanPercent)
        value.auxFanPercent = fan(fans["aux_fan"], fallback: value.auxFanPercent)
        value.chamberFanPercent = fan(fans["box_fan"], fallback: value.chamberFanPercent)
        if let mode = int(move["speed_mode"]) {
            value.speedLevel = mode + 1
            value.speedPercent = [0: 50, 1: 100, 2: 150, 3: 200][mode]
        }
        if !errors.isEmpty {
            value.hmsCodes = errors.map { string($0) }
            value.errorCode = UInt64(int(errors.first) ?? 0)
        }
        value.lastUpdated = Date()
        return value
    }

    static func canvas(result: [String: Any], previous: PrinterTelemetry) -> PrinterTelemetry {
        guard let info = result["canvas_info"] as? [String: Any],
              let canvases = info["canvas_list"] as? [[String: Any]] else { return previous }
        let activeCanvas = int(info["active_canvas_id"]), activeTray = int(info["active_tray_id"])
        var groups: [FilamentGroup] = []
        for canvas in canvases where int(canvas["connected"]) != 0 {
            let canvasID = int(canvas["canvas_id"]) ?? 0
            let trays = canvas["tray_list"] as? [[String: Any]] ?? []
            let indexed = Dictionary(uniqueKeysWithValues: trays.map { (int($0["tray_id"]) ?? 0, $0) })
            let slots = (0..<4).map { trayID -> FilamentSlot in
                let tray = indexed[trayID] ?? [:]
                let present = (int(tray["status"]) ?? 0) > 0
                var color = optionalString(tray["filament_color"])?.replacingOccurrences(of: "#", with: "")
                if color?.count == 6 { color! += "FF" }
                return FilamentSlot(id: "canvas-\(canvasID)-\(trayID)", label: "\(Character(UnicodeScalar(65 + canvasID)!))\(trayID + 1)",
                    material: present ? optionalString(tray["filament_type"] ?? tray["filament_name"]) : nil,
                    colorHex: present ? color : nil, remainingPercent: nil,
                    isActive: present && canvasID == activeCanvas && trayID == activeTray)
            }
            groups.append(FilamentGroup(id: "canvas-\(canvasID)", sourceType: .canvas,
                displayName: canvasID == 0 ? "CANVAS" : "CANVAS \(Character(UnicodeScalar(65 + canvasID)!))",
                declaredCapacity: 4, humidityPercent: nil, temperatureCelsius: nil, isExternal: false, slots: slots))
        }
        guard !groups.isEmpty else { return previous }
        var value = previous
        value.filamentGroups = groups
        value.amsSlots = groups.flatMap(\.legacyAMSSlots)
        value.lastUpdated = Date()
        return value
    }

    static func cc1(data: Data, previous: PrinterTelemetry = PrinterTelemetry()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data), let status = findDictionary(named: "Status", in: root) else { return nil }
        var value = previous
        let print = status["PrintInfo"] as? [String: Any] ?? [:]
        let printStatus = int(print["Status"]) ?? 0
        let error = int(print["ErrorNumber"]) ?? 0
        if error != 0 || printStatus == 14 { value.state = .error }
        else if [5, 6].contains(printStatus) { value.state = .paused }
        else if [1, 7, 13, 15, 16].contains(printStatus) { value.state = .printing }
        else if printStatus == 9 { value.state = .finished }
        else { value.state = .idle }
        for (key, path) in [("TempOfNozzle", \PrinterTelemetry.nozzleTemperature),
                            ("TempTargetNozzle", \PrinterTelemetry.nozzleTargetTemperature),
                            ("TempOfHotbed", \PrinterTelemetry.bedTemperature),
                            ("TempTargetHotbed", \PrinterTelemetry.bedTargetTemperature),
                            ("TempOfBox", \PrinterTelemetry.chamberTemperature)] {
            if status.keys.contains(key) { value[keyPath: path] = double(status[key]) }
        }
        if let progress = int(print["Progress"]) { value.progress = max(0, min(100, progress)) }
        if print.keys.contains("CurrentLayer") { value.currentLayer = int(print["CurrentLayer"]) }
        if print.keys.contains("TotalLayer") { value.totalLayers = int(print["TotalLayer"]) }
        if print.keys.contains("Filename") { value.jobName = optionalString(print["Filename"]) }
        if let current = double(print["CurrentTicks"]), let total = double(print["TotalTicks"]) {
            value.remainingMinutes = max(0, Int(((total - current) / 60).rounded()))
        }
        value.errorCode = UInt64(error); value.lastUpdated = Date()
        return value
    }

    private static func findDictionary(named key: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let found = dictionary[key] as? [String: Any] { return found }
            for child in dictionary.values { if let found = findDictionary(named: key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = findDictionary(named: key, in: child) { return found } }
        }
        return nil
    }
    private static func int(_ value: Any?) -> Int? { if let n = value as? NSNumber { return n.intValue }; return Int(string(value)) }
    private static func double(_ value: Any?) -> Double? { if let n = value as? NSNumber { return n.doubleValue }; return Double(string(value)) }
    private static func string(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
    private static func optionalString(_ value: Any?) -> String? { let result = string(value); return result.isEmpty || result == "<null>" ? nil : result }
    private static func fan(_ value: Any?, fallback: Int?) -> Int? {
        guard let object = value as? [String: Any], let raw = double(object["speed"]) else { return fallback }
        return max(0, min(100, Int((raw / 255 * 100).rounded())))
    }
}
