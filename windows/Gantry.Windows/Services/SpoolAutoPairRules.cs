using System;
using System.Collections.Generic;
using System.Linq;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>A Spoolbase product as the pairing sees it. Kept apart from <c>Filament</c>, which carries
/// WPF colour helpers, so the rules run in the plain test project too.</summary>
public sealed record PairProduct(Guid Id, string Brand, string Name, string Type, string ColorHex, double? PricePerRoll);

/// <summary>One pairing made: the roll, the product it was taken as (null when the tag was already
/// known and the roll only recognised), and the slot's name for the card.</summary>
public sealed record PairResult(string SpoolId, string? Product, string Slot);

/// <summary>
/// Pairs a Bambu RFID roll loaded in an AMS with its roll in Spoolbase, so what the print used is
/// charged to that roll and priced with what you paid for it, not with the slicer's price. Mirrors
/// the macOS SpoolAutoPair.
///
/// A roll with an RFID tag carries its own id. The first time a tag shows up, Gantry looks for the
/// product in Spoolbase (same material, closest colour, Bambu Lab first, the tag's product name
/// preferred) and takes a roll of it from storage, or adds one priced like that product. The tag is
/// kept on the roll, so the next time that roll goes into any slot of any printer it is recognised
/// straight away. A roll you assigned by hand to a slot is never replaced, and rolls without a tag
/// (third-party filament) are left for you to assign.
/// </summary>
public static class SpoolAutoPairRules
{
    /// <summary>The roll's RFID tag id from tray_uuid. A roll without a tag reports all zeros, which is
    /// no id at all.</summary>
    public static string? TagUid(string? trayUuid)
    {
        var raw = trayUuid?.Trim(' ', '\t');
        if (string.IsNullOrEmpty(raw) || raw.All(c => c == '0')) return null;
        return raw.ToUpperInvariant();
    }

    /// <summary>Filament groups differ in any field (the Swift array's ==).</summary>
    public static bool GroupsChanged(IReadOnlyList<FilamentGroup>? previous, IReadOnlyList<FilamentGroup> current)
    {
        if (previous is null || previous.Count != current.Count) return true;
        for (int i = 0; i < current.Count; i++)
        {
            var a = previous[i]; var b = current[i];
            if (a.Id != b.Id || a.SourceType != b.SourceType || a.DisplayName != b.DisplayName
                || a.DeclaredCapacity != b.DeclaredCapacity || a.HumidityPercent != b.HumidityPercent
                || a.TemperatureCelsius != b.TemperatureCelsius || a.IsExternal != b.IsExternal
                || a.Slots.Count != b.Slots.Count) return true;
            for (int s = 0; s < b.Slots.Count; s++)
                if (!a.Slots[s].SameAs(b.Slots[s])) return true;
        }
        return false;
    }

    /// <summary>Pairs every tagged, unpaired roll in these groups and returns one entry per pairing.</summary>
    public static List<PairResult> Pair(string serial, IReadOnlyList<FilamentGroup> groups,
                                        PhysicalSpoolStore store, IReadOnlyList<PairProduct> products)
    {
        var results = new List<PairResult>();
        for (int groupIndex = 0; groupIndex < groups.Count; groupIndex++)
        {
            var group = groups[groupIndex];
            for (int slotIndex = 0; slotIndex < group.Slots.Count; slotIndex++)
            {
                var slot = group.Slots[slotIndex];
                if (!slot.IsPresent || slot.SpoolUid is not { } uid) continue;
                var location = SpoolLocation.At(serial, group.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, groupIndex, slotIndex);
                var current = store.SpoolAt(location);
                if (current?.TagUid == uid) continue;
                // A roll assigned by hand stays: only an empty slot or one holding another tagged roll
                // (taken out and replaced) is paired again.
                if (current is not null && current.TagUid is null) continue;
                string slotName = group.IsExternal ? group.DisplayName : $"{group.DisplayName} {slot.Label}";

                if (store.Spools.FirstOrDefault(s => s.TagUid == uid) is { } known)
                {
                    store.Assign(known.Id, location);
                    results.Add(new PairResult(known.Id, null, slotName));
                    continue;
                }
                if (BestProduct(slot, products) is not { } product) continue;
                var waiting = store.SpoolsForDefinition(product.Id)
                    .Where(s => s.Location.IsStorage && s.TagUid is null && s.Status != SpoolStatus.Empty && s.Status != SpoolStatus.Archived)
                    // An opened roll first, then the oldest: the one most likely to be the roll in hand.
                    .OrderBy(s => s.OpenedAt is null ? 1 : 0).ThenBy(s => s.CreatedAt)
                    .ToList();
                PhysicalSpool roll;
                if (waiting.Count > 0) roll = waiting[0];
                else
                {
                    double weight = slot.NominalGrams ?? 1000;
                    var created = store.CreateRolls(product.Id, 1, weight, slot.RemainingWeightGrams,
                                                    product.PricePerRoll ?? store.LastPrice(product.Id));
                    if (created.Count == 0) continue;
                    roll = created[0];
                }
                store.SetTagUid(roll.Id, uid);
                store.Assign(roll.Id, location);
                results.Add(new PairResult(roll.Id, product.Brand + " " + product.Name, slotName));
            }
        }
        return results;
    }

    /// <summary>The Spoolbase product a tagged roll most likely is: same material, colour within reach,
    /// then Bambu Lab and a name that contains the tag's product name.</summary>
    public static PairProduct? BestProduct(FilamentSlot slot, IReadOnlyList<PairProduct> products)
    {
        var material = slot.Material?.Trim(' ', '\t');
        if (string.IsNullOrEmpty(material)) return null;
        string wanted = (slot.ProductName ?? "").ToUpperInvariant();
        PairProduct? best = null;
        double bestScore = double.MaxValue;
        foreach (var product in products)
        {
            if (!string.Equals(product.Type, material, StringComparison.OrdinalIgnoreCase)) continue;
            if (FarmRules.ColorDistance(product.ColorHex, slot.ColorHex ?? "") is not { } distance || distance > 60) continue;
            double score = distance;
            if (product.Brand.IndexOf("bambu", StringComparison.CurrentCultureIgnoreCase) < 0) score += 100;
            if (wanted.Length > 0 && !(product.Brand + " " + product.Name).ToUpperInvariant().Contains(wanted)) score += 40;
            // Strictly lower, so a tie keeps the first product, like Swift's min(by:).
            if (score < bestScore) { best = product; bestScore = score; }
        }
        return best;
    }
}
