import Foundation

enum CatalogFile {
    static var filaments: [CatalogFilament] {
        if let data = try? Data(contentsOf: editableURL),
           let items = try? JSONDecoder().decode([CatalogFilament].self, from: data) {
            return removingRetiredFactoryItems(from: items)
        }
        if let data = try? Data(contentsOf: legacyEditableURL),
           let items = try? JSONDecoder().decode([CatalogFilament].self, from: data) {
            return removingRetiredFactoryItems(from: items)
        }
        return bundledFilaments
    }

    static func save(_ filaments: [CatalogFilament]) throws {
        try FileManager.default.createDirectory(at: editableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(filaments).write(to: editableURL, options: .atomic)
    }

    static var factoryFilaments: [CatalogFilament] { bundledFilaments }

    static var editableURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spoolbase", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    private static var legacyEditableURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilamentStock", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    private static func removingRetiredFactoryItems(from items: [CatalogFilament]) -> [CatalogFilament] {
        items.filter { item in
            if item.id.hasPrefix("custom-") { return true }
            if item.type.caseInsensitiveCompare("ABS") == .orderedSame { return false }
            if item.brand.caseInsensitiveCompare("Creality") == .orderedSame { return false }
            return true
        }
    }

    private static let bundledFilaments: [CatalogFilament] = {
        // Ships inside the Gantry app bundle (Contents/Resources), copied there by build-app.sh; the
        // .build/debug fallback keeps `swift run` / --self-test working from the build directory.
        let url = Bundle.main.url(forResource: "filament-catalog", withExtension: "json")
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("filament-catalog.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([CatalogFilament].self, from: data) else {
            return []
        }
        return items
    }()
}
