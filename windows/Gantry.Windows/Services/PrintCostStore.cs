using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Where the print cost settings are kept: the app's defaults, same key and JSON as macOS.</summary>
public sealed partial class PrintCostSettings
{
    private const string Key = "print-cost-settings-v1";

    /// <summary>Bumped on every save, so a view that caches what it drew can tell the prices moved.</summary>
    public static int Version { get; private set; }

    public static PrintCostSettings Current
    {
        get
        {
            var raw = Defaults.GetRaw(Key);
            if (raw is null) return new PrintCostSettings();
            try { return FromJson(raw); }
            catch { return new PrintCostSettings(); }
        }
        set { Defaults.SetRaw(Key, JsonSerializer.Serialize(value)); Version++; }
    }
}

public sealed partial record PrintCost
{
    /// <summary>Filament the print used, from Spoolbase's per-print usage records written for this
    /// printer while it ran (a short grace after the end covers a late FINISH packet).</summary>
    public static List<Use> Uses(string serial, DateTime startedAt, DateTime endedAt)
    {
        var spools = SpoolbaseShared.Spools;
        var filaments = SpoolbaseShared.Filaments.Filaments;
        DateTime from = startedAt.ToUniversalTime().AddMinutes(-1), to = endedAt.ToUniversalTime().AddMinutes(10);
        var uses = new List<Use>();
        foreach (var usage in spools.UsageEvents)
        {
            var at = usage.Timestamp.Kind == DateTimeKind.Local ? usage.Timestamp.ToUniversalTime() : usage.Timestamp;
            if (usage.PrinterSerial != serial || at < from || at > to) continue;
            var spool = spools.Spools.FirstOrDefault(value => value.Id == usage.SpoolId);
            var definition = spool is null ? null : filaments.FirstOrDefault(value => value.Id == spool.FilamentDefinitionId);
            double? perKg = null;
            if (spool?.Price is { } price && price >= 0 && spool.NominalWeightGrams > 0)
                perKg = price / spool.NominalWeightGrams * 1000;
            else if (definition?.PricePerRoll is { } productPrice && spool is { NominalWeightGrams: > 0 })
                perKg = productPrice / spool.NominalWeightGrams * 1000;
            uses.Add(new Use(usage.ConsumedGrams, definition?.Type, perKg));
        }
        return uses;
    }
}
