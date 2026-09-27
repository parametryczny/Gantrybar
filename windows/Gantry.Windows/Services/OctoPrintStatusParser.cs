using System.Globalization;
using System.IO;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Parses OctoPrint's REST API (/api/printer for state and temperatures, /api/job for the file
/// and progress) into PrinterTelemetry. Local only: host plus an application or global API key.
/// Mirrors the macOS OctoPrintStatusParser.</summary>
public static class OctoPrintStatusParser
{
    /// <summary><paramref name="printerData"/> is null when OctoPrint answered 409: it runs, but no
    /// printer is connected to it.</summary>
    public static PrinterTelemetry Telemetry(byte[]? printerData, byte[]? jobData, PrinterTelemetry? previous = null)
    {
        var t = previous?.Clone() ?? new PrinterTelemetry();
        t.LastUpdated = DateTime.Now;
        JsonElement root;
        try
        {
            if (printerData is null) throw new JsonException();
            using var doc = JsonDocument.Parse(printerData);
            root = doc.RootElement.Clone();
            if (root.ValueKind != JsonValueKind.Object) throw new JsonException();
        }
        catch (JsonException)
        {
            t.State = PrinterState.Offline;
            return t;
        }

        var flags = Obj(root, "state", out var state) && Obj(state, "flags", out var f) ? f : default;
        bool Flag(string name) => flags.ValueKind == JsonValueKind.Object && flags.TryGetProperty(name, out var v)
                                  && v.ValueKind == JsonValueKind.True;

        if (Obj(root, "temperature", out var temperature))
        {
            (double?, double?) Reading(string key) => Obj(temperature, key, out var entry)
                ? (Num(entry, "actual"), Num(entry, "target")) : (null, null);
            (t.NozzleTemperature, t.NozzleTargetTemperature) = Reading("tool0");
            (t.BedTemperature, t.BedTargetTemperature) = Reading("bed");
            (t.ChamberTemperature, t.ChamberTargetTemperature) = Reading("chamber");
        }

        double? progress = null;
        string? fileName = null;
        if (jobData is not null)
        {
            try
            {
                using var jobDoc = JsonDocument.Parse(jobData);
                var jobRoot = jobDoc.RootElement;
                if (Obj(jobRoot, "job", out var job) && Obj(job, "file", out var file))
                    fileName = Str(file, "display") ?? Str(file, "name");
                if (Obj(jobRoot, "progress", out var progressEntry))
                {
                    progress = Num(progressEntry, "completion");
                    t.RemainingMinutes = Num(progressEntry, "printTimeLeft") is { } left && left > 0
                        ? (int)Math.Round(left / 60) : null;
                }
            }
            catch (JsonException) { }
        }
        if (!string.IsNullOrEmpty(fileName)) t.JobName = Path.GetFileName(fileName);
        if (progress is { } p) t.Progress = Math.Clamp((int)Math.Floor(p), 0, 100);

        t.State = MapState(Flag, progress, !string.IsNullOrEmpty(fileName));
        if (t.State is not (PrinterState.Printing or PrinterState.Paused)) t.RemainingMinutes = null;
        return t;
    }

    public static PrinterState MapState(Func<string, bool> flag, double? progress, bool hasFile)
    {
        if (flag("error") || (flag("closedOrError") && !flag("operational"))) return PrinterState.Error;
        if (flag("paused") || flag("pausing")) return PrinterState.Paused;
        if (flag("printing")) return PrinterState.Printing;
        if (flag("cancelling")) return PrinterState.Idle;
        // OctoPrint has no "finished" state: the job stays loaded at 100 % until the next one.
        if (hasFile && progress is { } value && value >= 100) return PrinterState.Finished;
        if (flag("operational") || flag("ready")) return PrinterState.Idle;
        return PrinterState.Offline;
    }

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
