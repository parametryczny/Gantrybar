using System;
using System.Text.Json.Serialization;

namespace Gantry.Models;

/// <summary>
/// A concrete physical roll of filament (vs <see cref="Filament"/>, the product definition). State
/// belongs to the spool, not the AMS slot. JSON keys mirror the macOS/Swift model so spools-v1.json is
/// shared across platforms. See design spec + spoolbase-physical-spools.
/// </summary>
public sealed class PhysicalSpool
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";                       // "SP-00001"
    [JsonPropertyName("filamentDefinitionID")] public Guid FilamentDefinitionId { get; set; }
    [JsonPropertyName("nominalWeightGrams")] public double NominalWeightGrams { get; set; } = 1000;
    [JsonPropertyName("remainingWeightGrams")] public double RemainingWeightGrams { get; set; } = 1000;
    [JsonPropertyName("status")] public SpoolStatus Status { get; set; } = SpoolStatus.New;
    [JsonPropertyName("location")] public SpoolLocation Location { get; set; } = new();
    [JsonPropertyName("notes")] public string Notes { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("updatedAt")] public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("openedAt")] public DateTime? OpenedAt { get; set; }
    [JsonPropertyName("emptiedAt")] public DateTime? EmptiedAt { get; set; }
    [JsonPropertyName("lastUsedAt")] public DateTime? LastUsedAt { get; set; }
    [JsonPropertyName("totalConsumedGrams")] public double TotalConsumedGrams { get; set; }
    // Manual weighing (spec §5): when last weighed, and the empty-spool tare (so a gross reading can be
    // turned into net filament). Both nullable; unset until first weighed.
    [JsonPropertyName("weighedAt")] public DateTime? WeighedAt { get; set; }
    [JsonPropertyName("tareGrams")] public double? TareGrams { get; set; }

    /// <summary>Locally computed fill level (no RFID). Never pushed back to firmware.</summary>
    [JsonIgnore]
    public int Percent => NominalWeightGrams > 0
        ? (int)Math.Round(RemainingWeightGrams / NominalWeightGrams * 100)
        : 0;
}

public enum SpoolStatus { New, Active, Stored, Empty, Archived }

/// <summary>Where a spool currently sits. <c>PrinterSerial == null</c> means storage. General enough for
/// AMS and the external feeder (EXT).</summary>
public sealed class SpoolLocation
{
    [JsonPropertyName("printerSerial")] public string? PrinterSerial { get; set; }
    [JsonPropertyName("feeder")] public SpoolFeeder? Feeder { get; set; }
    [JsonPropertyName("amsIndex")] public int? AmsIndex { get; set; }
    [JsonPropertyName("slot")] public int? Slot { get; set; }

    [JsonIgnore] public bool IsStorage => string.IsNullOrEmpty(PrinterSerial);

    public bool SameSlot(SpoolLocation other) =>
        !IsStorage && PrinterSerial == other.PrinterSerial && Feeder == other.Feeder
        && AmsIndex == other.AmsIndex && Slot == other.Slot;

    public static SpoolLocation Storage() => new();
    public static SpoolLocation At(string serial, SpoolFeeder feeder, int amsIndex, int slot) =>
        new() { PrinterSerial = serial, Feeder = feeder, AmsIndex = amsIndex, Slot = slot };
}

public enum SpoolFeeder { Ams, Ext }

/// <summary>One filament-consumption record, written once per finished print (idempotent on PrintJobId).</summary>
public sealed class SpoolUsageEvent
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("spoolID")] public string SpoolId { get; set; } = "";
    [JsonPropertyName("printerSerial")] public string PrinterSerial { get; set; } = "";
    [JsonPropertyName("printJobID")] public string PrintJobId { get; set; } = "";
    [JsonPropertyName("consumedGrams")] public double ConsumedGrams { get; set; }
    [JsonPropertyName("timestamp")] public DateTime Timestamp { get; set; } = DateTime.UtcNow;
}

/// <summary>One filament entry read from a Bambu .gcode.3mf slice_info.config (slicer-computed used_g).</summary>
public sealed class SlicedFilament
{
    public int Id { get; set; }
    public double UsedGrams { get; set; }
    public double UsedMeters { get; set; }
    public string Type { get; set; } = "";
    public string ColorHex { get; set; } = "";   // 6-hex, no '#'
}
