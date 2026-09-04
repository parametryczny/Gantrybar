using System;
using System.Linq;
using System.Threading.Tasks;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Turns a finished print into a spool decrement. Subtract on FINISH only, never on start;
/// cancelled/failed do not auto-subtract; idempotent per print job. Klipper uses measured
/// <c>filament_used</c>; Bambu reads the slicer's <c>used_g</c> from the printed 3mf over local FTPS.</summary>
public static class FilamentConsumption
{
    private const double FilamentDiameterMM = 1.75;

    public static double Density(string? material)
    {
        var m = (material ?? "").ToUpperInvariant();
        if (m.Contains("PETG")) return 1.27;
        if (m.Contains("ABS")) return 1.04;
        if (m.Contains("ASA")) return 1.07;
        if (m.Contains("TPU")) return 1.21;
        if (m.Contains("PVA")) return 1.23;
        if (m.Contains("PC")) return 1.20;
        if (m.StartsWith("PA")) return 1.14;
        if (m.Contains("PLA")) return 1.24;
        return 1.24;
    }

    public static double Grams(double lengthMM, string? material)
    {
        double area = Math.PI * (FilamentDiameterMM / 2) * (FilamentDiameterMM / 2);
        return lengthMM * area / 1000 * Density(material);
    }

    private static string JobId(string serial, PrinterTelemetry t) =>
        $"{serial}|{t.JobName ?? "?"}|{DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 3600}";

    /// <summary>With Spoolbase switched off nothing is subtracted, and nothing is remembered as
    /// subtracted either: prints finished while the feature was off never happened as far as the rolls
    /// are concerned. Switching it back on resumes from the grams the rolls had when it went off.</summary>
    public static void OnUpdate(SavedPrinter printer, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        if (!AppSettings.SpoolbaseEnabled) return;
        if (previous?.State == PrinterState.Finished || current.State != PrinterState.Finished) return;
        switch (printer.Kind)
        {
            case PrinterKind.Klipper: ConsumeKlipper(printer, current); break;
            case PrinterKind.Bambu: ConsumeBambu(printer, current); break;
        }
    }

    private static void ConsumeKlipper(SavedPrinter printer, PrinterTelemetry t)
    {
        if (t.FilamentUsedMM is not { } usedMM || usedMM <= 0) return;
        var loc = LoadedLocation(printer.Serial, t);
        if (loc is null) return;
        var spool = SpoolbaseShared.Spools.SpoolAt(loc);
        if (spool is null) return;
        var material = LoadedSlot(t)?.Material;
        SpoolbaseShared.Spools.Consume(spool.Id, Grams(usedMM, material), printer.Serial, JobId(printer.Serial, t));
    }

    private static void ConsumeBambu(SavedPrinter printer, PrinterTelemetry t)
    {
        if (string.IsNullOrEmpty(t.GcodeFile)) return;
        var code = AccessCodeStore.AccessCode(printer.Serial);
        if (string.IsNullOrEmpty(code)) return;
        string host = printer.Host, serial = printer.Serial, file = t.GcodeFile!;
        var groups = t.FilamentGroups.Select(g => g.Clone()).ToList();
        string job = JobId(serial, t);
        _ = Task.Run(async () =>
        {
            try
            {
                var data = await new BambuFileClient(host, code).FetchAsync(file);
                var filaments = ThreeMFReader.Filaments(data);
                System.Windows.Application.Current?.Dispatcher.Invoke(() => ApplyBambu(serial, groups, filaments, job));
            }
            catch (Exception e)
            {
                System.Diagnostics.Debug.WriteLine($"Spoolbase: 3mf fetch/parse failed for {serial} ({file}): {e.Message}");
            }
        });
    }

    private static void ApplyBambu(string serial, System.Collections.Generic.List<FilamentGroup> groups,
                                   System.Collections.Generic.List<SlicedFilament> filaments, string job)
    {
        SpoolLocation? ByColor(string colorHex)
        {
            for (int gi = 0; gi < groups.Count; gi++)
                for (int si = 0; si < groups[gi].Slots.Count; si++)
                {
                    var slotHex = (groups[gi].Slots[si].ColorHex ?? "").Replace("#", "").ToUpperInvariant();
                    if (slotHex.Length >= 6) slotHex = slotHex.Substring(0, 6);
                    if (colorHex.Length > 0 && slotHex == colorHex)
                        return SpoolLocation.At(serial, groups[gi].IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, gi, si);
                }
            return null;
        }
        foreach (var fil in filaments.Where(f => f.UsedGrams > 0))
        {
            var loc = ByColor(fil.ColorHex) ?? (filaments.Count == 1 ? LoadedLocationFromGroups(serial, groups) : null);
            if (loc is null) continue;
            var spool = SpoolbaseShared.Spools.SpoolAt(loc);
            if (spool is null) continue;
            SpoolbaseShared.Spools.Consume(spool.Id, fil.UsedGrams, serial, $"{job}#{fil.Id}");
        }
    }

    private static FilamentSlot? LoadedSlot(PrinterTelemetry t) =>
        t.FilamentGroups.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsActive)
        ?? t.FilamentGroups.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsPresent);

    private static SpoolLocation? LoadedLocation(string serial, PrinterTelemetry t) =>
        LoadedLocationFromGroups(serial, t.FilamentGroups);

    private static SpoolLocation? LoadedLocationFromGroups(string serial, System.Collections.Generic.List<FilamentGroup> groups)
    {
        for (int gi = 0; gi < groups.Count; gi++)
        {
            int si = groups[gi].Slots.FindIndex(s => s.IsActive);
            if (si < 0) si = groups[gi].Slots.FindIndex(s => s.IsPresent);
            if (si >= 0) return SpoolLocation.At(serial, groups[gi].IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, gi, si);
        }
        return null;
    }
}
