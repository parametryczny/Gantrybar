import Foundation

/// Local, vendor-neutral print history and maintenance counters. Printer firmware does not expose a
/// stable maintenance schedule across Bambu/Elegoo/Klipper/Prusa, so Gantry counts actual printing
/// time and lets each printer override the default intervals. HMS errors remain live printer alerts.
@MainActor
final class PrinterInsightsStore {
    static let shared = PrinterInsightsStore()
    static let didChange = Notification.Name("GantryPrinterInsightsDidChange")

    enum Result: String, Codable { case completed, failed, cancelled }
    enum Signal: Equatable { case none, planned, due(Int), urgent(Int) }

    struct HistoryEntry: Codable, Identifiable {
        let id: UUID
        let job: String
        let startedAt: Date
        let endedAt: Date
        let result: Result
        let durationSeconds: Double
    }

    struct TaskState: Codable {
        var intervalHours: Double
        var completedAtPrintHours: Double
        var snoozedUntil: Date?
    }

    struct PrinterRecord: Codable {
        var totalPrintSeconds: Double = 0
        var activeStartedAt: Date?
        var activeJob: String?
        var history: [HistoryEntry] = []
        var tasks: [String: TaskState] = [:]
    }

    struct TaskStatus: Identifiable {
        let id: String
        let title: String
        let intervalHours: Double
        let remainingHours: Double
        let overdueHours: Double
        let isDue: Bool
        let isUrgent: Bool
        let snoozedUntil: Date?
    }

    struct Snapshot {
        let totalPrintHours: Double
        let history: [HistoryEntry]
        let tasks: [TaskStatus]
        let consumedGrams: Double

        var completedCount: Int { history.filter { $0.result == .completed }.count }
        var unsuccessfulCount: Int { history.filter { $0.result != .completed }.count }
        var successPercent: Int? {
            guard !history.isEmpty else { return nil }
            return Int((Double(completedCount) / Double(history.count) * 100).rounded())
        }
    }

    struct TaskDefinition {
        let id: String
        let polish: String
        let english: String
        let defaultHours: Double
    }

    static let definitions: [TaskDefinition] = [
        .init(id: "clean-rods", polish: "Czyszczenie prowadnic", english: "Clean guide rods", defaultHours: 100),
        .init(id: "lubricate-axes", polish: "Smarowanie osi", english: "Lubricate axes", defaultHours: 200),
        .init(id: "inspect-belts", polish: "Kontrola pasków", english: "Inspect belts", defaultHours: 300),
        .init(id: "inspect-nozzle", polish: "Kontrola dyszy", english: "Inspect nozzle", defaultHours: 500)
    ]

    private let key = "printer-insights-v1"
    private var records: [String: PrinterRecord]
    private var lastPersistedAt = Date.distantPast

