import Foundation

/// Parses PrusaLink's local HTTP API (`/api/v1/status`, plus `/api/v1/job` for the file name) into
/// PrinterTelemetry. PrusaLink is fully local (printer IP + API key), like Moonraker — no cloud.
enum PrusaLinkStatusParser {
    static func telemetry(status statusData: Data, job jobData: Data?, previous: PrinterTelemetry = .init()) -> PrinterTelemetry? {
        guard let root = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else { return nil }
        var telemetry = previous

        if let printer = root["printer"] as? [String: Any] {
            if let state = string(printer["state"]) { telemetry.state = mapState(state) }
            if let temp = number(printer["temp_nozzle"]) { telemetry.nozzleTemperature = temp }
            if let target = number(printer["target_nozzle"]) { telemetry.nozzleTargetTemperature = target }
            if let temp = number(printer["temp_bed"]) { telemetry.bedTemperature = temp }
            if let target = number(printer["target_bed"]) { telemetry.bedTargetTemperature = target }
        }

        if let job = root["job"] as? [String: Any] {
            if let progress = number(job["progress"]) {
                telemetry.progress = min(max(Int(progress.rounded()), 0), 100)
            }
            if let remaining = number(job["time_remaining"]), remaining > 0 {
                telemetry.remainingMinutes = Int((remaining / 60).rounded())
            }
        }

        // File name lives in /api/v1/job (best-effort; absent when idle).
        if let jobData,
           let jobRoot = try? JSONSerialization.jsonObject(with: jobData) as? [String: Any],
           let file = jobRoot["file"] as? [String: Any],
           let name = string(file["display_name"]) ?? string(file["name"]), !name.isEmpty {
            telemetry.jobName = (name as NSString).lastPathComponent
        }

        telemetry.lastUpdated = Date()
        return telemetry
    }

    static func mapState(_ raw: String) -> PrinterState {
        switch raw.uppercased() {
        case "PRINTING": .printing
        case "PAUSED": .paused
        case "FINISHED": .finished
        case "ERROR", "ATTENTION": .error
        case "STOPPED", "IDLE", "READY", "BUSY": .idle
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
