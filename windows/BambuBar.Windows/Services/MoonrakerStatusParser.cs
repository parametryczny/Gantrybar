using System.Globalization;
using System.IO;
using System.Text.Json;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>Parses a Moonraker printer/objects/query response into PrinterTelemetry, including the
/// Happy Hare mmu object mapped to AMS slots. Mirrors the macOS MoonrakerStatusParser.</summary>
public static class MoonrakerStatusParser
{
    public static PrinterTelemetry? Telemetry(byte[] data, PrinterTelemetry? previous = null)
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

        if (Obj(status, "extruder", out var extruder))
        {
            if (Num(extruder, "temperature") is { } temp) t.NozzleTemperature = temp;
            if (Num(extruder, "target") is { } target) t.NozzleTargetTemperature = target;
        }
        if (Obj(status, "heater_bed", out var bed))
        {
            if (Num(bed, "temperature") is { } temp) t.BedTemperature = temp;
            if (Num(bed, "target") is { } target) t.BedTargetTemperature = target;
        }
        if (ChamberTemperature(status) is { } chamber) t.ChamberTemperature = chamber;

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
}
