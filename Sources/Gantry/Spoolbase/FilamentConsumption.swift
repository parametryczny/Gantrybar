import Foundation

/// Which print a finished job belongs to.
///
/// The hour a FINISHED packet happened to arrive used to be the identity, so two short prints of one
/// file within an hour merged into one job, and a finished print seen again after a restart in a later
/// hour was subtracted a second time. A session starts when the printer is seen printing and ends when
/// it finishes; it is kept on disk, so a restart finds the same session and the same id.
struct PrintJobSessions: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        var job: String
        var id: String
        var finished: Bool
    }

    private(set) var sessions: [String: Session] = [:]

    /// Feeds one update. Returns the job id when this update is the finish to account for, nil otherwise.
    mutating func observe(serial: String, previous: PrinterState?, state: PrinterState,
                          jobName: String?, now: Date) -> String? {
        let job = jobName ?? "?"
        let id = "\(serial)|\(job)|\(Int(now.timeIntervalSince1970))"
        switch state {
        case .printing, .paused:
            if let current = sessions[serial], current.job == job, !current.finished { return nil }
            sessions[serial] = Session(job: job, id: id, finished: false)
            return nil
        case .finished:
            guard previous != .finished else { return nil }
            if var current = sessions[serial], current.job == job {
                current.finished = true
                sessions[serial] = current
                return current.id
            }
            // Finished before Gantry saw it print. One session for it, kept, so a restart reuses it.
            sessions[serial] = Session(job: job, id: id, finished: true)
            return id
        default:
            return nil
        }
    }
}

/// Turns a finished print into a spool decrement. The rule (spec §15-18): subtract on FINISH only,
/// never on start; cancelled/failed prints do not auto-subtract; every subtraction is idempotent per
/// print job so a reconnect or restart cannot double-count.
///
/// Source of the grams used differs per printer:
///  - Klipper/Moonraker: real measured `filament_used` (mm) converted to grams here.
///  - Bambu: the slicer's `used_g` read from the printed 3mf.
@MainActor
enum FilamentConsumption {
    private static let filamentDiameterMM = 1.75
    private static let sessionsKey = "spoolbase-print-sessions"
    private static var sessions: PrintJobSessions = {
        guard let data = BambuDefaults.shared.data(forKey: sessionsKey),
              let stored = try? JSONDecoder().decode(PrintJobSessions.self, from: data) else { return PrintJobSessions() }
        return stored
    }()

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

    /// Called on every telemetry update. Acts only on the finish of a print session.
    ///
    /// With Spoolbase switched off nothing is subtracted, and nothing is remembered as subtracted
    /// either: prints finished while the feature was off simply never happened as far as the rolls are
    /// concerned. Sessions are still followed, so a print that started before the switch was turned on
    /// has the right identity when it ends.
    static func onUpdate(printer: SavedPrinter, previous: PrinterTelemetry?, current: PrinterTelemetry) {
        let before = sessions
        let job = sessions.observe(serial: printer.serial, previous: previous?.state, state: current.state,
                                   jobName: current.jobName, now: Date())
        if sessions != before, let data = try? JSONEncoder().encode(sessions) {
            BambuDefaults.shared.set(data, forKey: sessionsKey)
        }
        guard let job, AppSettings.shared.spoolbaseEnabled else { return }
        switch printer.kind {
        case .klipper: consumeKlipper(printer: printer, telemetry: current, job: job)
        case .bambu: consumeBambu(printer: printer, telemetry: current, job: job)
        default: break   // no local grams source for other kinds yet.
        }
    }

    struct LoadedSlot {
        let location: SpoolLocation
        let slot: FilamentSlot
    }

    struct SpoolCharge: Equatable {
        let spoolID: String
        let grams: Double
        let filamentID: Int
    }

    static func slotLocation(serial: String, groups: [FilamentGroup], group: Int, slot: Int) -> SpoolLocation {
        SpoolLocation(printerSerial: serial, feeder: groups[group].isExternal ? .ext : .ams, amsIndex: group, slot: slot)
    }

    /// The slot a single-extruder print came from: the active one, wherever it is. With none active,
    /// only a lone loaded roll counts. Taking the first present slot charged whatever roll sat in A1
    /// while A2 was feeding, and the first unit's roll while the second unit was feeding.
    static func loadedSlot(serial: String, groups: [FilamentGroup], hasSpool: (SpoolLocation) -> Bool) -> LoadedSlot? {
        var active: [LoadedSlot] = []
        var loaded: [LoadedSlot] = []
        for (groupIndex, group) in groups.enumerated() {
            for (slotIndex, slot) in group.slots.enumerated() {
                let entry = LoadedSlot(location: slotLocation(serial: serial, groups: groups, group: groupIndex, slot: slotIndex),
                                       slot: slot)
                if slot.isActive { active.append(entry) }
                else if slot.isPresent, hasSpool(entry.location) { loaded.append(entry) }
            }
        }
        if !active.isEmpty { return active.count == 1 ? active[0] : nil }
        return loaded.count == 1 ? loaded[0] : nil
    }

