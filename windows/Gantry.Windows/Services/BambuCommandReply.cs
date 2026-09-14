using System.Text.Json;

namespace Gantry.Services;

/// <summary>A Bambu printer's answer to one of Gantry's control commands (a G-code line, a speed
/// mode): which command, whether the printer took it, and its reason when it did not. Without this a
/// refused command only showed as the setpoint quietly returning to the old value. Mirrors macOS
/// BambuCommandReply.</summary>
public sealed record BambuCommandReply(string Command, bool Accepted, string? Reason)
{
    private static readonly HashSet<string> ControlCommands = new() { "gcode_line", "print_speed" };

    /// <summary>Null for anything that is not a reply to a control command, telemetry included.</summary>
    public static BambuCommandReply? Parse(byte[] data)
    {
        // Telemetry arrives several times a second and never carries a result; skip the JSON parse.
        if (data.AsSpan().IndexOf("\"result\""u8) < 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            foreach (var key in new[] { "print", "system" })
            {
                if (!doc.RootElement.TryGetProperty(key, out var body) || body.ValueKind != JsonValueKind.Object) continue;
                if (!body.TryGetProperty("command", out var command) || command.ValueKind != JsonValueKind.String
                    || !ControlCommands.Contains(command.GetString()!)) continue;
                if (!body.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.String) continue;
                var outcome = result.GetString()!;
                bool accepted = outcome.Equals("success", StringComparison.OrdinalIgnoreCase)
                    || outcome.Equals("ok", StringComparison.OrdinalIgnoreCase);
                string? reason = body.TryGetProperty("reason", out var why) && why.ValueKind == JsonValueKind.String
                    && !string.IsNullOrEmpty(why.GetString()) ? why.GetString() : null;
                return new BambuCommandReply(command.GetString()!, accepted, accepted ? null : reason ?? outcome);
            }
        }
        catch (JsonException) { }
        return null;
    }
}
