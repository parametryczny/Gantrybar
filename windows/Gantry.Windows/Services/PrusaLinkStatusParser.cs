using System.Globalization;
using System.IO;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Parses PrusaLink's local HTTP API (/api/v1/status plus /api/v1/job for the file name)
/// into PrinterTelemetry. Local only (printer IP + API key), no Prusa account. Mirrors macOS.</summary>
public static class PrusaLinkStatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] statusData, byte[]? jobData, PrinterTelemetry? previous = null)
    {
        JsonElement root;
        try { using var doc = JsonDocument.Parse(statusData); root = doc.RootElement.Clone(); }
        catch { return null; }

        var t = previous?.Clone() ?? new PrinterTelemetry();

        if (Obj(root, "printer", out var printer))
        {
            if (Str(printer, "state") is { } state) t.State = MapState(state);
            if (Num(printer, "temp_nozzle") is { } n) t.NozzleTemperature = n;
            if (Num(printer, "target_nozzle") is { } nt) t.NozzleTargetTemperature = nt;
            if (Num(printer, "temp_bed") is { } b) t.BedTemperature = b;
            if (Num(printer, "target_bed") is { } bt) t.BedTargetTemperature = bt;
        }

        if (Obj(root, "job", out var job))
        {
            if (Num(job, "progress") is { } p) t.Progress = Math.Clamp((int)Math.Round(p), 0, 100);
            if (Num(job, "time_remaining") is { } rem && rem > 0) t.RemainingMinutes = (int)Math.Round(rem / 60);
        }

        if (jobData is not null)
        {
            try
            {
                using var jobDoc = JsonDocument.Parse(jobData);
                if (jobDoc.RootElement.TryGetProperty("file", out var file) && file.ValueKind == JsonValueKind.Object)
                {
                    var name = Str(file, "display_name") ?? Str(file, "name");
                    if (!string.IsNullOrEmpty(name)) t.JobName = Path.GetFileName(name);
                }
            }
            catch { /* job absent when idle */ }
        }

        t.LastUpdated = DateTime.Now;
        return t;
    }

    public static PrinterState MapState(string raw) => raw.ToUpperInvariant() switch
    {
        "PRINTING" => PrinterState.Printing,
        "PAUSED" => PrinterState.Paused,
        "FINISHED" => PrinterState.Finished,
        "ERROR" or "ATTENTION" => PrinterState.Error,
        "STOPPED" or "IDLE" or "READY" or "BUSY" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static bool Obj(JsonElement parent, string key, out JsonElement value)
    {
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out value) && value.ValueKind == JsonValueKind.Object)
            return true;
        value = default;
        return false;
    }

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
