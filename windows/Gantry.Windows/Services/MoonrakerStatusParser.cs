using System.Globalization;
using System.IO;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Parses a Moonraker printer/objects/query response into PrinterTelemetry, including the
/// Happy Hare mmu object mapped to AMS slots. Mirrors the macOS MoonrakerStatusParser.</summary>
public static class MoonrakerStatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] data, PrinterTelemetry? previous = null, MoonrakerObjects? objects = null)
    {
        JsonElement root;
        try { using var doc = JsonDocument.Parse(data); root = doc.RootElement.Clone(); }
        catch { return null; }

        JsonElement result = root.TryGetProperty("result", out var r) ? r : root;
        if (!result.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.Object) return null;

        var t = previous?.Clone() ?? new PrinterTelemetry();

        if (Obj(status, "print_stats", out var printStats))
        {
            if (Str(printStats, "state") is { } state) t.State = MapState(state);
            if (Str(printStats, "filename") is { Length: > 0 } file) t.JobName = Path.GetFileName(file);
            if (Obj(printStats, "info", out var info))
            {
                if (Int(info, "current_layer") is { } cl) t.CurrentLayer = cl;
                if (Int(info, "total_layer") is { } tl) t.TotalLayers = tl;
            }
            // Real measured filament consumed so far (mm) — basis for spool decrement on finish.
            if (Num(printStats, "filament_used") is { } used) t.FilamentUsedMM = used;
        }

        // Creality K1/K1Max leave print_stats.info.*_layer null and expose layers on virtual_sdcard.
        if (Obj(status, "virtual_sdcard", out var vsd))
        {
            if (t.CurrentLayer is null && Int(vsd, "layer") is { } vl) t.CurrentLayer = vl;
            if (t.TotalLayers is null && Int(vsd, "layer_count") is { } vc) t.TotalLayers = vc;
        }

        double? progress = null;
        if (Obj(status, "display_status", out var ds)) progress = Num(ds, "progress");
        if (progress is null && Obj(status, "virtual_sdcard", out var vs)) progress = Num(vs, "progress");
        if (progress is { } p) t.Progress = Math.Clamp((int)Math.Round(p * 100), 0, 100);

        if (Obj(status, "print_stats", out var ps) && Num(ps, "print_duration") is { } duration && duration > 0
            && progress is { } pr && pr > 0.01)
        {
            t.RemainingMinutes = (int)Math.Round(duration * (1 - pr) / pr / 60);
        }

        objects ??= new MoonrakerObjects();
        if (Obj(status, objects.Nozzle, out var extruder))
        {
            if (Num(extruder, "temperature") is { } temp) t.NozzleTemperature = temp;
            if (Num(extruder, "target") is { } target) t.NozzleTargetTemperature = target;
        }
        if (Obj(status, objects.Bed, out var bed))
        {
            if (Num(bed, "temperature") is { } temp) t.BedTemperature = temp;
            if (Num(bed, "target") is { } target) t.BedTargetTemperature = target;
        }
        // Chamber: the overridden object if given, else auto-detect a *chamber* sensor.
        if (!string.IsNullOrEmpty(objects.Chamber) && Obj(status, objects.Chamber!, out var chObj) && Num(chObj, "temperature") is { } chTemp)
            t.ChamberTemperature = chTemp;
        else if (ChamberTemperature(status) is { } chamber) t.ChamberTemperature = chamber;

        // Part-cooling fan (0-1) and the live speed factor (1.0 = 100%).
        ApplyFans(status, objects.Fan, t);
        if (Obj(status, "gcode_move", out var gm) && Num(gm, "speed_factor") is { } speedFactor)
            t.SpeedPercent = (int)Math.Round(speedFactor * 100);

        if (Obj(status, "mmu", out var mmu) && ParseMmuGroup(mmu) is { } mmuGroup)
        {
            t.FilamentGroups = new List<FilamentGroup> { mmuGroup };
            t.AmsSlots = mmuGroup.LegacyAmsSlots().ToList();
        }

        // Single-nozzle Klipper machine: expose one nozzle entry so the dashboard renders it via the
        // shared collection just like Bambu.
        t.Nozzles = new List<NozzleTelemetry>
        {
            new() { Position = NozzlePosition.Single, CurrentTemperature = t.NozzleTemperature, TargetTemperature = t.NozzleTargetTemperature }
        };

        t.LastUpdated = DateTime.Now;
        return t;
    }

    public static PrinterState MapState(string raw) => raw.ToLowerInvariant() switch
    {
        "printing" => PrinterState.Printing,
        "paused" => PrinterState.Paused,
        "complete" or "completed" => PrinterState.Finished,
        "error" => PrinterState.Error,
        "cancelled" or "canceled" or "standby" => PrinterState.Idle,
        _ => PrinterState.Idle
    };

    private static double? ChamberTemperature(JsonElement status)
    {
        foreach (var prop in status.EnumerateObject())
        {
            if (!prop.Name.ToLowerInvariant().Contains("chamber")) continue;
            if ((prop.Name.StartsWith("temperature_sensor") || prop.Name.StartsWith("heater_generic"))
                && prop.Value.ValueKind == JsonValueKind.Object && Num(prop.Value, "temperature") is { } temp)
                return temp;
        }
        return null;
    }

    /// <summary>Happy Hare is one dynamic module: num_gates gates named T0..Tn, never split into
    /// fours. Empty gates (status 0) stay as grey slots so the layout keeps its width.</summary>
    private static FilamentGroup? ParseMmuGroup(JsonElement mmu)
    {
        if (mmu.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.False) return null;
        if (Int(mmu, "num_gates") is not { } count || count <= 0) return null;

        var materials = Arr(mmu, "gate_material");
        var colors = Arr(mmu, "gate_color");
        var statuses = Arr(mmu, "gate_status");
        int current = Int(mmu, "gate") ?? -1;

        var slots = new List<FilamentSlot>();
        for (int i = 0; i < count; i++)
        {
            int gateStatus = i < statuses.Count ? (IntValue(statuses[i]) ?? -1) : -1;
            string rawMaterial = i < materials.Count ? (StringValue(materials[i]) ?? "") : "";
            bool present = gateStatus != 0 && rawMaterial.Length > 0;
            slots.Add(new FilamentSlot
            {
                Id = $"mmu-{i}",
                Label = $"T{i}",
                Material = present ? rawMaterial : null,
                ColorHex = present ? AmsColor(i < colors.Count ? StringValue(colors[i]) : null) : null,
                RemainingPercent = null,
                IsActive = i == current
            });
        }
        return new FilamentGroup
        {
            Id = "mmu",
            SourceType = FilamentSourceType.Mmu,
            DisplayName = "MMU",
            DeclaredCapacity = count,
            HumidityPercent = null,
            TemperatureCelsius = null,
            IsExternal = false,
            Slots = slots
        };
    }

    private static string AmsColor(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "8E8E93FF";
        var value = raw.StartsWith('#') ? raw[1..] : raw;
        if (value.Length == 6) return (value + "FF").ToUpperInvariant();
        if (value.Length == 8) return value.ToUpperInvariant();
        return "8E8E93FF";
    }

    /// <summary>Parses a Creality CFS WebSocket <c>boxsInfo</c> reply into AMS slots. Creality's
    /// filament system is not a Klipper object; it lives on the printer's own ws://host:9999 API,
    /// so this is fed separately from the Moonraker poll. Returns null when there are no boxes.</summary>
    public static List<FilamentGroup>? ParseCfsGroups(byte[] data)
    {
        JsonElement root;
        try { using var doc = JsonDocument.Parse(data); root = doc.RootElement.Clone(); }
        catch { return null; }

        JsonElement container = root;
        if (root.ValueKind == JsonValueKind.Object)
        {
            if (root.TryGetProperty("boxsInfo", out var b) && b.ValueKind == JsonValueKind.Object) container = b;
            else if (root.TryGetProperty("result", out var r) && r.ValueKind == JsonValueKind.Object) container = r;
        }
        if (!container.TryGetProperty("materialBoxs", out var boxes) || boxes.ValueKind != JsonValueKind.Array) return null;

        var groups = new List<FilamentGroup>();
        int boxIndex = 0;
        int cfsNumber = 0;
        int slotNumber = 0;
        foreach (var box in boxes.EnumerateArray())
        {
            bool spool = (Int(box, "type") ?? 0) == 1;
            var materials = box.TryGetProperty("materials", out var m) && m.ValueKind == JsonValueKind.Array
                ? m.EnumerateArray().ToList()
                : new List<JsonElement>();
            int capacity = spool ? 1 : 4;
            var slots = new List<FilamentSlot>();
            for (int slotIndex = 0; slotIndex < capacity; slotIndex++)
            {
                bool hasMaterial = slotIndex < materials.Count;
                JsonElement material = hasMaterial ? materials[slotIndex] : default;
                string type = hasMaterial ? (Str(material, "type") ?? "") : "";
                string name = hasMaterial ? (Str(material, "name") ?? "") : "";
                string? display = type.Length > 0 ? type : (name.Length == 0 ? null : name);
                bool present = display != null;
                string label = spool ? "EXT" : $"T{slotNumber}";
                if (!spool) slotNumber++;
                slots.Add(new FilamentSlot
                {
                    Id = $"cfs-{boxIndex}-{slotIndex}",
                    Label = label,
                    Material = display,
                    ColorHex = present ? CfsColor(hasMaterial ? Str(material, "color") : null) : null,
                    RemainingPercent = hasMaterial ? Int(material, "percent") : null,
                    IsActive = hasMaterial && (Int(material, "selected") ?? 0) == 1
                });
            }
            if (spool)
            {
                groups.Add(new FilamentGroup
                {
                    Id = $"cfs-ext-{boxIndex}", SourceType = FilamentSourceType.External, DisplayName = "EXT",
                    DeclaredCapacity = 1, HumidityPercent = null, TemperatureCelsius = null,
                    IsExternal = true, Slots = slots
                });
            }
            else
            {
                cfsNumber++;
                groups.Add(new FilamentGroup
                {
                    Id = $"cfs-{boxIndex}", SourceType = FilamentSourceType.Cfs, DisplayName = $"CFS {cfsNumber}",
                    DeclaredCapacity = capacity, HumidityPercent = null, TemperatureCelsius = null,
                    IsExternal = false, Slots = slots
                });
            }
            boxIndex++;
        }
        return groups.Count > 0 ? groups : null;
    }

    /// <summary>CFS colours are hex, sometimes with an extra leading zero (e.g. "0fa7c0c").</summary>
    private static string CfsColor(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "8E8E93FF";
        var value = raw.StartsWith('#') ? raw[1..] : raw;
        if (value.Length == 7) value = value[1..];
        return AmsColor(value);
    }

    private static bool Obj(JsonElement parent, string key, out JsonElement value)
    {
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(key, out value) && value.ValueKind == JsonValueKind.Object)
            return true;
        value = default;
        return false;
    }

    private static List<JsonElement> Arr(JsonElement parent, string key)
    {
        if (parent.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Array)
            return value.EnumerateArray().ToList();
        return new();
    }

    private static string? Str(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double? Num(JsonElement obj, string key)
        => obj.TryGetProperty(key, out var v) ? NumberValue(v) : null;

    private static int? Int(JsonElement obj, string key)
    {
        var n = Num(obj, key);
        return n.HasValue ? (int)n.Value : null;
    }

    private static double? NumberValue(JsonElement v)
    {
        if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
        if (v.ValueKind == JsonValueKind.String && double.TryParse(v.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ds)) return ds;
        return null;
    }

    private static string? StringValue(JsonElement v) => v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? IntValue(JsonElement v)
    {
        var n = NumberValue(v);
        return n.HasValue ? (int)n.Value : null;
    }

    /// Klipper exposes the part cooler as plain `fan`, but auxiliary/chamber/exhaust fans arrive as
    /// `fan_generic <name>` (also `heater_fan`, `controller_fan`), and some vendor forks (Creality among
    /// them) publish no bare `fan` at all. Classify by name over whatever the query returned rather than
    /// reading one hard-coded object, which left Aux and Chamber permanently blank.
    private static readonly string[] FanPrefixes =
        { "fan_generic ", "heater_fan ", "controller_fan ", "temperature_fan " };

    private static void ApplyFans(JsonElement status, string preferredPartName, PrinterTelemetry t)
    {
        // Collect first, decide after: enumeration order is not guaranteed, so classifying inside the
        // loop lets a heater fan claim the part slot before the real `fan` is seen.
        var readings = new List<(string Name, int Percent)>();
        foreach (var property in status.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
        {
            string key = property.Name;
            bool isFan = key == preferredPartName || key == "fan" || FanPrefixes.Any(key.StartsWith);
            if (!isFan || property.Value.ValueKind != JsonValueKind.Object) continue;
            double? raw = Num(property.Value, "speed") ?? Num(property.Value, "value");
            if (raw is not { } value) continue;
            readings.Add((key, (int)Math.Round(Math.Clamp(value, 0, 1) * 100)));
        }
        if (readings.Count == 0) return;

        int? First(Func<string, bool> matches)
        {
            foreach (var r in readings) if (matches(r.Name.ToLowerInvariant())) return r.Percent;
            return null;
        }

        var explicitPart = readings.FirstOrDefault(r => r.Name == preferredPartName || r.Name == "fan");
        if (explicitPart.Name is not null) t.PartFanPercent = explicitPart.Percent;
        else if (First(n => n.Contains("part") || n.Contains("cooling")) is { } named) t.PartFanPercent = named;
        else
        {
            // A vendor fork with no bare `fan`: the one generic fan it does publish is the part cooler.
            // Heater and controller fans are excluded, they cool the hotend and the electronics.
            var lone = readings.FirstOrDefault(r => !r.Name.StartsWith("heater_fan")
                                                 && !r.Name.StartsWith("controller_fan"));
            if (lone.Name is not null) t.PartFanPercent = lone.Percent;
        }
        if (First(n => n.Contains("aux") || n.Contains("side")) is { } aux) t.AuxFanPercent = aux;
        if (First(n => n.Contains("chamber") || n.Contains("exhaust") || n.Contains("filter")) is { } ch)
            t.ChamberFanPercent = ch;
    }
}
