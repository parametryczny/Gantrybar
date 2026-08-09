using System.Globalization;
using System.Text;
using System.Text.Json;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>Parses Bambu MQTT telemetry JSON, ported 1:1 from the macOS BambuStatusParser.</summary>
public static class StatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] data, PrinterTelemetry? previous = null)
    {
        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(data);
            root = doc.RootElement.Clone();
        }
        catch { return null; }

        if (root.ValueKind != JsonValueKind.Object) return null;
        JsonElement report;
        if (root.TryGetProperty("print", out var p)) report = p;
        else if (root.TryGetProperty("pushing", out var pu)) report = pu;
        else return null;
        if (report.ValueKind != JsonValueKind.Object) return null;

        var result = previous?.Clone() ?? new PrinterTelemetry();

        if (Str(report, "gcode_state") is { } state) result.State = MapState(state);
        if (Int(report, "mc_percent") is { } percent) result.Progress = Math.Min(Math.Max(percent, 0), 100);
        if (Int(report, "mc_remaining_time") is { } rem) result.RemainingMinutes = rem;
        if (Num(report, "nozzle_temper") is { } nt) result.NozzleTemperature = nt;
        if (Num(report, "nozzle_target_temper") is { } ntt) result.NozzleTargetTemperature = ntt;
        if (Num(report, "bed_temper") is { } bt) result.BedTemperature = bt;
        if (Num(report, "bed_target_temper") is { } btt) result.BedTargetTemperature = btt;
        // Dual-nozzle printers (H2D) report each extruder under device.extruder.info as {id, temp},
        // where temp packs current in the low 16 bits and target in the high 16 bits. Single-nozzle
        // machines omit this and keep using nozzle_temper above.
        if (report.TryGetProperty("device", out var dev) && dev.ValueKind == JsonValueKind.Object
            && dev.TryGetProperty("extruder", out var extruder) && extruder.ValueKind == JsonValueKind.Object
            && extruder.TryGetProperty("info", out var extruderInfo) && extruderInfo.ValueKind == JsonValueKind.Array)
        {
            double? current0 = null, target0 = null, current1 = null, target1 = null;
            foreach (var item in extruderInfo.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                if (Int(item, "id") is not { } id || Int(item, "temp") is not { } packed) continue;
                double current = packed & 0xFFFF;
                double target = (packed >> 16) & 0xFFFF;
                if (id == 0) { current0 = current; target0 = target; }
                else if (id == 1) { current1 = current; target1 = target; }
            }
            if (current0 is { }) { result.NozzleTemperature = current0; result.NozzleTargetTemperature = target0; }
            result.NozzleTemperature2 = current1;
            result.NozzleTargetTemperature2 = target1;
        }
        // Modern firmware reports the real chamber temperature under device.ctc.info.temp;
        // printers without a chamber sensor (A1, P1) omit it and chamber_temper is only a fixed
        // placeholder there, so accept the legacy field only as a plausible fallback.
        if (report.TryGetProperty("device", out var device) && device.ValueKind == JsonValueKind.Object
            && device.TryGetProperty("ctc", out var ctc) && ctc.ValueKind == JsonValueKind.Object
            && ctc.TryGetProperty("info", out var ctcInfo) && ctcInfo.ValueKind == JsonValueKind.Object
            && Num(ctcInfo, "temp") is { } chamber)
        {
            result.ChamberTemperature = chamber;
        }
        else if (Num(report, "chamber_temper") is { } legacyChamber && legacyChamber > 10)
        {
            result.ChamberTemperature = legacyChamber;
        }
        if (Int(report, "layer_num") is { } ln) result.CurrentLayer = ln;
        if (Int(report, "total_layer_num") is { } tln) result.TotalLayers = tln;

        if (report.TryGetProperty("stage", out var stage) && stage.ValueKind == JsonValueKind.Object && Int(stage, "_id") is { } sid)
            result.CurrentStage = sid;
        else if (Int(report, "stg_cur") is { } stg)
            result.CurrentStage = stg;

        if ((Str(report, "print_type")?.ToLowerInvariant() == "idle") && result.CurrentStage == 0)
            result.CurrentStage = 255;

        if (Str(report, "subtask_name") is { Length: > 0 } job) result.JobName = DisplayName(job);
        if (UInt64Value(report, "print_error") is { } err) result.ErrorCode = err;

        if (report.TryGetProperty("hms", out var hms) && hms.ValueKind == JsonValueKind.Array)
        {
            var codes = new List<string>();
            foreach (var item in hms.EnumerateArray())
                if (HmsCode(item) is { } code) codes.Add(code);
            result.HmsCodes = codes;
        }

        if (report.TryGetProperty("ams", out var ams) && ams.ValueKind == JsonValueKind.Object)
        {
            // A partial report often carries only tray_now without the tray list. ParseAmsGroups
            // keeps the last known groups and preserves the active slot instead of blanking them.
            var groups = ParseAmsGroups(ams, result.FilamentGroups);
            if (groups is { }) result.FilamentGroups = groups;
            // Flat compatibility view + legacy humidity/temp for notifications / the tray.
            var flat = result.FilamentGroups.SelectMany(g => g.LegacyAmsSlots()).ToList();
            if (flat.Count > 0) result.AmsSlots = flat;
            if (result.FilamentGroups.FirstOrDefault(g => g.HumidityPercent.HasValue)?.HumidityPercent is { } hum)
                result.AmsHumidity = hum;
            if (result.FilamentGroups.FirstOrDefault(g => g.TemperatureCelsius.HasValue)?.TemperatureCelsius is { } tmp)
                result.AmsTemperature = tmp;
        }

        // Publish the nozzle collection the dashboard renders. Starting from previous means a partial
        // report that omits the second extruder keeps the last known right-nozzle values.
        if (result.NozzleTemperature2 is { } || result.NozzleTargetTemperature2 is { })
        {
            result.Nozzles = new List<NozzleTelemetry>
            {
                new() { Position = NozzlePosition.Left, CurrentTemperature = result.NozzleTemperature, TargetTemperature = result.NozzleTargetTemperature },
                new() { Position = NozzlePosition.Right, CurrentTemperature = result.NozzleTemperature2, TargetTemperature = result.NozzleTargetTemperature2 }
            };
        }
        else
        {
            result.Nozzles = new List<NozzleTelemetry>
            {
                new() { Position = NozzlePosition.Single, CurrentTemperature = result.NozzleTemperature, TargetTemperature = result.NozzleTargetTemperature }
            };
        }

        if (result.ErrorCode != 0) result.State = PrinterState.Error;
        result.LastUpdated = DateTime.Now;
        return result;
    }

    public static PrinterState MapState(string raw) => raw.ToUpperInvariant() switch
    {
        "RUNNING" or "PREPARE" => PrinterState.Printing,
        "PAUSE" or "PAUSED" => PrinterState.Paused,
        "FINISH" or "FINISHED" => PrinterState.Finished,
        "FAILED" or "ERROR" => PrinterState.Error,
        "IDLE" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static string DisplayName(string raw)
    {
        string value = Uri.UnescapeDataString(raw);
        if (value.Contains('Ã') || value.Contains('Å') || value.Contains('Ä'))
        {
            try
            {
                var bytes = Encoding.GetEncoding(1252).GetBytes(value);
                value = Encoding.UTF8.GetString(bytes);
            }
            catch { /* keep original */ }
        }
        return value.Normalize(NormalizationForm.FormC);
    }

    /// <summary>Build one FilamentGroup per physical unit (ams.ams[]) plus an EXT group for vt_tray.
    /// Returns null for a pure-partial report so the caller keeps its previous groups untouched.</summary>
    private static List<FilamentGroup>? ParseAmsGroups(JsonElement ams, List<FilamentGroup> previous)
    {
        bool hasTrayNow = ams.TryGetProperty("tray_now", out _);
        string activeRaw = Str(ams, "tray_now") ?? Int(ams, "tray_now")?.ToString() ?? "";
        // Only trust tray_now when it names a real slot; otherwise fall back to the previously active
        // slot so a report that carries the tray list without tray_now doesn't clear the ring.
        bool activeAuthoritative = hasTrayNow && activeRaw.Length > 0 && activeRaw != "255";
        string? previousActiveId = previous.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsActive)?.Id;
        bool ResolveActive(string id, bool matches) => activeAuthoritative ? matches : id == previousActiveId;

        var groups = new List<FilamentGroup>();

        if (ams.TryGetProperty("ams", out var units) && units.ValueKind == JsonValueKind.Array && units.GetArrayLength() > 0)
        {
            int unitIndex = 0;
            foreach (var unit in units.EnumerateArray())
            {
                string unitId = Str(unit, "id") ?? unitIndex.ToString();
                string letter = ((char)(65 + Math.Min(unitIndex, 25))).ToString();
                var trays = unit.TryGetProperty("tray", out var t) && t.ValueKind == JsonValueKind.Array
                    ? t.EnumerateArray().ToList()
                    : new List<JsonElement>();
                // A single-spool AMS reports itself as unit 128; a regular AMS owns four fixed positions.
                bool isSingle = unitId == "128" || (trays.Count == 1 && unitId != unitIndex.ToString());
                int capacity = isSingle ? 1 : 4;
                var slots = new List<FilamentSlot>();
                for (int trayIndex = 0; trayIndex < capacity; trayIndex++)
                {
                    bool hasTray = trayIndex < trays.Count;
                    JsonElement tray = hasTray ? trays[trayIndex] : default;
                    string trayId = (hasTray ? (Str(tray, "id") ?? Int(tray, "id")?.ToString()) : null) ?? trayIndex.ToString();
                    string? rawMaterial = hasTray ? (Str(tray, "tray_type") ?? Str(tray, "tray_sub_brands")) : null;
                    string? material = string.IsNullOrEmpty(rawMaterial) ? null : rawMaterial;
                    string slotId = $"ams-{unitId}-{trayId}";
                    int globalIndex = unitIndex * 4 + trayIndex;
                    bool matches = activeRaw == globalIndex.ToString() || activeRaw == $"{unitId}{trayId}";
                    slots.Add(new FilamentSlot
                    {
                        Id = slotId,
                        Label = $"{letter}{trayIndex + 1}",
                        Material = material,
                        ColorHex = material != null ? ((hasTray ? Str(tray, "tray_color") : null) ?? "8E8E93FF") : null,
                        RemainingPercent = material != null && hasTray ? Int(tray, "remain") : null,
                        IsActive = ResolveActive(slotId, matches)
                    });
                }
                groups.Add(new FilamentGroup
                {
                    Id = $"ams-{unitId}",
                    SourceType = isSingle ? FilamentSourceType.AmsHT : FilamentSourceType.Ams,
                    DisplayName = unitId == "128" ? "AMS HT" : $"AMS {letter}",
                    DeclaredCapacity = capacity,
                    HumidityPercent = Int(unit, "humidity_raw") ?? Int(unit, "humidity"),
                    TemperatureCelsius = Num(unit, "temp"),
                    IsExternal = false,
                    Slots = slots
                });
                unitIndex++;
            }
        }

        if (ams.TryGetProperty("vt_tray", out var external) && external.ValueKind == JsonValueKind.Object)
        {
            string? rawMaterial = Str(external, "tray_type") ?? Str(external, "tray_sub_brands");
            if (!string.IsNullOrEmpty(rawMaterial))
            {
                string trayId = Str(external, "id") ?? "254";
                string slotId = $"external-{trayId}";
                bool matches = activeRaw == trayId || activeRaw == "254" || activeRaw == "255";
                groups.Add(new FilamentGroup
                {
                    Id = slotId,
                    SourceType = FilamentSourceType.External,
                    DisplayName = "EXT",
                    DeclaredCapacity = 1,
                    HumidityPercent = null,
                    TemperatureCelsius = null,
                    IsExternal = true,
                    Slots = new List<FilamentSlot>
                    {
                        new()
                        {
                            Id = slotId,
                            Label = "EXT",
                            Material = rawMaterial,
                            ColorHex = Str(external, "tray_color") ?? "E8E8E8FF",
                            RemainingPercent = Int(external, "remain"),
                            IsActive = ResolveActive(slotId, matches)
                        }
                    }
                });
            }
        }

        // Pure-partial report (no unit list, no external): keep the previously known modules.
        if (groups.Count == 0) return previous.Count == 0 ? null : previous;
        return groups;
    }

    private static string? HmsCode(JsonElement item)
    {
        if (UInt64Value(item, "code") is not { } code) return null;
        ulong attr = UInt64Value(item, "attr") ?? 0;
        if (attr == 0 && Str(item, "ecode") is { Length: > 0 } raw)
            return raw.Replace("_", "").ToUpperInvariant();
        return $"{attr:X8}{code:X8}";
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

    private static int? Int(JsonElement obj, string key)
    {
        var n = Num(obj, key);
        return n.HasValue ? (int)n.Value : null;
    }

    private static ulong? UInt64Value(JsonElement obj, string key)
    {
        if (!obj.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number)
        {
            if (v.TryGetUInt64(out var u)) return u;
            if (v.TryGetDouble(out var d)) return (ulong)d;
        }
        if (v.ValueKind == JsonValueKind.String)
        {
            string s = v.GetString() ?? "";
            if (ulong.TryParse(s, out var dec)) return dec;
            string hex = s.Replace("0x", "");
            if (ulong.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var h)) return h;
        }
        return null;
    }
}
