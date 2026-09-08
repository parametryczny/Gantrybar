import Foundation

/// One launch, shared by the popover and floating dashboard. Reconnects never restart the gate.
struct StartupConnectionProgress {
    static let timeout: TimeInterval = 15
    private(set) var pendingSerials: Set<String>
    private(set) var readySerials: Set<String> = []
    private(set) var isLoading: Bool

    init(serials: [String]) {
        pendingSerials = Set(serials)
        isLoading = !serials.isEmpty
    }

    var total: Int { pendingSerials.count }
    var ready: Int { readySerials.count }
    var required: Int { (total * 3 + 4) / 5 } // ceil(60%), including small fleets

    mutating func receivedTelemetry(from serial: String) {
        guard isLoading, pendingSerials.contains(serial) else { return }
        readySerials.insert(serial)
        if ready >= required { finish() }
    }

    mutating func remove(_ serial: String) {
        pendingSerials.remove(serial)
        readySerials.remove(serial)
        if ready >= required { finish() }
    }

    mutating func finish() { isLoading = false }
}