    /// The roll assigned to every slot, read when the print finishes.
    static func assignedSpools(serial: String, groups: [FilamentGroup]) -> [SpoolLocation: String] {
        var assigned: [SpoolLocation: String] = [:]
        for (groupIndex, group) in groups.enumerated() {
            for slotIndex in group.slots.indices {
                let location = slotLocation(serial: serial, groups: groups, group: groupIndex, slot: slotIndex)
                if let spool = SpoolbaseShared.spools.spool(at: location) { assigned[location] = spool.id }
            }
        }
        return assigned
    }

    /// Maps each sliced filament to a slot by colour (a single filament falls back to the loaded slot)
    /// and to the roll that was assigned there when the print finished.
    static func bambuCharges(serial: String, groups: [FilamentGroup], filaments: [SlicedFilament],
                             assigned: [SpoolLocation: String]) -> [SpoolCharge] {
        func hex6(_ value: String?) -> String {
            String((value ?? "").replacingOccurrences(of: "#", with: "").uppercased().prefix(6))
        }
        // The slot a filament was printed from, by colour. Two slots of one colour are told apart by
        // material; still more than one means the job cannot say which roll it used, so nothing is
        // charged rather than the first match (two black rolls used to be charged as one).
        func location(for filament: SlicedFilament) -> SpoolLocation? {
            let wanted = hex6(filament.colorHex)
            guard !wanted.isEmpty else { return nil }
            var matches: [(location: SpoolLocation, material: String)] = []
            for (groupIndex, group) in groups.enumerated() {
                for (slotIndex, slot) in group.slots.enumerated() where hex6(slot.colorHex) == wanted {
                    matches.append((slotLocation(serial: serial, groups: groups, group: groupIndex, slot: slotIndex),
                                    (slot.material ?? "").uppercased()))
                }
            }
            if matches.count > 1, !filament.type.isEmpty {
                matches = matches.filter { $0.material == filament.type.uppercased() }
            }
            return matches.count == 1 ? matches[0].location : nil
        }
        var charges: [SpoolCharge] = []
        for filament in filaments where filament.usedGrams > 0 {
            let target = location(for: filament)
                ?? (filaments.count == 1
                    ? loadedSlot(serial: serial, groups: groups, hasSpool: { assigned[$0] != nil })?.location : nil)
            guard let target, let spoolID = assigned[target] else { continue }
            charges.append(SpoolCharge(spoolID: spoolID, grams: filament.usedGrams, filamentID: filament.id))
        }
        return charges
    }

    /// Bambu: fetch the printed `.gcode.3mf` over the printer's local FTPS, read the slicer's `used_g`
    /// per filament, map each filament to its AMS slot, and subtract from the roll assigned there.
    private static func consumeBambu(printer: SavedPrinter, telemetry: PrinterTelemetry, job: String) {
        guard let file = telemetry.gcodeFile, !file.isEmpty else { return }
        guard let code = try? AccessCodeStore.readAccessCode(for: printer.serial), !code.isEmpty else { return }
        let host = printer.host
        let serial = printer.serial
        let groups = telemetry.filamentGroups
        // The rolls are read now, at the finish. Looked up after the download, a roll swapped in while
        // the file was still coming over was charged for the print that had just come off the old one.
        let assigned = assignedSpools(serial: serial, groups: groups)
        guard !assigned.isEmpty else { return }
        Task {
            let client = BambuFileClient(host: host, accessCode: code)
            do {
                let data = try await client.fetch(fileName: file)
                let filaments = ThreeMFReader.filaments(fromData: data)
                await MainActor.run {
                    // Spoolbase switched off during the download: the print is not accounted.
                    guard AppSettings.shared.spoolbaseEnabled else { return }
                    for charge in bambuCharges(serial: serial, groups: groups, filaments: filaments, assigned: assigned) {
                        SpoolbaseShared.spools.consume(spoolID: charge.spoolID, grams: charge.grams,
                                                       printerSerial: serial, printJobID: "\(job)#\(charge.filamentID)")
                    }
                }
            } catch {
                NSLog("Spoolbase: nie udało się pobrać/odczytać 3mf dla %@ (%@): %@", serial, file, "\(error)")
            }
        }
    }

    /// Klipper single-extruder: the whole print's measured length comes off the roll in the slot the
    /// print came from.
    private static func consumeKlipper(printer: SavedPrinter, telemetry: PrinterTelemetry, job: String) {
        guard let usedMM = telemetry.filamentUsedMM, usedMM > 0 else { return }
        let spools = SpoolbaseShared.spools
        guard let loaded = loadedSlot(serial: printer.serial, groups: telemetry.filamentGroups,
                                      hasSpool: { spools.spool(at: $0) != nil }),
              let spool = spools.spool(at: loaded.location) else { return }
        spools.consume(spoolID: spool.id, grams: grams(lengthMM: usedMM, material: loaded.slot.material),
                       printerSerial: printer.serial, printJobID: job)
    }
}