    private init() {
        if let data = BambuDefaults.shared.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: PrinterRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func observe(printer: SavedPrinter, previous: PrinterTelemetry?, current: PrinterTelemetry) {
        var record = records[printer.serial] ?? PrinterRecord()
        let now = current.lastUpdated ?? Date()
        let wasActive = previous?.state == .printing || previous?.state == .paused
        let isActive = current.state == .printing || current.state == .paused

        if isActive, record.activeStartedAt == nil {
            record.activeStartedAt = now
            record.activeJob = current.jobName
        }
        if current.state == .printing, let last = previous?.lastUpdated {
            // Protect the counter from a stale timestamp after sleep/reconnect; long sessions are
            // finalized from activeStartedAt when the print ends.
            let delta = max(0, min(now.timeIntervalSince(last), 120))
            record.totalPrintSeconds += delta
        }

        var result: Result?
        if current.state == .finished, previous?.state != .finished,
           wasActive || record.activeStartedAt != nil { result = .completed }
        else if wasActive, current.state == .error { result = .failed }
        else if wasActive, current.state == .idle, (previous?.progress ?? 0) > 0, (previous?.progress ?? 0) < 100 {
            result = .cancelled
        }
        if let result {
            let start = record.activeStartedAt ?? now
            let duration = max(0, now.timeIntervalSince(start))
            let job = current.jobName ?? previous?.jobName ?? record.activeJob ?? ""
            // One terminal transition may be repeated by partial telemetry; keep it idempotent.
            let duplicate = record.history.last.map {
                $0.result == result && $0.job == job && abs($0.endedAt.timeIntervalSince(now)) < 30
            } ?? false
            if !duplicate {
                record.history.append(.init(id: UUID(), job: job, startedAt: start, endedAt: now,
                                            result: result, durationSeconds: duration))
                if record.history.count > 100 { record.history.removeFirst(record.history.count - 100) }
            }
            record.activeStartedAt = nil
            record.activeJob = nil
        } else if !isActive, current.state != .offline, !wasActive {
            record.activeStartedAt = nil
            record.activeJob = nil
        }

        records[printer.serial] = record
        save(notify: result != nil, force: result != nil)
    }

    func snapshot(serial: String, polish: Bool) -> Snapshot {
        let record = records[serial] ?? PrinterRecord()
        let hours = record.totalPrintSeconds / 3600
        let tasks = Self.definitions.map { definition -> TaskStatus in
            let state = record.tasks[definition.id]
                ?? TaskState(intervalHours: definition.defaultHours, completedAtPrintHours: 0, snoozedUntil: nil)
            let remaining = state.completedAtPrintHours + state.intervalHours - hours
            let snoozed = state.snoozedUntil.map { $0 > Date() } ?? false
            let due = remaining <= 0 && !snoozed
            let overdue = max(0, -remaining)
            let urgent = due && overdue >= max(24, state.intervalHours * 0.15)
            return TaskStatus(id: definition.id, title: polish ? definition.polish : definition.english,
                              intervalHours: state.intervalHours, remainingHours: max(0, remaining),
                              overdueHours: overdue, isDue: due, isUrgent: urgent,
                              snoozedUntil: state.snoozedUntil)
        }
        let grams = SpoolbaseShared.spools.usageEvents
            .filter { $0.printerSerial == serial }
            .reduce(0) { $0 + $1.consumedGrams }
        return Snapshot(totalPrintHours: hours, history: Array(record.history.reversed()),
                        tasks: tasks, consumedGrams: grams)
    }

    func signal(serial: String, hmsCodes: [String]) -> Signal {
        let tasks = snapshot(serial: serial, polish: true).tasks
        let urgent = tasks.filter(\.isUrgent).count + (hmsCodes.isEmpty ? 0 : 1)
        if urgent > 0 { return .urgent(urgent) }
        let due = tasks.filter(\.isDue).count
        if due > 0 { return .due(due) }
        let now = Date()
        let planned = tasks.contains {
            !$0.isDue && !($0.snoozedUntil.map { $0 > now } ?? false)
                && $0.remainingHours <= max(24, $0.intervalHours * 0.1)
        }
        return planned ? .planned : .none
    }

    func complete(serial: String, taskID: String) {
        var record = records[serial] ?? PrinterRecord()
        let definition = Self.definitions.first { $0.id == taskID }
        var state = record.tasks[taskID]
            ?? TaskState(intervalHours: definition?.defaultHours ?? 200, completedAtPrintHours: 0, snoozedUntil: nil)
        state.completedAtPrintHours = record.totalPrintSeconds / 3600
        state.snoozedUntil = nil
        record.tasks[taskID] = state
        records[serial] = record
        save(notify: true, force: true)
    }

    func snooze(serial: String, taskID: String, days: Int = 7) {
        var record = records[serial] ?? PrinterRecord()
        let definition = Self.definitions.first { $0.id == taskID }
        var state = record.tasks[taskID]
            ?? TaskState(intervalHours: definition?.defaultHours ?? 200, completedAtPrintHours: 0, snoozedUntil: nil)
        state.snoozedUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
        record.tasks[taskID] = state
        records[serial] = record
        save(notify: true, force: true)
    }

    func setInterval(serial: String, taskID: String, hours: Double) {
        guard hours >= 1 else { return }
        var record = records[serial] ?? PrinterRecord()
        let definition = Self.definitions.first { $0.id == taskID }
        var state = record.tasks[taskID]
            ?? TaskState(intervalHours: definition?.defaultHours ?? hours, completedAtPrintHours: 0, snoozedUntil: nil)
        state.intervalHours = hours
        record.tasks[taskID] = state
        records[serial] = record
        save(notify: true, force: true)
    }

    private func save(notify: Bool, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(lastPersistedAt) >= 60 {
            if let data = try? JSONEncoder().encode(records) { BambuDefaults.shared.set(data, forKey: key) }
            lastPersistedAt = now
        }
        if notify { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
