import Foundation

/// Parses Snapmaker's local HTTP API `/api/v1/status` (port 8080) into PrinterTelemetry. Field names
/// follow Luban's HTTP server; every field is read defensively so a missing key just leaves the
/// previous value untouched.
enum SnapmakerStatusParser {
    static func telemetry(status statusData: Data, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else { return nil }
        var telemetry = previous

        if let state = string(root["status"]) ?? string(root["printStatus"]) {
            telemetry.state = mapState(state)
        }
        if let temp = number(root["nozzleTemperature"]) { telemetry.nozzleTemperature = temp }
        if let target = number(root["nozzleTargetTemperature"]) { telemetry.nozzleTargetTemperature = target }
        if let temp = number(root["heatedBedTemperature"]) { telemetry.bedTemperature = temp }
        if let target = number(root["heatedBedTargetTemperature"]) { telemetry.bedTargetTemperature = target }

        if let progress = number(root["progress"]) {
            // Luban reports a 0…1 fraction; some firmware sends 0…100. Handle both.
            let percent = progress <= 1.0 ? progress * 100 : progress
            telemetry.progress = min(max(Int(percent.rounded()), 0), 100)
        }
        if let remaining = number(root["remainingTime"]), remaining > 0 {
            telemetry.remainingMinutes = Int((remaining / 60).rounded())
        }
        if let name = string(root["fileName"]), !name.isEmpty {
            telemetry.jobName = (name as NSString).lastPathComponent
        }

        telemetry.lastUpdated = Date()
        return telemetry
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.uppercased() {
        case "RUNNING", "PRINTING": .printing
        case "PAUSED", "PAUSING": .paused
        case "IDLE", "READY": .idle
        case "STOPPED", "COMPLETED", "FINISHED": .finished
        case "ERROR": .error
        default: .idle
        }
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
