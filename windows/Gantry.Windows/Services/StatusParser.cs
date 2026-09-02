using System.Globalization;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

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
        // Dual-nozzle printers (H2D / X2D) report each extruder under device.extruder.info as
        // {id, temp}, where temp packs current in the low 16 bits and target in the high 16 bits.
        // On this hardware the LEFT (main) nozzle is id 1 and the RIGHT is id 0 — so the primary
        // reading (NozzleTemperature, shown as "L") comes from id 1. Single-nozzle machines omit
        // this and keep using nozzle_temper above.
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
            if (current1 is { })   // left / main nozzle
            {
                result.NozzleTemperature = current1; result.NozzleTargetTemperature = target1;
                result.NozzleTemperature2 = current0; result.NozzleTargetTemperature2 = target0;   // right
            }
            else if (current0 is { }) { result.NozzleTemperature = current0; result.NozzleTargetTemperature = target0; }
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

        // Fans (part / aux / chamber), speed level+magnitude and nozzle diameter. Keep the previous
        // value when a key is missing (partial reports drop them).
        if (FanPercent(report, "cooling_fan_speed") is { } pf) result.PartFanPercent = pf;
        if (FanPercent(report, "big_fan1_speed") is { } af) result.AuxFanPercent = af;
        if (FanPercent(report, "big_fan2_speed") is { } cf) result.ChamberFanPercent = cf;
        if (Int(report, "spd_lvl") is { } sl) result.SpeedLevel = sl;
        if (Int(report, "spd_mag") is { } sm) result.SpeedPercent = sm;
        if (Num(report, "nozzle_diameter") is { } nd && nd > 0) result.NozzleDiameter = nd;

        if (report.TryGetProperty("stage", out var stage) && stage.ValueKind == JsonValueKind.Object && Int(stage, "_id") is { } sid)
            result.CurrentStage = sid;
        else if (Int(report, "stg_cur") is { } stg)
            result.CurrentStage = stg;

        if ((Str(report, "print_type")?.ToLowerInvariant() == "idle") && result.CurrentStage == 0)
            result.CurrentStage = 255;

        if (Str(report, "subtask_name") is { Length: > 0 } job) result.JobName = DisplayName(job);
        // The file being printed (for fetching its per-filament used_g from the 3mf).
        if (Str(report, "gcode_file") is { Length: > 0 } gf) result.GcodeFile = gf;
        else if (Str(report, "subtask_name") is { Length: > 0 } sn) result.GcodeFile = sn;
        if (UInt64Value(report, "print_error") is { } err) result.ErrorCode = err;

        if (report.TryGetProperty("hms", out var hms) && hms.ValueKind == JsonValueKind.Array)
        {
            var codes = new List<string>();
            foreach (var item in hms.EnumerateArray())
                if (HmsCode(item) is { } code) codes.Add(code);
            result.HmsCodes = codes;
        }

        // External spools live in different places: older firmwares use a single vt_tray dict (inside
        // print.ams or at the top level); the H2D family (AMS HT models) uses a print.vir_slot list.
        JsonElement? amsObject = report.TryGetProperty("ams", out var amsEl) && amsEl.ValueKind == JsonValueKind.Object
            ? amsEl : (JsonElement?)null;
        var externalTrays = new List<JsonElement>();
        var seenExternalIds = new HashSet<string>();
        void AddExternal(JsonElement candidate)
        {
            if (candidate.ValueKind != JsonValueKind.Object) return;
            string extId = Str(candidate, "id") ?? Int(candidate, "id")?.ToString() ?? "";
            if (extId.Length > 0 && !seenExternalIds.Add(extId)) return;
            externalTrays.Add(candidate);
        }
        bool hasExternalPayload = report.TryGetProperty("vir_slot", out _) || report.TryGetProperty("vt_tray", out _)
            || (amsObject is { } extObj && extObj.TryGetProperty("vt_tray", out _));
        if (report.TryGetProperty("vir_slot", out var vir) && vir.ValueKind == JsonValueKind.Array)
            foreach (var slot in vir.EnumerateArray()) AddExternal(slot);
        if (amsObject is { } aObj && aObj.TryGetProperty("vt_tray", out var vtInner)) AddExternal(vtInner);
        else if (report.TryGetProperty("vt_tray", out var vtTop)) AddExternal(vtTop);

        if (amsObject is { } || externalTrays.Count > 0)
        {
            // A partial report often carries only tray_now without the tray list. ParseAmsGroups
            // keeps the last known groups and preserves the active slot instead of blanking them.
            var groups = ParseAmsGroups(amsObject, externalTrays, hasExternalPayload, result.FilamentGroups);
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

    /// <summary>Build one FilamentGroup per physical unit (ams.ams[]) plus EXT groups for the external
    /// spools (vt_tray / vir_slot, gathered by the caller). Returns null for a pure-partial report so
    /// the caller keeps its previous groups untouched.</summary>
    private static List<FilamentGroup>? ParseAmsGroups(JsonElement? amsNullable, List<JsonElement> externalTrays,
                                                       bool externalAuthoritative, List<FilamentGroup> previous)
    {
        JsonElement ams = amsNullable ?? default;
        bool hasAms = amsNullable is { } && ams.ValueKind == JsonValueKind.Object;
        bool hasAmsPayload = hasAms && ams.TryGetProperty("ams", out _);
        bool hasTrayNow = hasAms && ams.TryGetProperty("tray_now", out _);
        string activeRaw = hasAms ? (Str(ams, "tray_now") ?? Int(ams, "tray_now")?.ToString() ?? "") : "";
        // Only trust tray_now when it names a real slot; otherwise fall back to the previously active
        // slot so a report that carries the tray list without tray_now doesn't clear the ring.
        bool activeAuthoritative = hasTrayNow && activeRaw.Length > 0 && activeRaw != "255";
        string? previousActiveId = previous.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsActive)?.Id;
        bool ResolveActive(string id, bool matches) => activeAuthoritative ? matches : id == previousActiveId;

        var groups = new List<FilamentGroup>();

        if (hasAms && ams.TryGetProperty("ams", out var units) && units.ValueKind == JsonValueKind.Array && units.GetArrayLength() > 0)
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
                        RemainingWeightGrams = material != null && hasTray ? NfcGrams(tray) : null,
                        IsActive = ResolveActive(slotId, matches)
                    });
                }
                // Keep the last known humidity/temperature when a mid-print report omits them.
                var previousUnit = previous.FirstOrDefault(g => g.Id == $"ams-{unitId}");
                groups.Add(new FilamentGroup
                {
                    Id = $"ams-{unitId}",
                    SourceType = isSingle ? FilamentSourceType.AmsHT : FilamentSourceType.Ams,
                    DisplayName = unitId == "128" ? "AMS HT" : $"AMS {letter}",
                    DeclaredCapacity = capacity,
                    HumidityPercent = Int(unit, "humidity_raw") ?? Int(unit, "humidity") ?? previousUnit?.HumidityPercent,
                    TemperatureCelsius = Num(unit, "temp") ?? previousUnit?.TemperatureCelsius,
                    IsExternal = false,
                    Slots = slots
                });
                unitIndex++;
            }
        }

        bool multipleExternals = externalTrays.Count > 1;
        for (int extIndex = 0; extIndex < externalTrays.Count; extIndex++)
        {
            var external = externalTrays[extIndex];
            string? rawMaterial = Str(external, "tray_type") ?? Str(external, "tray_sub_brands");
            string? material = string.IsNullOrEmpty(rawMaterial) ? null : rawMaterial;
            string trayId = Str(external, "id") ?? Int(external, "id")?.ToString() ?? "254";
            string slotId = $"external-{trayId}";
            bool matches = activeRaw == trayId || activeRaw == "254" || activeRaw == "255";
            // Show when a spool is loaded, or when actively fed even if this partial report lacks the type.
            if (material == null && !(activeAuthoritative && matches)) continue;
            string label = multipleExternals ? $"EXT {extIndex + 1}" : "EXT";
            groups.Add(new FilamentGroup
            {
                Id = slotId,
                SourceType = FilamentSourceType.External,
                DisplayName = label,
                DeclaredCapacity = 1,
                HumidityPercent = null,
                TemperatureCelsius = null,
                IsExternal = true,
                Slots = new List<FilamentSlot>
                {
                    new()
                    {
                        Id = slotId,
                        Label = label,
                        Material = material,
                        ColorHex = material != null ? (Str(external, "tray_color") ?? "E8E8E8FF") : null,
                        RemainingPercent = material != null ? Int(external, "remain") : null,
                        RemainingWeightGrams = material != null ? NfcGrams(external) : null,
                        IsActive = ResolveActive(slotId, matches)
                    }
                }
            });
        }

        // Bambu sends AMS and external-tray data in independent partial reports. A report carrying only
        // vt_tray / vir_slot must update EXT without temporarily deleting every AMS unit; conversely an
        // AMS-only report must not make EXT blink out. Preserve the side missing from this packet and
        // replace only the authoritative side, otherwise the card changes height and springs back.
        if (!hasAmsPayload) groups.InsertRange(0, previous.Where(g => !g.IsExternal));
        if (!externalAuthoritative) groups.AddRange(previous.Where(g => g.IsExternal));

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

    /// <summary>Remaining grams from an AMS NFC/RFID tray: tray_weight (nominal grams) scaled by remain (%).
    /// Null for spools whose tag carries no weight (non-RFID / third-party).</summary>
    private static double? NfcGrams(JsonElement tray)
    {
        if (Num(tray, "tray_weight") is not { } nominal || nominal <= 0) return null;
        int remain = Int(tray, "remain") ?? 100;
        return nominal * Math.Clamp(remain, 0, 100) / 100.0;
    }

    // Bambu reports fan speeds as a 0-15 gear (some firmwares already send a 0-100 percentage).
    // Normalise both to a percentage.
    private static int? FanPercent(JsonElement obj, string key)
    {
        if (Int(obj, key) is not { } raw) return null;
        if (raw > 15) return Math.Min(raw, 100);
        return (int)Math.Round(raw / 15.0 * 100);
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
