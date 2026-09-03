import Foundation

/// Parses a Moonraker `printer/objects/query` response into PrinterTelemetry, including the
/// Happy Hare `mmu` object mapped to AMS slots. Field names verified defensively; unknown or
/// missing values fall back to the previous telemetry.
enum MoonrakerStatusParser {
    static func telemetry(from data: Data, previous: PrinterTelemetry = .init(),
                          objects: MoonrakerObjects = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = root["result"] as? [String: Any] ?? root
        guard let status = result["status"] as? [String: Any] else { return nil }

        var telemetry = previous

        if let printStats = status["print_stats"] as? [String: Any] {
            if let state = string(printStats["state"]) { telemetry.state = mapState(state) }
            if let name = string(printStats["filename"]), !name.isEmpty {
                telemetry.jobName = (name as NSString).lastPathComponent
            }
            if let info = printStats["info"] as? [String: Any] {
                if let current = integer(info["current_layer"]) { telemetry.currentLayer = current }
                if let total = integer(info["total_layer"]) { telemetry.totalLayers = total }
            }
            // Real measured filament consumed so far (mm) — the basis for spool decrement on finish.
            if let used = number(printStats["filament_used"]) { telemetry.filamentUsedMM = used }
        }

        // Creality K1/K1Max leave print_stats.info.*_layer null and expose layers on virtual_sdcard.
        if let vsd = status["virtual_sdcard"] as? [String: Any] {
            if telemetry.currentLayer == nil, let layer = integer(vsd["layer"]) { telemetry.currentLayer = layer }
            if telemetry.totalLayers == nil, let count = integer(vsd["layer_count"]) { telemetry.totalLayers = count }
        }

        // Progress: display_status is the slicer/M73 value; fall back to sd position.
        let progress = number((status["display_status"] as? [String: Any])?["progress"])
            ?? number((status["virtual_sdcard"] as? [String: Any])?["progress"])
        if let progress {
            telemetry.progress = min(max(Int((progress * 100).rounded()), 0), 100)
        }

        // ETA from elapsed print time and progress.
        if let printStats = status["print_stats"] as? [String: Any],
           let duration = number(printStats["print_duration"]), duration > 0,
           let progress, progress > 0.01 {
            let remainingSeconds = duration * (1 - progress) / progress
            telemetry.remainingMinutes = Int((remainingSeconds / 60).rounded())
        }

        if let extruder = status[objects.nozzle] as? [String: Any] {
            if let temp = number(extruder["temperature"]) { telemetry.nozzleTemperature = temp }
            if let target = number(extruder["target"]) { telemetry.nozzleTargetTemperature = target }
        }
        if let bed = status[objects.bed] as? [String: Any] {
            if let temp = number(bed["temperature"]) { telemetry.bedTemperature = temp }
            if let target = number(bed["target"]) { telemetry.bedTargetTemperature = target }
        }
        // Chamber: the overridden object if given, else any temperature_sensor / heater_generic whose
        // name mentions "chamber".
        if let name = objects.chamber, let object = status[name] as? [String: Any],
           let temp = number(object["temperature"]) {
            telemetry.chamberTemperature = temp
        } else if let chamber = chamberTemperature(in: status) {
            telemetry.chamberTemperature = chamber
        }

        // Fans. Klipper exposes the part cooler as plain `fan`, but everything else (auxiliary, chamber,
        // exhaust) arrives as `fan_generic <name>` / `heater_fan <name>` / `controller_fan <name>`, and
        // some vendor forks (Creality among them) do not publish a bare `fan` at all. So classify by
        // name over whatever the query returned instead of reading one hard-coded object.
        applyFans(status: status, preferredPartName: objects.fan, into: &telemetry)
        if let gm = status["gcode_move"] as? [String: Any], let factor = number(gm["speed_factor"]) {
            telemetry.speedPercent = Int((factor * 100).rounded())
        }

        if let mmu = status["mmu"] as? [String: Any], let group = parseMMUGroup(mmu) {
            telemetry.filamentGroups = [group]
            telemetry.amsSlots = group.legacyAMSSlots
        }

        // Single-nozzle Klipper machine: expose one nozzle entry so the dashboard renders it via the
        // shared collection just like Bambu.
        telemetry.nozzles = [
            NozzleTelemetry(position: .single, currentTemperature: telemetry.nozzleTemperature,
                            targetTemperature: telemetry.nozzleTargetTemperature)
        ]

        telemetry.lastUpdated = Date()
        return telemetry
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.lowercased() {
        case "printing": .printing
        case "paused": .paused
        case "complete", "completed": .finished
        case "error": .error
        case "cancelled", "canceled", "standby": .idle
        default: .idle
        }
    }

