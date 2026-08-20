using System.Text.Json;

namespace Gantry.Services;

/// Optional per-printer overrides for setups that differ from the defaults — a camera on a separate
/// IP, custom light commands, and (Klipper) non-standard Moonraker object names.
public sealed class PrinterOverrides
{
    public string? CameraHost { get; set; }
    public string? LedOn { get; set; }
    public string? LedOff { get; set; }
    public string? NozzleObject { get; set; }   // default "extruder"
    public string? BedObject { get; set; }       // default "heater_bed"
    public string? ChamberObject { get; set; }   // default: auto-detect a *chamber* sensor
    public string? FanObject { get; set; }        // default "fan"

    public bool IsEmpty => new[] { CameraHost, LedOn, LedOff, NozzleObject, BedObject, ChamberObject, FanObject }
        .All(string.IsNullOrEmpty);

    public MoonrakerObjects MoonrakerObjects => new()
    {
        Nozzle = NonEmpty(NozzleObject) ?? "extruder",
        Bed = NonEmpty(BedObject) ?? "heater_bed",
        Chamber = NonEmpty(ChamberObject),
        Fan = NonEmpty(FanObject) ?? "fan"
    };

    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;
}

/// Moonraker object names to read temperatures and the cooling fan from (custom configs override).
public sealed class MoonrakerObjects
{
    public string Nozzle = "extruder";
    public string Bed = "heater_bed";
    public string? Chamber;     // null = auto-detect by the "chamber" name convention
    public string Fan = "fan";
}

public static class PrinterOverridesStore
{
    private const string Key = "printer-overrides-v1";

    public static PrinterOverrides For(string serial)
        => Load().TryGetValue(serial, out var o) ? o : new PrinterOverrides();

    public static void Set(string serial, PrinterOverrides overrides)
    {
        var all = Load();
        if (overrides.IsEmpty) all.Remove(serial); else all[serial] = overrides;
        Defaults.SetRaw(Key, JsonSerializer.Serialize(all));
    }

    private static Dictionary<string, PrinterOverrides> Load()
    {
        var raw = Defaults.GetRaw(Key);
        if (string.IsNullOrEmpty(raw)) return new();
        try { return JsonSerializer.Deserialize<Dictionary<string, PrinterOverrides>>(raw) ?? new(); }
        catch { return new(); }
    }
}
