import Foundation

struct PrinterPersistence {
    private let key = "saved-printers-v1"
    private let defaults = BambuDefaults.shared

    func load() -> [SavedPrinter] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedPrinter].self, from: data)) ?? []
    }

    func save(_ printers: [SavedPrinter]) {
        guard let data = try? JSONEncoder().encode(printers) else { return }
        defaults.set(data, forKey: key)
    }
}
