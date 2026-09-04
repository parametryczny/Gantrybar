import Foundation

/// Shared Spoolbase stores so the inventory window, the dashboard AMS popover and (later) the
/// consumption tracker all read/write one source of truth.
@MainActor
enum SpoolbaseShared {
    static let filaments = FilamentStore()
    static let spools = PhysicalSpoolStore()
}

/// Persistent store for physical spools and their consumption history. Mirrors `FilamentStore`'s
/// JSON-in-Application-Support pattern so the two live side by side. All mutations save immediately;
/// nothing critical is kept only in memory (spec §24).
@MainActor
final class PhysicalSpoolStore {
    private(set) var spools: [PhysicalSpool]
    private(set) var usageEvents: [SpoolUsageEvent]
    private let spoolsURL: URL
    private let usageURL: URL
    var onChange: (() -> Void)?

    init(spoolsURL: URL? = nil, usageURL: URL? = nil) {
        self.spoolsURL = spoolsURL ?? Self.defaultSpoolsURL
        self.usageURL = usageURL ?? Self.defaultUsageURL
        spools = Self.load([PhysicalSpool].self, from: self.spoolsURL) ?? []
        usageEvents = Self.load([SpoolUsageEvent].self, from: self.usageURL) ?? []
    }

    // MARK: Lookup

    func spool(id: String) -> PhysicalSpool? { spools.first { $0.id == id } }

    /// The spool currently sitting in a given physical slot (or nil if that slot is empty).
    func spool(at location: SpoolLocation) -> PhysicalSpool? {
        guard !location.isStorage else { return nil }
        return spools.first { $0.location.sameSlot(as: location) }
    }

    func spools(forDefinition definitionID: UUID) -> [PhysicalSpool] {
        spools.filter { $0.filamentDefinitionID == definitionID }
    }

    /// Next free short id like "SP-00001" (one past the highest existing number).
    func nextSpoolID() -> String {
        let maxNumber = spools.compactMap { spool -> Int? in
            guard spool.id.hasPrefix("SP-") else { return nil }
            return Int(spool.id.dropFirst(3))
        }.max() ?? 0
        return String(format: "SP-%05d", maxNumber + 1)
    }

    // MARK: Mutations

    func add(_ spool: PhysicalSpool) {
        spools.append(spool)
        changed()
    }

    /// Creates `count` fresh rolls of one filament definition, each with its own id, dropped straight
    /// into storage (spec §1: adding a filament to Spoolbase creates one physical roll per spool). A
    /// full roll has remaining == nominal == `weight`; an opened roll passes a smaller `remaining`.
    @discardableResult
    func createRolls(definitionID: UUID, count: Int, weight: Double, remaining: Double? = nil) -> [PhysicalSpool] {
        var created: [PhysicalSpool] = []
        for _ in 0..<max(0, count) {
            let rest = remaining ?? weight
            let spool = PhysicalSpool(id: nextSpoolID(), filamentDefinitionID: definitionID,
                                      nominalWeightGrams: weight, remainingWeightGrams: rest,
                                      status: rest < weight ? .active : .new, location: .storage,
                                      openedAt: rest < weight ? .now : nil)
            spools.append(spool)
            created.append(spool)
        }
        if !created.isEmpty { changed() }
        return created
    }

    func update(_ spool: PhysicalSpool) {
        guard let index = spools.firstIndex(where: { $0.id == spool.id }) else { return }
        var updated = spool
        updated.updatedAt = .now
        spools[index] = updated
        changed()
    }

    func delete(id: String) {
        spools.removeAll { $0.id == id }
        changed()
    }

    /// Manual correction of the remaining amount (spec §12: "Ustaw pozostałą ilość").
    func setRemaining(id: String, grams: Double) {
        guard let index = spools.firstIndex(where: { $0.id == id }) else { return }
        spools[index].remainingWeightGrams = max(0, min(grams, spools[index].nominalWeightGrams))
        spools[index].status = spools[index].remainingWeightGrams <= 0 ? .empty : spools[index].status
        spools[index].updatedAt = .now
        changed()
    }

    /// Manual weighing (spec §5 "Skoryguj wagę"): store a freshly measured net amount and stamp the
    /// weighing date. `tare` (empty-spool weight) is remembered so a later gross reading can be
    /// converted to net automatically. `grams` here is already net (gross minus tare).
    func correctWeight(id: String, netGrams: Double, tare: Double? = nil) {
        guard let index = spools.firstIndex(where: { $0.id == id }) else { return }
        spools[index].remainingWeightGrams = max(0, min(netGrams, spools[index].nominalWeightGrams))
        if let tare { spools[index].tareGrams = tare }
        spools[index].weighedAt = .now
        if spools[index].remainingWeightGrams <= 0 {
            spools[index].status = .empty
            spools[index].emptiedAt = .now
        } else if spools[index].status == .empty {
            spools[index].status = spools[index].location.isStorage ? .stored : .active
        }
        spools[index].updatedAt = .now
        changed()
    }

