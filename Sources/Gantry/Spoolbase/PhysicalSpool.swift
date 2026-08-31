import Foundation

/// A concrete, physical roll of filament (as opposed to `Filament`, which describes the *product*).
/// The state (remaining grams, location) belongs to the spool, never to the AMS slot: an AMS slot only
/// tells us which spool is currently there. See design/writing-block spec (ETAP 1).
///
/// Field meanings are intentionally simple so the same JSON maps 1:1 onto the Windows (C#) and Linux
/// (Python) implementations.
struct PhysicalSpool: Codable, Identifiable, Hashable, Sendable {
    /// Short, human-friendly, immutable id, e.g. "SP-00001". Never encode brand/colour/type into it.
    var id: String
    /// References `Filament.id` (the product definition) in the existing Spoolbase.
    var filamentDefinitionID: UUID
    var nominalWeightGrams: Double
    var remainingWeightGrams: Double
    var status: SpoolStatus
    var location: SpoolLocation
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    // Optional lifecycle timestamps (spec §3), filled in as the spool is used.
    var openedAt: Date?
    var emptiedAt: Date?
    var lastUsedAt: Date?
    var totalConsumedGrams: Double
    // Manual weighing (spec §5): when the user last weighed the roll, and the tare of the empty spool
    // (so a gross reading can be turned into net filament). Both optional; nil until first weighed.
    var weighedAt: Date?
    var tareGrams: Double?

    init(
        id: String,
        filamentDefinitionID: UUID,
        nominalWeightGrams: Double = 1000,
        remainingWeightGrams: Double? = nil,
        status: SpoolStatus = .new,
        location: SpoolLocation = .storage,
        notes: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        openedAt: Date? = nil,
        emptiedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        totalConsumedGrams: Double = 0,
        weighedAt: Date? = nil,
        tareGrams: Double? = nil
    ) {
        self.id = id
        self.filamentDefinitionID = filamentDefinitionID
        self.nominalWeightGrams = max(0, nominalWeightGrams)
        self.remainingWeightGrams = max(0, remainingWeightGrams ?? nominalWeightGrams)
        self.status = status
        self.location = location
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.openedAt = openedAt
        self.emptiedAt = emptiedAt
        self.lastUsedAt = lastUsedAt
        self.totalConsumedGrams = totalConsumedGrams
        self.weighedAt = weighedAt
        self.tareGrams = tareGrams
    }

    /// Locally computed fill level (no RFID): remaining / nominal. Never pushed back to firmware.
    var percent: Int {
        guard nominalWeightGrams > 0 else { return 0 }
        return Int((remainingWeightGrams / nominalWeightGrams * 100).rounded())
    }
}

enum SpoolStatus: String, Codable, Sendable {
    case new
    case active
    case stored
    case empty
    case archived
}

/// Where a spool currently is. `printerSerial == nil` means it sits in storage. The location is a
/// property of the spool, general enough for AMS and the external feeder (EXT), and any printer.
struct SpoolLocation: Codable, Hashable, Sendable {
    enum Feeder: String, Codable, Sendable {
        case ams
        case ext
    }

    var printerSerial: String?   // nil == storage
    var feeder: Feeder?
    var amsIndex: Int?           // AMS unit index (0-based); nil for EXT
    var slot: Int?               // slot within the unit (0-based)

    init(printerSerial: String? = nil, feeder: Feeder? = nil, amsIndex: Int? = nil, slot: Int? = nil) {
        self.printerSerial = printerSerial
        self.feeder = feeder
        self.amsIndex = amsIndex
        self.slot = slot
    }

    static let storage = SpoolLocation()

    var isStorage: Bool { printerSerial == nil }

    /// True when this location points at the same physical slot as `other` (same printer/feeder/ams/slot).
    func sameSlot(as other: SpoolLocation) -> Bool {
        printerSerial == other.printerSerial && feeder == other.feeder
            && amsIndex == other.amsIndex && slot == other.slot && !isStorage
    }
}

/// One filament-consumption record, written once per finished print job (spec §16). Kept append-only so
/// history survives without ever reshaping the data model. Idempotency is enforced on `printJobID`.
struct SpoolUsageEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var spoolID: String
    var printerSerial: String
    var printJobID: String
    var consumedGrams: Double
    var timestamp: Date

    init(id: UUID = UUID(), spoolID: String, printerSerial: String, printJobID: String,
         consumedGrams: Double, timestamp: Date = .now) {
        self.id = id
        self.spoolID = spoolID
        self.printerSerial = printerSerial
        self.printJobID = printJobID
        self.consumedGrams = consumedGrams
        self.timestamp = timestamp
    }
}
