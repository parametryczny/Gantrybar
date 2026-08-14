import AppKit
import Foundation

struct Filament: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var catalogID: String?
    var brand: String
    var name: String
    var type: String
    var colorName: String
    var colorHex: String
    var manufacturerCode: String
    var spoolCount: Int
    var notes: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        catalogID: String? = nil,
        brand: String,
        name: String,
        type: String,
        colorName: String,
        colorHex: String,
        manufacturerCode: String = "",
        spoolCount: Int = 0,
        notes: String = "",
        updatedAt: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID
        self.brand = brand
        self.name = name
        self.type = type
        self.colorName = colorName
        self.colorHex = Self.normalizedHex(colorHex)
        self.manufacturerCode = manufacturerCode
        self.spoolCount = max(0, spoolCount)
        self.notes = notes
        self.updatedAt = updatedAt
    }

    var isInStock: Bool { spoolCount > 0 }

    var stockDescription: String {
        if spoolCount == 0 { return "brak" }
        return "\(spoolCount) szp."
    }

    static func normalizedHex(_ value: String) -> String {
        let filtered = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard filtered.count == 6, filtered.allSatisfy({ $0.isHexDigit }) else { return "8E8E93" }
        return filtered
    }
}

struct CatalogFilament: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let brand: String
    let name: String
    let type: String
    let colorName: String
    let colorHex: String
    let manufacturerCode: String

    func inventoryItem(spoolCount: Int = 1) -> Filament {
        Filament(
            catalogID: id,
            brand: brand,
            name: name,
            type: type,
            colorName: colorName,
            colorHex: colorHex,
            manufacturerCode: manufacturerCode,
            spoolCount: spoolCount
        )
    }
}

extension NSColor {
    convenience init(filamentHex hex: String) {
        let clean = Filament.normalizedHex(hex)
        let value = Int(clean, radix: 16) ?? 0x8E8E93
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var filamentHex: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "8E8E93" }
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

enum FilamentCatalog {
    static let brands = ["Bambu Lab", "Creality", "eSUN", "Fiberlogy", "Overture", "Polymaker", "Prusament", "ROSA 3D", "SUNLU"]
    static let types = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "ESD", "PVA", "Support"]
}
