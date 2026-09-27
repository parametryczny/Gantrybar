using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>
/// The user's prices for turning a print into money: filament per kilogram (optionally per material),
/// electricity per kWh with each printer's average draw, and machine time per hour. Same JSON as macOS
/// (<c>print-cost-settings-v1</c>); every field has a default, so a partial value still loads.
/// </summary>
public sealed class PrintCostSettings
{
    private const string Key = "print-cost-settings-v1";

    [JsonPropertyName("currency")] public string Currency { get; set; } = "PLN";
    [JsonPropertyName("filamentPerKg")] public double FilamentPerKg { get; set; } = 80;
    [JsonPropertyName("materialPerKg")] public Dictionary<string, double> MaterialPerKg { get; set; } = new();
    [JsonPropertyName("electricityPerKWh")] public double ElectricityPerKWh { get; set; } = 1.0;
    [JsonPropertyName("printerWatts")] public double PrinterWatts { get; set; } = 150;
    [JsonPropertyName("watts")] public Dictionary<string, double> Watts { get; set; } = new();
    [JsonPropertyName("machinePerHour")] public double MachinePerHour { get; set; }

    public double PricePerKg(string? material)
    {
        string key = (material ?? "").Trim().ToUpperInvariant();
        return MaterialPerKg.TryGetValue(key, out var price) ? price : FilamentPerKg;
    }

    public double Power(string serial) => Watts.TryGetValue(serial, out var watts) ? watts : PrinterWatts;

    public static PrintCostSettings Current
    {
        get
        {
            var raw = Defaults.GetRaw(Key);
            if (raw is null) return new PrintCostSettings();
            try
            {
                var value = JsonSerializer.Deserialize<PrintCostSettings>(raw) ?? new PrintCostSettings();
                value.MaterialPerKg ??= new();
                value.Watts ??= new();
                value.Currency = string.IsNullOrWhiteSpace(value.Currency) ? "PLN" : value.Currency;
                return value;
            }
            catch { return new PrintCostSettings(); }
        }
        set => Defaults.SetRaw(Key, JsonSerializer.Serialize(value));
    }

    /// <summary>"PETG=90, ASA=119,50; TPU = 140" → PETG 90, ASA 119.5, TPU 140.</summary>
    public static Dictionary<string, double> ParseMaterialPrices(string text)
    {
        var result = new Dictionary<string, double>();
        foreach (Match match in Regex.Matches(text ?? "", @"([A-Za-z][A-Za-z0-9+\-]*)\s*=\s*([0-9]+(?:[.,][0-9]+)?)"))
        {
            if (double.TryParse(match.Groups[2].Value.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var price))
                result[match.Groups[1].Value.ToUpperInvariant()] = price;
        }
        return result;
    }

    public static double? ParseAmount(string text)
    {
        string clean = (text ?? "").Trim().Replace(',', '.');
        return double.TryParse(clean, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && value >= 0 ? value : null;
    }
}

/// <summary>One print's cost, split so the user can see where the money went. Mirrors macOS PrintCost.</summary>
public sealed record PrintCost(double? Filament, double? Grams, double Energy, double Machine, double KWh)
{
    public double Total => (Filament ?? 0) + Energy + Machine;

    public sealed record Use(double Grams, string? Material, double? PricePerKg = null);

    public static PrintCost Compute(double durationSeconds, IReadOnlyList<Use> uses, string serial, PrintCostSettings settings)
    {
        double hours = Math.Max(0, durationSeconds) / 3600;
        double kWh = hours * Math.Max(0, settings.Power(serial)) / 1000;
        double? grams = uses.Count == 0 ? null : uses.Sum(use => Math.Max(0, use.Grams));
        double? filament = uses.Count == 0 ? null
            : uses.Sum(use => Math.Max(0, use.Grams) / 1000 * Math.Max(0, use.PricePerKg ?? settings.PricePerKg(use.Material)));
        return new PrintCost(filament, grams, kWh * Math.Max(0, settings.ElectricityPerKWh),
                             hours * Math.Max(0, settings.MachinePerHour), kWh);
    }

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
