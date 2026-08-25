import Foundation

/// Turns a finished print into a spool decrement. The rule (spec §15-18): subtract on FINISH only,
/// never on start; cancelled/failed prints do not auto-subtract; every subtraction is idempotent per
/// print job so a reconnect or restart cannot double-count.
///
/// Source of the grams used differs per printer:
///  - Klipper/Moonraker: real measured `filament_used` (mm) converted to grams here.
///  - Bambu: the slicer's `used_g` read from the printed 3mf (handled by the file reader, wired later).
@MainActor
enum FilamentConsumption {
    private static let filamentDiameterMM = 1.75

    /// Rough densities (g/cm³) by material family; good enough to turn measured length into grams.
    static func density(_ material: String?) -> Double {
        let m = (material ?? "").uppercased()
        if m.contains("PETG") { return 1.27 }
        if m.contains("ABS") { return 1.04 }
        if m.contains("ASA") { return 1.07 }
        if m.contains("TPU") { return 1.21 }
        if m.contains("PVA") { return 1.23 }
        if m.contains("PC") { return 1.20 }
        if m.hasPrefix("PA") { return 1.14 }   // nylon family
        if m.contains("PLA") { return 1.24 }
        return 1.24
    }

    /// grams = cross-section area (mm²) × length (mm) → mm³, ÷1000 → cm³, × density (g/cm³).
    static func grams(lengthMM: Double, material: String?) -> Double {
        let area = Double.pi * (filamentDiameterMM / 2) * (filamentDiameterMM / 2)
        return lengthMM * area / 1000 * density(material)
    }

    /// A stable-enough job id: same finished print reported twice (reconnect/restart within the hour)
    /// dedupes, while a genuinely new print in a later hour is treated as a fresh job.
    static func jobID(serial: String, telemetry: PrinterTelemetry) -> String {
        "\(serial)|\(telemetry.jobName ?? "?")|\(Int(Date().timeIntervalSince1970 / 3600))"
    }

    /// Called on every telemetry update. Acts only on the transition into `.finished`.
    static func onUpdate(printer: SavedPrinter, previous: PrinterTelemetry?, current: PrinterTelemetry) {
        guard previous?.state != .finished, current.state == .finished else { return }
        switch printer.kind {
        case .klipper: consumeKlipper(printer: printer, telemetry: current)
        case .bambu: consumeBambu(printer: printer, telemetry: current)
        default: break   // no local grams source for other kinds yet.
        }
    }

    /// Bambu: fetch the printed `.gcode.3mf` over the printer's local FTPS, read the slicer's `used_g`
    /// per filament, map each filament to its AMS slot by colour, and subtract from the assigned spool.
    private static func consumeBambu(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        guard let file = telemetry.gcodeFile, !file.isEmpty else { return }
        guard let code = try? AccessCodeStore.readAccessCode(for: printer.serial), !code.isEmpty else { return }
        let host = printer.host
        let serial = printer.serial
        let groups = telemetry.filamentGroups
        let job = jobID(serial: serial, telemetry: telemetry)
        Task {
            let client = BambuFileClient(host: host, accessCode: code)
            do {
                let data = try await client.fetch(fileName: file)
                let filaments = ThreeMFReader.filaments(fromData: data)
                await MainActor.run { applyBambu(serial: serial, groups: groups, filaments: filaments, job: job) }
            } catch {
                NSLog("Spoolbase: nie udało się pobrać/odczytać 3mf dla %@ (%@): %@", serial, file, "\(error)")
            }
        }
    }

    /// Maps each sliced filament to a physical slot (by colour; single filament falls back to the loaded
    /// slot) and subtracts its grams from the assigned spool. Idempotent per filament within the job.
    @MainActor
    private static func applyBambu(serial: String, groups: [FilamentGroup], filaments: [SlicedFilament], job: String) {
        func location(colorHex: String) -> SpoolLocation? {
            for (gi, group) in groups.enumerated() {
                for (si, slot) in group.slots.enumerated() {
                    let slotHex = (slot.colorHex ?? "").replacingOccurrences(of: "#", with: "").uppercased()
                    if !colorHex.isEmpty, slotHex == colorHex {
                        return SpoolLocation(printerSerial: serial, feeder: group.isExternal ? .ext : .ams, amsIndex: gi, slot: si)
                    }
                }
            }
            return nil
        }
        func loadedLocation() -> SpoolLocation? {
            for (gi, group) in groups.enumerated() {
                if let si = group.slots.firstIndex(where: { $0.isActive }) ?? group.slots.firstIndex(where: { $0.isPresent }) {
                    return SpoolLocation(printerSerial: serial, feeder: group.isExternal ? .ext : .ams, amsIndex: gi, slot: si)
                }
            }
            return nil
        }
        for fil in filaments where fil.usedGrams > 0 {
            let target = location(colorHex: fil.colorHex) ?? (filaments.count == 1 ? loadedLocation() : nil)
            guard let loc = target, let spool = SpoolbaseShared.spools.spool(at: loc) else { continue }
            SpoolbaseShared.spools.consume(spoolID: spool.id, grams: fil.usedGrams,
                                           printerSerial: serial, printJobID: "\(job)#\(fil.id)")
        }
    }

    /// Klipper single-extruder: the whole print's measured length comes off the one loaded slot that
    /// carries an assigned physical spool.
    private static func consumeKlipper(printer: SavedPrinter, telemetry: PrinterTelemetry) {
        guard let usedMM = telemetry.filamentUsedMM, usedMM > 0 else { return }
        for (groupIndex, group) in telemetry.filamentGroups.enumerated() {
            guard let slotIndex = group.slots.firstIndex(where: { $0.isActive })
                    ?? group.slots.firstIndex(where: { $0.isPresent }) else { continue }
            let feeder: SpoolLocation.Feeder = group.isExternal ? .ext : .ams
            let location = SpoolLocation(printerSerial: printer.serial, feeder: feeder,
                                         amsIndex: groupIndex, slot: slotIndex)
            guard let spool = SpoolbaseShared.spools.spool(at: location) else { continue }
            let grams = grams(lengthMM: usedMM, material: group.slots[slotIndex].material)
            SpoolbaseShared.spools.consume(spoolID: spool.id, grams: grams,
                                           printerSerial: printer.serial,
                                           printJobID: jobID(serial: printer.serial, telemetry: telemetry))
            return   // single extruder: one decrement
        }
    }
}
