using System.Text.Json.Serialization;

namespace Gantry.Models;

public enum PrinterState
{
    Idle,
    Printing,
    Paused,
    Finished,
    Error,
    Offline
}

public static class PrinterStateExtensions
{
    public static string Label(this PrinterState state, bool polish) => state switch
    {
        PrinterState.Idle => polish ? "Gotowa" : "Ready",
        PrinterState.Printing => polish ? "Drukowanie" : "Printing",
        PrinterState.Paused => polish ? "Wstrzymana" : "Paused",
        PrinterState.Finished => polish ? "Zakończono" : "Finished",
        PrinterState.Error => polish ? "Błąd" : "Error",
        PrinterState.Offline => polish ? "Offline" : "Offline",
        _ => "—"
    };

    /// <summary>Accent colour (hex, no #) used on the printer card, mirroring the macOS symbols.</summary>
    public static string AccentHex(this PrinterState state) => state switch
    {
        PrinterState.Idle => "30D158",
        PrinterState.Printing => "0A84FF",
        PrinterState.Paused => "FF9F0A",
        PrinterState.Finished => "30D158",
        PrinterState.Error => "FF453A",
        PrinterState.Offline => "8E8E93",
        _ => "8E8E93"
    };
}

/// <summary>Live telemetry for one printer. Reference type so incremental MQTT updates merge in place.</summary>
public sealed class PrinterTelemetry
{
    public PrinterState State { get; set; } = PrinterState.Offline;
    public int Progress { get; set; }
    public int? RemainingMinutes { get; set; }
    public double? NozzleTemperature { get; set; }
    public double? NozzleTargetTemperature { get; set; }
    // Second nozzle on dual-nozzle printers (H2D); null on single-nozzle machines.
    public double? NozzleTemperature2 { get; set; }
    public double? NozzleTargetTemperature2 { get; set; }
    public double? BedTemperature { get; set; }
    public double? BedTargetTemperature { get; set; }
    public double? ChamberTemperature { get; set; }
    /// <summary>Only machines with a heated chamber (H2D) report a setpoint.</summary>
    public double? ChamberTargetTemperature { get; set; }
    public int? CurrentLayer { get; set; }
    public int? TotalLayers { get; set; }
    // Cooling fans as a percentage (Bambu 0-15 gear normalised, or Moonraker 0-1). Aux = big_fan1,
    // chamber = big_fan2.
    public int? PartFanPercent { get; set; }
    public int? AuxFanPercent { get; set; }
    public int? ChamberFanPercent { get; set; }
    public int? SpeedLevel { get; set; }     // Bambu spd_lvl: 1 Silent, 2 Standard, 3 Sport, 4 Ludicrous
    public int? SpeedPercent { get; set; }   // Bambu spd_mag or Moonraker speed_factor
    public double? NozzleDiameter { get; set; }
    public int? CurrentStage { get; set; }
    public string? JobName { get; set; }
    // Klipper measured filament (mm) + Bambu current print file — sources for spool decrement on finish.
    public double? FilamentUsedMM { get; set; }
    public string? GcodeFile { get; set; }
    public ulong ErrorCode { get; set; }
    public List<string> HmsCodes { get; set; } = new();
    // Physical filament modules (AMS / AMS HT / CFS / MMU / external). Primary source for the
    // dashboard; AmsSlots stays as a flat compatibility view for notifications / the tray.
    public List<FilamentGroup> FilamentGroups { get; set; } = new();
    // One entry for a single-nozzle machine, two (Left/Right) for dual-nozzle printers like the H2D.
    public List<NozzleTelemetry> Nozzles { get; set; } = new();
    public List<AmsSlot> AmsSlots { get; set; } = new();
    public int? AmsHumidity { get; set; }
    public double? AmsTemperature { get; set; }
    public DateTime? LastUpdated { get; set; }

    public PrinterTelemetry Clone()
    {
        return new PrinterTelemetry
        {
            State = State,
            Progress = Progress,
            RemainingMinutes = RemainingMinutes,
            NozzleTemperature = NozzleTemperature,
            NozzleTargetTemperature = NozzleTargetTemperature,
            NozzleTemperature2 = NozzleTemperature2,
            NozzleTargetTemperature2 = NozzleTargetTemperature2,
            BedTemperature = BedTemperature,
            BedTargetTemperature = BedTargetTemperature,
            ChamberTemperature = ChamberTemperature,
            ChamberTargetTemperature = ChamberTargetTemperature,
            CurrentLayer = CurrentLayer,
            TotalLayers = TotalLayers,
            PartFanPercent = PartFanPercent,
            AuxFanPercent = AuxFanPercent,
            ChamberFanPercent = ChamberFanPercent,
            SpeedLevel = SpeedLevel,
            SpeedPercent = SpeedPercent,
            NozzleDiameter = NozzleDiameter,
            CurrentStage = CurrentStage,
            JobName = JobName,
            FilamentUsedMM = FilamentUsedMM,
            GcodeFile = GcodeFile,
            ErrorCode = ErrorCode,
            HmsCodes = new List<string>(HmsCodes),
            FilamentGroups = FilamentGroups.Select(g => g.Clone()).ToList(),
            Nozzles = Nozzles.Select(n => n.Clone()).ToList(),
            AmsSlots = AmsSlots.Select(s => s.Clone()).ToList(),
            AmsHumidity = AmsHumidity,
            AmsTemperature = AmsTemperature,
            LastUpdated = LastUpdated
        };
    }
}