    /// Reset a roll back to a full nominal amount (spec §6): used when a spent roll is swapped for a
    /// fresh one of the same product without minting a new id. Clears consumption/lifecycle so the
    /// history starts over for the new physical roll. Pass `nominal` to also change the roll size.
    func resetToFull(id: String, nominal: Double? = nil) {
        guard let index = spools.firstIndex(where: { $0.id == id }) else { return }
        let full = max(0, nominal ?? spools[index].nominalWeightGrams)
        spools[index].nominalWeightGrams = full
        spools[index].remainingWeightGrams = full
        spools[index].totalConsumedGrams = 0
        spools[index].openedAt = nil
        spools[index].emptiedAt = nil
        spools[index].weighedAt = nil
        spools[index].status = spools[index].location.isStorage ? .new : .active
        spools[index].updatedAt = .now
        changed()
    }

    /// Assigns a spool to a slot, moving it there and freeing whatever slot it (or the target) held.
    /// A spool can only be in one place at a time (spec §6); the target slot can hold only one spool.
    func assign(spoolID: String, to location: SpoolLocation) {
        guard let index = spools.firstIndex(where: { $0.id == spoolID }) else { return }
        // Any *other* spool currently in the target slot is bumped back to storage.
        if !location.isStorage {
            for i in spools.indices where i != index && spools[i].location.sameSlot(as: location) {
                spools[i].location = .storage
                spools[i].status = spools[i].status == .empty ? .empty : .stored
                spools[i].updatedAt = .now
            }
        }
        spools[index].location = location
        if !location.isStorage {
            spools[index].status = spools[index].remainingWeightGrams <= 0 ? .empty : .active
            if spools[index].openedAt == nil { spools[index].openedAt = .now }
        } else if spools[index].status == .active {
            spools[index].status = .stored
        }
        spools[index].updatedAt = .now
        changed()
    }

    /// Removes whatever spool sits in a slot, sending it back to storage.
    func clearSlot(_ location: SpoolLocation) {
        guard let spool = spool(at: location) else { return }
        assign(spoolID: spool.id, to: .storage)
    }

    /// When a real RFID/NFC spool is newly inserted into a slot that still holds a manually-assigned
    /// Spoolbase spool, the assignment is stale (that physical roll was taken out) — send the assigned
    /// spool back to storage so the slot shows the inserted NFC roll's own data. Only fires on the
    /// insert transition (the slot gains an NFC reading), so a deliberate later assignment is left alone.
    /// Returns a short description of each detached spool (id + slot label), so the UI can tell the user.
    @discardableResult
    func detachAssignmentsReplacedByNFC(printerSerial: String, previous: [FilamentGroup], current: [FilamentGroup]) -> [(spoolID: String, slot: String)] {
        var detached: [(spoolID: String, slot: String)] = []
        for (gi, group) in current.enumerated() {
            for (si, slot) in group.slots.enumerated() where slot.remainingWeightGrams != nil {
                let hadNFC = previous.indices.contains(gi)
                    && previous[gi].slots.indices.contains(si)
                    && previous[gi].slots[si].remainingWeightGrams != nil
                guard !hadNFC else { continue }
                let location = SpoolLocation(printerSerial: printerSerial,
                                             feeder: group.isExternal ? .ext : .ams, amsIndex: gi, slot: si)
                if let assigned = spool(at: location) {
                    let slotLabel = group.isExternal ? group.displayName : "\(group.displayName) \(slot.label)"
                    clearSlot(location)
                    detached.append((assigned.id, slotLabel))
                }
            }
        }
        return detached
    }

    // MARK: Consumption (ETAP 4 — idempotent per print job)

    /// Subtracts filament for a finished job. Idempotent: a job id already recorded is ignored, so a
    /// reconnect / restart / re-delivered event never double-subtracts (spec §17). Returns false when
    /// the job was already applied (or the spool is unknown).
    @discardableResult
    func consume(spoolID: String, grams: Double, printerSerial: String, printJobID: String) -> Bool {
        guard grams > 0 else { return false }
        guard !usageEvents.contains(where: { $0.printJobID == printJobID && $0.spoolID == spoolID }) else { return false }
        guard let index = spools.firstIndex(where: { $0.id == spoolID }) else { return false }
        spools[index].remainingWeightGrams = max(0, spools[index].remainingWeightGrams - grams)
        spools[index].totalConsumedGrams += grams
        spools[index].lastUsedAt = .now
        spools[index].updatedAt = .now
        if spools[index].remainingWeightGrams <= 0 {
            spools[index].status = .empty
            spools[index].emptiedAt = .now
        }
        usageEvents.append(SpoolUsageEvent(spoolID: spoolID, printerSerial: printerSerial,
                                           printJobID: printJobID, consumedGrams: grams))
        saveUsage()
        changed()
        return true
    }

    // MARK: Persistence

    private func changed() {
        save()
        onChange?()
    }

    private func save() { Self.write(spools, to: spoolsURL) }
    private func saveUsage() { Self.write(usageEvents, to: usageURL) }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Nie można zapisać rolek Spoolbase: %@", error.localizedDescription)
        }
    }

    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spoolbase", isDirectory: true)
    }
    static var defaultSpoolsURL: URL { baseDirectory.appendingPathComponent("spools-v1.json") }
    static var defaultUsageURL: URL { baseDirectory.appendingPathComponent("usage-v1.json") }
}
