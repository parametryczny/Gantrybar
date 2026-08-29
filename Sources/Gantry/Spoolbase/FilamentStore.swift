import Foundation

@MainActor
final class FilamentStore {
    private(set) var filaments: [Filament]
    private let storageURL: URL
    var onChange: (() -> Void)?

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        let readURL: URL
        if storageURL == nil,
           !FileManager.default.fileExists(atPath: self.storageURL.path),
           FileManager.default.fileExists(atPath: Self.legacyStorageURL.path) {
            readURL = Self.legacyStorageURL
        } else {
            readURL = self.storageURL
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: readURL),
           let saved = try? decoder.decode([Filament].self, from: data) {
            filaments = saved
            if readURL != self.storageURL { save() }
        } else {
            filaments = []
            save()
        }
    }

    func add(_ filament: Filament) {
        if let catalogID = filament.catalogID,
           let index = filaments.firstIndex(where: { $0.catalogID == catalogID }) {
            filaments[index].spoolCount += max(1, filament.spoolCount)
            filaments[index].updatedAt = .now
            changed()
            return
        }
        filaments.append(filament)
        changed()
    }

    func update(_ filament: Filament) {
        guard let index = filaments.firstIndex(where: { $0.id == filament.id }) else { return }
        filaments[index] = filament
        changed()
    }

    /// Merges a peer's catalog (LAN sync): reconcile by `updatedAt`, add unseen definitions.
    @discardableResult
    func mergeRemote(_ remote: [Filament]) -> Bool {
        var didChange = false
        for item in remote {
            if let index = filaments.firstIndex(where: { $0.id == item.id }) {
                if item.updatedAt > filaments[index].updatedAt { filaments[index] = item; didChange = true }
            } else {
                filaments.append(item); didChange = true
            }
        }
        if didChange { changed() }
        return didChange
    }

    func delete(id: UUID) {
        filaments.removeAll { $0.id == id }
        changed()
    }

    func adjust(id: UUID, spools: Int) {
        guard let index = filaments.firstIndex(where: { $0.id == id }) else { return }
        filaments[index].spoolCount = max(0, filaments[index].spoolCount + spools)
        filaments[index].updatedAt = .now
        changed()
    }

    func move(id sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = filaments.firstIndex(where: { $0.id == sourceID }),
              let targetItem = filaments.first(where: { $0.id == targetID }),
              filaments[sourceIndex].type == targetItem.type else { return }
        let source = filaments.remove(at: sourceIndex)
        guard let targetIndex = filaments.firstIndex(where: { $0.id == targetID }) else { return }
        filaments.insert(source, at: targetIndex)
        changed()
    }

    private func changed() {
        save()
        onChange?()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(filaments).write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Nie można zapisać bazy filamentów: %@", error.localizedDescription)
        }
    }

    static var defaultStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spoolbase", isDirectory: true)
            .appendingPathComponent("inventory-v2.json")
    }

    private static var legacyStorageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FilamentStock", isDirectory: true)
            .appendingPathComponent("inventory-v2.json")
    }
}
