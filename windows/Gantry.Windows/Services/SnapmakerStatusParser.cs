using System.Globalization;
using System.IO;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Parses Snapmaker's local HTTP API /api/v1/status (port 8080) into PrinterTelemetry.
/// Field names follow Luban's HTTP server; every field is read defensively. Mirrors macOS.</summary>
public static class SnapmakerStatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] statusData, PrinterTelemetry? previous = null)
    {
        JsonElement root;
        try { using var doc = JsonDocument.Parse(statusData); root = doc.RootElement.Clone(); }
        catch { return null; }
        if (root.ValueKind != JsonValueKind.Object) return null;

        var t = previous?.Clone() ?? new PrinterTelemetry();

        if ((Str(root, "status") ?? Str(root, "printStatus")) is { } state) t.State = MapState(state);
        if (Num(root, "nozzleTemperature") is { } n) t.NozzleTemperature = n;
        if (Num(root, "nozzleTargetTemperature") is { } nt) t.NozzleTargetTemperature = nt;
        if (Num(root, "heatedBedTemperature") is { } b) t.BedTemperature = b;
        if (Num(root, "heatedBedTargetTemperature") is { } bt) t.BedTargetTemperature = bt;

        if (Num(root, "progress") is { } p)
        {
            // Luban reports a 0…1 fraction; some firmware sends 0…100. Handle both.
            var percent = p <= 1.0 ? p * 100 : p;
            t.Progress = Math.Clamp((int)Math.Round(percent), 0, 100);
        }
        if (Num(root, "remainingTime") is { } rem && rem > 0) t.RemainingMinutes = (int)Math.Round(rem / 60);
        if (Str(root, "fileName") is { Length: > 0 } name) t.JobName = Path.GetFileName(name);

        t.LastUpdated = DateTime.Now;
        return t;
    }

    public static PrinterState MapState(string raw) => raw.ToUpperInvariant() switch
    {
        "RUNNING" or "PRINTING" => PrinterState.Printing,
        "PAUSED" or "PAUSING" => PrinterState.Paused,
        "STOPPED" or "COMPLETED" or "FINISHED" => PrinterState.Finished,
        "ERROR" => PrinterState.Error,
        "IDLE" or "READY" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static string? Str(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? Num(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ds)) return ds;
        return null;
    }
}