    /// Klipper fan object prefixes. `fan` is the part cooler; the rest carry a name after a space.
    private static let fanPrefixes = ["fan_generic ", "heater_fan ", "controller_fan ", "temperature_fan "]

    private static func applyFans(status: [String: Any], preferredPartName: String,
                                  into telemetry: inout PrinterTelemetry) {
        func percent(_ object: Any?) -> Int? {
            guard let dict = object as? [String: Any] else { return nil }
            // `speed` for fans, `value` for an output_pin driving one; both are 0..1.
            guard let raw = number(dict["speed"]) ?? number(dict["value"]) else { return nil }
            return Int((min(max(raw, 0), 1) * 100).rounded())
        }

        // Collect first, decide after: dictionary order is not defined, so classifying inside the loop
        // let a `heater_fan` claim the part slot before the real `fan` was ever seen.
        var readings: [(name: String, percent: Int)] = []
        for key in status.keys.sorted() {
            let isFan = key == preferredPartName || key == "fan"
                || fanPrefixes.contains(where: { key.hasPrefix($0) })
            guard isFan, let reading = percent(status[key]) else { continue }
            readings.append((key, reading))
        }
        func first(where matches: (String) -> Bool) -> Int? {
            readings.first { matches($0.name.lowercased()) }?.percent
        }

        if let explicit = readings.first(where: { $0.name == preferredPartName || $0.name == "fan" })?.percent {
            telemetry.partFanPercent = explicit
        } else if let named = first(where: { $0.contains("part") || $0.contains("cooling") }) {
            telemetry.partFanPercent = named
        } else if let lone = readings.first(where: { !$0.name.hasPrefix("heater_fan")
                                                 && !$0.name.hasPrefix("controller_fan") })?.percent {
            // A vendor fork with no bare `fan`: the one generic fan it does publish is the part cooler.
            // Heater and controller fans are excluded, they cool the hotend and the electronics.
            telemetry.partFanPercent = lone
        }
        if let aux = first(where: { $0.contains("aux") || $0.contains("side") }) {
            telemetry.auxFanPercent = aux
        }
        if let chamber = first(where: { $0.contains("chamber") || $0.contains("exhaust") || $0.contains("filter") }) {
            telemetry.chamberFanPercent = chamber
        }
    }

    private static func chamberTemperature(in status: [String: Any]) -> Double? {
        for (key, value) in status where key.lowercased().contains("chamber") {
            if (key.hasPrefix("temperature_sensor") || key.hasPrefix("heater_generic")),
               let object = value as? [String: Any],
               let temp = number(object["temperature"]) {
                return temp
            }
        }
        return nil
    }

    /// Happy Hare is one dynamic module: `num_gates` gates named `T0…Tn`, never split into sets of
    /// four. Empty gates (status 0) stay as grey slots so the layout keeps its width.
    private static func parseMMUGroup(_ mmu: [String: Any]) -> FilamentGroup? {
        if let enabled = mmu["enabled"] as? Bool, !enabled { return nil }
        guard let count = integer(mmu["num_gates"]), count > 0 else { return nil }

        let materials = mmu["gate_material"] as? [Any] ?? []
        let colors = mmu["gate_color"] as? [Any] ?? []
        let statuses = mmu["gate_status"] as? [Any] ?? []
        let currentGate = integer(mmu["gate"]) ?? -1

        var slots: [FilamentSlot] = []
        for index in 0..<count {
            let gateStatus = index < statuses.count ? (integer(statuses[index]) ?? -1) : -1
            let rawMaterial = index < materials.count ? (string(materials[index]) ?? "") : ""
            let present = gateStatus != 0 && !rawMaterial.isEmpty
            slots.append(FilamentSlot(
                id: "mmu-\(index)",
                label: "T\(index)",
                material: present ? rawMaterial : nil,
                colorHex: present ? amsColor(index < colors.count ? string(colors[index]) : nil) : nil,
                remainingPercent: nil,
                isActive: index == currentGate
            ))
        }
        return FilamentGroup(
            id: "mmu",
            sourceType: .mmu,
            displayName: "MMU",
            declaredCapacity: count,
            humidityPercent: nil,
            temperatureCelsius: nil,
            isExternal: false,
            slots: slots
        )
    }

