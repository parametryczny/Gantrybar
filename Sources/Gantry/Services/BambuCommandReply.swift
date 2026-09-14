import Foundation

/// A Bambu printer's answer to one of Gantry's control commands (a G-code line, a speed mode): which
/// command, whether the printer took it, and its reason when it did not. Without this a refused
/// command only showed as the setpoint quietly returning to the old value.
struct BambuCommandReply: Equatable, Sendable {
    static let controlCommands: Set<String> = ["gcode_line", "print_speed"]

    let command: String
    let accepted: Bool
    let reason: String?

    /// Nil for anything that is not a reply to a control command, telemetry included.
    static func parse(_ data: Data) -> BambuCommandReply? {
        // Telemetry arrives several times a second and never carries a result; skip the JSON parse.
        guard data.range(of: Data(#""result""#.utf8)) != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["print", "system"] {
            guard let body = root[key] as? [String: Any],
                  let command = body["command"] as? String, controlCommands.contains(command),
                  let result = body["result"] as? String else { continue }
            let accepted = ["success", "ok"].contains(result.lowercased())
            let reason = (body["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return BambuCommandReply(command: command, accepted: accepted, reason: accepted ? nil : reason ?? result)
        }
        return nil
    }
}
