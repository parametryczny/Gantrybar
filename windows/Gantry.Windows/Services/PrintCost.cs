using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Gantry.Services;

/// <summary>
/// The user's prices for turning a print into money: filament per kilogram (optionally per material),
/// electricity per kWh with each printer's average draw, and machine time per hour. Same JSON as macOS
/// (<c>print-cost-settings-v1</c>); every field has a default, so a partial value still loads.
/// Free of app state so the test project can compile it; loading and saving live in PrintCostStore.cs.
/// </summary>
public sealed partial class PrintCostSettings
{
    [JsonPropertyName("currency")] public string Currency { get; set; } = "PLN";
    [JsonPropertyName("filamentPerKg")] public double FilamentPerKg { get; set; } = 80;
    [JsonPropertyName("materialPerKg")] public Dictionary<string, double> MaterialPerKg { get; set; } = new();
    [JsonPropertyName("electricityPerKWh")] public double ElectricityPerKWh { get; set; } = 1.0;
    [JsonPropertyName("printerWatts")] public double PrinterWatts { get; set; } = 150;
    [JsonPropertyName("watts")] public Dictionary<string, double> Watts { get; set; } = new();
    [JsonPropertyName("machinePerHour")] public double MachinePerHour { get; set; }

    // Selling: how the seller is set up and what goes on top of the print's cost (Settings → Pricing).

    /// <summary>"unregistered" (działalność nierejestrowana: no VAT), "company" (VAT-exempt) or
    /// "companyVAT" (charges VAT). Kept as the macOS raw value so the JSON stays shared; an unknown
    /// value reads as unregistered.</summary>
    [JsonPropertyName("business")] public string BusinessRaw { get; set; } = "unregistered";
    /// <summary>Income tax in percent, from the profit or, with <see cref="TaxOnRevenue"/>, from the
    /// revenue (the Polish lump-sum "ryczałt").</summary>
    [JsonPropertyName("incomeTaxPercent")] public double IncomeTaxPercent { get; set; } = 12;
    [JsonPropertyName("taxOnRevenue")] public bool TaxOnRevenue { get; set; }
    [JsonPropertyName("vatPercent")] public double VatPercent { get; set; } = 23;
    /// <summary>Mark-up on everything it costs to make and ship one print.</summary>
    [JsonPropertyName("marginPercent")] public double MarginPercent { get; set; } = 30;
    /// <summary>A marketplace's cut of the gross price (Allegro, Etsy).</summary>
    [JsonPropertyName("platformFeePercent")] public double PlatformFeePercent { get; set; }
    /// <summary>Hands-on time per print and what that hour is worth.</summary>
    [JsonPropertyName("laborPerHour")] public double LaborPerHour { get; set; }
    [JsonPropertyName("laborMinutes")] public double LaborMinutes { get; set; } = 10;
    /// <summary>Box, filler and label per order.</summary>
    [JsonPropertyName("packaging")] public double Packaging { get; set; }
    /// <summary>Extra material and machine time set aside for prints that fail, in percent.</summary>
    [JsonPropertyName("failurePercent")] public double FailurePercent { get; set; } = 5;

    public enum BusinessKind { Unregistered, Company, CompanyVAT }

    /// <summary>In the order the Pricing pane lists them, same as macOS.</summary>
    public static readonly BusinessKind[] BusinessKinds = { BusinessKind.Unregistered, BusinessKind.Company, BusinessKind.CompanyVAT };

    [JsonIgnore]
    public BusinessKind Business
    {
        get => BusinessRaw switch
        {
            "company" => BusinessKind.Company,
            "companyVAT" => BusinessKind.CompanyVAT,
            _ => BusinessKind.Unregistered,
        };
        set => BusinessRaw = value switch
        {
            BusinessKind.Company => "company",
            BusinessKind.CompanyVAT => "companyVAT",
            _ => "unregistered",
        };
    }

    public static PrintCostSettings FromJson(string raw)
    {
        var value = JsonSerializer.Deserialize<PrintCostSettings>(raw) ?? new PrintCostSettings();
        value.MaterialPerKg ??= new();
        value.Watts ??= new();
        value.BusinessRaw ??= "unregistered";
        value.Currency = string.IsNullOrWhiteSpace(value.Currency) ? "PLN" : value.Currency;
        return value;
    }

    public double PricePerKg(string? material)
    {
        string key = (material ?? "").Trim().ToUpperInvariant();
        return MaterialPerKg.TryGetValue(key, out var price) ? price : FilamentPerKg;
    }

    public double Power(string serial) => Watts.TryGetValue(serial, out var watts) ? watts : PrinterWatts;

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
public sealed partial record PrintCost(double? Filament, double? Grams, double Energy, double Machine, double KWh)
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
}

/// <summary>
/// What a print should sell for, built up from what it cost. Mirrors macOS SaleQuote.
///
/// Costs first: the print itself (filament, electricity, machine time), an allowance for prints that
/// fail, the hands-on work and the packaging. The mark-up is the profit wanted on top of those, after
/// tax. The price is then solved so that, once the marketplace has taken its cut and the tax office
/// its share, exactly that profit is left; VAT, when charged, goes on top.
///
///     income tax on profit:     net = (costs + profit / (1 − tax)) / (1 − fee)
///     tax on revenue (ryczałt): net = (costs + profit) / (1 − fee − tax)
///     gross = net × (1 + VAT)
///
/// The marketplace fee is charged on the gross price, which is how Allegro and Etsy bill it.
/// An estimate for pricing, not tax advice.
/// </summary>
public sealed record SaleQuote(double Print, double Failures, double Labor, double Packaging,
                               double Profit, double Fee, double Tax, double Vat,
                               double Net, double Gross, bool Complete)
{
    public double Costs => Print + Failures + Labor + Packaging;

    public static SaleQuote Compute(PrintCost cost, PrintCostSettings s)
    {
        double print = cost.Total;
        double failures = print * Math.Max(0, s.FailurePercent) / 100;
        double labor = Math.Max(0, s.LaborPerHour) * Math.Max(0, s.LaborMinutes) / 60;
        double packaging = Math.Max(0, s.Packaging);
        double costs = print + failures + labor + packaging;
        double profit = costs * Math.Max(0, s.MarginPercent) / 100;
        double vatRate = s.Business == PrintCostSettings.BusinessKind.CompanyVAT ? Math.Max(0, s.VatPercent) / 100 : 0;
        double taxRate = Math.Min(0.9, Math.Max(0, s.IncomeTaxPercent) / 100);
        // The fee is a share of the gross price; as a share of the net it is that times (1 + VAT).
        double feeRate = Math.Min(0.9, Math.Max(0, s.PlatformFeePercent) / 100);
        double net = s.TaxOnRevenue
            ? (costs + profit) / Math.Max(0.05, 1 - feeRate - taxRate)
            : (costs + profit / Math.Max(0.05, 1 - taxRate)) / Math.Max(0.05, 1 - feeRate);
        double gross = net * (1 + vatRate);
        double fee = gross * feeRate / (1 + vatRate);
        double tax = s.TaxOnRevenue ? net * taxRate : Math.Max(0, net - fee - costs) * taxRate;
        return new SaleQuote(print, failures, labor, packaging, profit, fee, tax, gross - net, net, gross,
                             cost.Filament is not null);
    }
}