    /// Parses a Creality CFS WebSocket `boxsInfo` reply into filament groups. Each `materialBoxs[]`
    /// element is a separate physical unit: `type == 1` is the external spool holder (EXT), the rest
    /// are `CFS 1`, `CFS 2`, … keeping four fixed positions. Creality's filament system is not a
    /// Klipper object; it lives on the printer's own `ws://host:9999` API and is fed in on the side.
    static func parseCFSGroups(from data: Data) -> [FilamentGroup]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // The box data may sit under "boxsInfo" or directly at the root, depending on firmware.
        let container = (root["boxsInfo"] as? [String: Any])
            ?? (root["result"] as? [String: Any])
            ?? root
        guard let boxes = container["materialBoxs"] as? [[String: Any]] else { return nil }

        var groups: [FilamentGroup] = []
        var cfsNumber = 0
        var slotNumber = 0
        for (boxIndex, box) in boxes.enumerated() {
            let isSpoolHolder = (integer(box["type"]) ?? 0) == 1
            let materials = box["materials"] as? [[String: Any]] ?? []
            let capacity = isSpoolHolder ? 1 : 4
            var slots: [FilamentSlot] = []
            for slotIndex in 0..<capacity {
                let material = slotIndex < materials.count ? materials[slotIndex] : [:]
                let type = string(material["type"]) ?? ""
                let name = string(material["name"]) ?? ""
                let display = !type.isEmpty ? type : (name.isEmpty ? nil : name)
                let present = display != nil
                let isActive = (integer(material["selected"]) ?? 0) == 1
                let label = isSpoolHolder ? "EXT" : "T\(slotNumber)"
                if !isSpoolHolder { slotNumber += 1 }
                slots.append(FilamentSlot(
                    id: "cfs-\(boxIndex)-\(slotIndex)",
                    label: label,
                    material: display,
                    colorHex: present ? cfsColor(string(material["color"])) : nil,
                    remainingPercent: integer(material["percent"]),
                    isActive: isActive
                ))
            }
            if isSpoolHolder {
                groups.append(FilamentGroup(
                    id: "cfs-ext-\(boxIndex)", sourceType: .external, displayName: "EXT",
                    declaredCapacity: 1, humidityPercent: nil, temperatureCelsius: nil,
                    isExternal: true, slots: slots
                ))
            } else {
                cfsNumber += 1
                groups.append(FilamentGroup(
                    id: "cfs-\(boxIndex)", sourceType: .cfs, displayName: "CFS \(cfsNumber)",
                    declaredCapacity: capacity, humidityPercent: nil, temperatureCelsius: nil,
                    isExternal: false, slots: slots
                ))
            }
        }
        return groups.isEmpty ? nil : groups
    }

    /// CFS colours are hex, sometimes with an extra leading zero (e.g. "0fa7c0c" → "fa7c0c").
    private static func cfsColor(_ raw: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "8E8E93FF" }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 7 { value.removeFirst() }
        return amsColor(value)
    }

    /// Happy Hare gate colours are hex (6 chars) or a named colour; normalise to RRGGBBAA.
    private static func amsColor(_ raw: String?) -> String {
        guard var value = raw, !value.isEmpty else { return "8E8E93FF" }
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 6 { return (value + "FF").uppercased() }
        if value.count == 8 { return value.uppercased() }
        return "8E8E93FF"
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? { number(value).map(Int.init) }
}
