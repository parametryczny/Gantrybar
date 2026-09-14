using System;
using System.Collections.Generic;
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
    private const string SessionsKey = "spoolbase-print-sessions";
    private static PrintJobSessions? _sessions;
    private static PrintJobSessions Sessions => _sessions ??= PrintJobSessions.FromJson(Defaults.GetRaw(SessionsKey));

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

    /// <summary>Called on every telemetry update; acts only on the finish of a print session. With
    /// Spoolbase switched off nothing is subtracted, and nothing is remembered as subtracted either.
    /// Sessions are still followed, so a print that started before the switch has the right identity
    /// when it ends.</summary>
    public static void OnUpdate(SavedPrinter printer, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        var phase = current.State switch
        {
            PrinterState.Printing or PrinterState.Paused => JobPhase.Running,
            PrinterState.Finished => JobPhase.Finished,
            _ => JobPhase.Other
        };
        var (job, changed) = Sessions.Observe(printer.Serial, previous?.State == PrinterState.Finished, phase,
                                              current.JobName, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        if (changed) Defaults.SetRaw(SessionsKey, Sessions.ToJson());
        if (job is null || !AppSettings.SpoolbaseEnabled) return;
        switch (printer.Kind)
        {
            case PrinterKind.Klipper: ConsumeKlipper(printer, current, job); break;
            case PrinterKind.Bambu: ConsumeBambu(printer, current, job); break;
        }
    }

    private static List<SlotRef> Slots(List<FilamentGroup> groups)
    {
        var slots = new List<SlotRef>();
        for (int gi = 0; gi < groups.Count; gi++)
            for (int si = 0; si < groups[gi].Slots.Count; si++)
            {
                var slot = groups[gi].Slots[si];
                slots.Add(new SlotRef(gi, si, groups[gi].IsExternal, slot.IsActive, slot.IsPresent, slot.ColorHex));
            }
        return slots;
    }

    private static SpoolLocation Location(string serial, SlotRef slot) =>
        SpoolLocation.At(serial, slot.External ? SpoolFeeder.Ext : SpoolFeeder.Ams, slot.Group, slot.Slot);

    /// <summary>Klipper single-extruder: the measured length comes off the roll in the slot the print
    /// came from.</summary>
    private static void ConsumeKlipper(SavedPrinter printer, PrinterTelemetry t, string job)
    {
        if (t.FilamentUsedMM is not { } usedMM || usedMM <= 0) return;
        var spools = SpoolbaseShared.Spools;
        if (SpoolAccounting.LoadedSlot(Slots(t.FilamentGroups), s => spools.SpoolAt(Location(printer.Serial, s)) is not null) is not { } loaded)
            return;
        if (spools.SpoolAt(Location(printer.Serial, loaded)) is not { } spool) return;
        var material = t.FilamentGroups[loaded.Group].Slots[loaded.Slot].Material;
        spools.Consume(spool.Id, Grams(usedMM, material), printer.Serial, job);
    }

    private static void ConsumeBambu(SavedPrinter printer, PrinterTelemetry t, string job)
    {
        if (string.IsNullOrEmpty(t.GcodeFile)) return;
        var code = AccessCodeStore.AccessCode(printer.Serial);
        if (string.IsNullOrEmpty(code)) return;
        string host = printer.Host, serial = printer.Serial, file = t.GcodeFile!;
        var slots = Slots(t.FilamentGroups);
        // The rolls are read now, at the finish. Looked up after the download, a roll swapped in while the
        // file was still coming over was charged for the print that had just come off the old one.
        var assigned = new Dictionary<SlotRef, string>();
        foreach (var slot in slots)
            if (SpoolbaseShared.Spools.SpoolAt(Location(serial, slot)) is { } spool) assigned[slot] = spool.Id;
        if (assigned.Count == 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                var data = await new BambuFileClient(host, code).FetchAsync(file);
                var filaments = ThreeMFReader.Filaments(data)
                    .Select(f => (Id: f.Id.ToString(), UsedGrams: f.UsedGrams, ColorHex: f.ColorHex ?? ""))
                    .ToList();
                System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                {
                    // Spoolbase switched off during the download: the print is not accounted.
                    if (!AppSettings.SpoolbaseEnabled) return;
                    foreach (var charge in SpoolAccounting.BambuCharges(slots, filaments, s => assigned.TryGetValue(s, out var id) ? id : null))
                        SpoolbaseShared.Spools.Consume(charge.SpoolId, charge.Grams, serial, $"{job}#{charge.FilamentId}");
                });
            }
            catch (Exception e)
            {
                System.Diagnostics.Debug.WriteLine($"Spoolbase: 3mf fetch/parse failed for {serial} ({file}): {e.Message}");
            }
        });
    }
}
