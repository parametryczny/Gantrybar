import Foundation

/// A tiny rolling log of finished prints (printer + job + time), for the Telegram bot's `/history`.
/// Deliberately minimal and self-contained — persisted as JSON in UserDefaults, capped to the last 30 —
/// so the same idea ports to Windows/Linux without a new data model.
enum PrintHistory {
    struct Entry: Codable, Sendable {
        let serial: String
        let printer: String
        let job: String
        let date: Date
    }

    private static let key = "print-history-v1"
    private static let cap = 30

    static func record(serial: String, printer: String, job: String) {
        var entries = all()
        entries.append(Entry(serial: serial, printer: printer, job: job, date: Date()))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        if let data = try? JSONEncoder().encode(entries) {
            BambuDefaults.shared.set(data, forKey: key)
        }
    }

    static func recent(_ count: Int = 10) -> [Entry] {
        Array(all().suffix(count).reversed())
    }

    private static func all() -> [Entry] {
        guard let data = BambuDefaults.shared.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }
}
