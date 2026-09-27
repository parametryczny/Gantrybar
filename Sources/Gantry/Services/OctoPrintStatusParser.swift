import Foundation

/// Parses OctoPrint's REST API (`/api/printer` for state and temperatures, `/api/job` for the file and
/// progress) into PrinterTelemetry. Local only: host plus an application or global API key.
enum OctoPrintStatusParser {
    /// `printer` is nil when OctoPrint answered 409: it runs, but no printer is connected to it.
    static func telemetry(printer printerData: Data?, job jobData: Data?, previous: PrinterTelemetry = .init()) -> PrinterTelemetry {
        var telemetry = previous
        telemetry.lastUpdated = Date()
        guard let printerData,
              let root = try? JSONSerialization.jsonObject(with: printerData) as? [String: Any] else {
            telemetry.state = .offline
            return telemetry
        }
        let flags = ((root["state"] as? [String: Any])?["flags"] as? [String: Any]) ?? [:]
        func flag(_ name: String) -> Bool { (flags[name] as? NSNumber)?.boolValue ?? false }

        if let temperature = root["temperature"] as? [String: Any] {
            func reading(_ key: String) -> (Double?, Double?) {
                let entry = temperature[key] as? [String: Any]
                return (number(entry?["actual"]), number(entry?["target"]))
            }
            (telemetry.nozzleTemperature, telemetry.nozzleTargetTemperature) = reading("tool0")
            (telemetry.bedTemperature, telemetry.bedTargetTemperature) = reading("bed")
            let chamber = reading("chamber")
            telemetry.chamberTemperature = chamber.0
            telemetry.chamberTargetTemperature = chamber.1
        }

        var progress: Double?
        var fileName: String?
        if let jobData, let jobRoot = try? JSONSerialization.jsonObject(with: jobData) as? [String: Any] {
            let file = (jobRoot["job"] as? [String: Any])?["file"] as? [String: Any]
            fileName = (file?["display"] as? String) ?? (file?["name"] as? String)
            let progressEntry = jobRoot["progress"] as? [String: Any]
            progress = number(progressEntry?["completion"])
            if let left = number(progressEntry?["printTimeLeft"]), left > 0 {
                telemetry.remainingMinutes = Int((left / 60).rounded())
            } else {
                telemetry.remainingMinutes = nil
            }
        }
        if let fileName, !fileName.isEmpty { telemetry.jobName = (fileName as NSString).lastPathComponent }
        if let progress { telemetry.progress = min(max(Int(progress.rounded(.down)), 0), 100) }

        telemetry.state = mapState(flags: flag, progress: progress, hasFile: fileName?.isEmpty == false)
        if telemetry.state != .printing && telemetry.state != .paused { telemetry.remainingMinutes = nil }
        return telemetry
    }

    static func mapState(flags flag: (String) -> Bool, progress: Double?, hasFile: Bool) -> PrinterState {
        if flag("error") || flag("closedOrError") && !flag("operational") { return .error }
        if flag("paused") || flag("pausing") { return .paused }
        if flag("printing") { return .printing }
        if flag("cancelling") { return .idle }
        // OctoPrint has no "finished" state: the job stays loaded at 100 % until the next one.
        if hasFile, let progress, progress >= 100 { return .finished }
        if flag("operational") || flag("ready") { return .idle }
        return .offline
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