/// One point in a printer's rolling temperature history, drawn by the detail window's graph.
public readonly record struct TemperatureSample(DateTime Time, double? Nozzle, double? Bed, double? Chamber);

public sealed class AmsSlot
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Material { get; set; } = "";
    public string ColorHex { get; set; } = "8E8E93FF";
    public int? RemainingPercent { get; set; }
    public bool IsActive { get; set; }
    public bool IsExternal { get; set; }
    /// <summary>RFID/NFC remaining weight (grams); null for a chipless spool whose RemainingPercent is
    /// not trustworthy - used to suppress false "low filament" warnings (issue #27).</summary>
    public double? RemainingWeightGrams { get; set; }

    public AmsSlot Clone() => (AmsSlot)MemberwiseClone();
}

/// <summary>Which physical filament system a group came from.</summary>
public enum FilamentSourceType { Ams, AmsHT, Cfs, Mmu, External, Canvas }

/// <summary>One physical filament module and its slots. Empty slots stay so the layout never
/// collapses when a spool is removed.</summary>
public sealed class FilamentGroup
{
    public string Id { get; set; } = "";
    public FilamentSourceType SourceType { get; set; }
    public string DisplayName { get; set; } = "";   // AMS A, AMS HT, CFS 1, MMU, EXT
    public int DeclaredCapacity { get; set; }        // 1, 4 or a dynamic gate count
    public int? HumidityPercent { get; set; }        // per-module, null when the firmware omits it
    public double? TemperatureCelsius { get; set; }
    public bool IsExternal { get; set; }
    public List<FilamentSlot> Slots { get; set; } = new();

    public FilamentGroup Clone() => new()
    {
        Id = Id,
        SourceType = SourceType,
        DisplayName = DisplayName,
        DeclaredCapacity = DeclaredCapacity,
        HumidityPercent = HumidityPercent,
        TemperatureCelsius = TemperatureCelsius,
        IsExternal = IsExternal,
        Slots = Slots.Select(s => s.Clone()).ToList()
    };

    /// <summary>Flatten to the legacy AmsSlot list still used by notifications / the tray.</summary>
    public IEnumerable<AmsSlot> LegacyAmsSlots() => Slots.Select(s => new AmsSlot
    {
        Id = s.Id,
        Label = s.Label,
        Material = s.IsPresent ? (s.Material ?? "—") : "—",
        ColorHex = s.ColorHex ?? "8E8E93FF",
        RemainingPercent = s.RemainingPercent,
        IsActive = s.IsActive,
        IsExternal = IsExternal,
        RemainingWeightGrams = s.RemainingWeightGrams
    });
}

public sealed class FilamentSlot
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";      // A1, B3, T6, EXT
    public string? Material { get; set; }         // null / empty => empty slot
    public string? ColorHex { get; set; }
    public int? RemainingPercent { get; set; }
    public bool IsActive { get; set; }
    /// <summary>Remaining grams from the AMS NFC/RFID tag (tray_weight × remain), when known.</summary>
    public double? RemainingWeightGrams { get; set; }

    public bool IsPresent => !string.IsNullOrEmpty(Material) && Material != "—";

    public FilamentSlot Clone() => (FilamentSlot)MemberwiseClone();
}

public enum NozzlePosition { Single, Left, Right }

public sealed class NozzleTelemetry
{
    public NozzlePosition Position { get; set; }
    public double? CurrentTemperature { get; set; }
    public double? TargetTemperature { get; set; }

    public NozzleTelemetry Clone() => (NozzleTelemetry)MemberwiseClone();
}

public enum PrinterKind
{
    Bambu,
    Klipper,
    Prusa,
    Snapmaker,
    ElegooCc1,
    ElegooCc2,
    AnycubicKobraS1
}

public sealed class SavedPrinter
{
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "Bambu Lab";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    // Missing in printers saved before Klipper support → defaults to Bambu.
    [JsonPropertyName("kind")] public PrinterKind Kind { get; set; } = PrinterKind.Bambu;
    [JsonPropertyName("port")] public int? Port { get; set; }
    [JsonPropertyName("apiKey")] public string? ApiKey { get; set; }
}

/// <summary>A live connection to one printer (MqttClient for Bambu, MoonrakerClient for Klipper).</summary>
public interface IPrinterConnection
{
    void Start();
    void Stop();
}

public sealed class DiscoveredPrinter
{
    public string Serial { get; set; } = "";
    public string Name { get; set; } = "";
    public string Model { get; set; } = "Bambu Lab";
    public string Host { get; set; } = "";
    public PrinterKind Kind { get; set; } = PrinterKind.Bambu;
}
