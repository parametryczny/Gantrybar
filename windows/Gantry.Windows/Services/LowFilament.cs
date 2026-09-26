using System;
using System.Collections.Generic;
using System.Linq;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Which loaded rolls are running low, and which roll ran out (port of LowFilament.swift).
/// Two sources Gantry can trust: a roll assigned in Spoolbase, whose grams Gantry counts down itself,
/// and otherwise a Bambu roll with an RFID/NFC tag, whose percentage comes from the printer. A chipless
/// roll without a Spoolbase assignment has no reliable level and is never reported (issue #27).</summary>
public static class LowFilament
{
    /// <summary>A tagged roll at or below this share of its weight is low.</summary>
    public const int PercentThreshold = 15;
    /// <summary>A Spoolbase roll at or below this many grams is low.</summary>
    public const double GramsThreshold = 100;
    /// <summary>Bambu print stage 6: paused because the filament ran out.</summary>
    public const int RunoutStage = 6;

    /// <param name="Key">Unit index and slot index, stable within one printer.</param>
    /// <param name="Amount">"12%" for a tagged roll, "85 g" for a Spoolbase roll.</param>
    public sealed record Slot(string Key, string Label, string Material, string Amount)
    {
        public string Describe() => string.Join(" • ", new[] { Label, Material, Amount }.Where(p => !string.IsNullOrEmpty(p)));
    }

    public static List<Slot> LowSlots(string serial, IReadOnlyList<FilamentGroup> groups,
                                      Func<SpoolLocation, PhysicalSpool?> assignedSpool)
    {
        var result = new List<Slot>();
        for (int g = 0; g < groups.Count; g++)
        {
            var group = groups[g];
            for (int s = 0; s < group.Slots.Count; s++)
            {
                var slot = group.Slots[s];
                string key = $"{g}-{s}";
                var spool = assignedSpool(SpoolLocation.At(serial, group.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, g, s));
                // Spoolbase first: an assignment is the user's own record of the roll and outranks the tag.
                if (spool is not null)
                {
                    if (spool.RemainingWeightGrams <= GramsThreshold)
                        result.Add(new Slot(key, slot.Label, slot.IsPresent ? slot.Material ?? spool.Id : spool.Id,
                            $"{(int)Math.Round(spool.RemainingWeightGrams, MidpointRounding.AwayFromZero)} g"));
                    continue;
                }
                if (slot.IsPresent && slot.RemainingWeightGrams is not null
                    && slot.RemainingPercent is int percent && percent <= PercentThreshold)
                    result.Add(new Slot(key, slot.Label, slot.Material ?? "", $"{percent}%"));
            }
        }
        return result;
    }

    /// <summary>The roll that was feeding when the printer stopped: the active slot of the last report
    /// that had one, because the report that carries the pause may already have cleared it.</summary>
    public static FilamentSlot? FeedingSlot(IReadOnlyList<FilamentGroup>? previous, IReadOnlyList<FilamentGroup> current) =>
        current.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsActive)
        ?? previous?.SelectMany(g => g.Slots).FirstOrDefault(s => s.IsActive);
}
