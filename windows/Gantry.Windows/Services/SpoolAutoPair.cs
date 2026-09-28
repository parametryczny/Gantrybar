using System.Collections.Generic;
using System.Linq;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>The app side of <see cref="SpoolAutoPairRules"/>: the shared Spoolbase stores, the setting
/// and the card notices. Mirrors the macOS SpoolAutoPair.pair(serial:groups:).</summary>
public static class SpoolAutoPair
{
    /// <summary>Pairs every tagged, unpaired roll in these groups and returns one line per pairing, for the card.</summary>
    public static List<string> Pair(string serial, IReadOnlyList<FilamentGroup> groups)
    {
        if (!AppSettings.SpoolbaseEnabled || !AppSettings.SpoolAutoPair) return new();
        var products = SpoolbaseShared.Filaments.Filaments
            .Select(f => new PairProduct(f.Id, f.Brand, f.Name, f.Type, f.ColorHex, f.PricePerRoll))
            .ToList();
        return SpoolAutoPairRules.Pair(serial, groups, SpoolbaseShared.Spools, products)
            .Select(result => result.Product is null
                ? string.Format(AppSettings.T("{0} recognised in {1}"), result.SpoolId, result.Slot)
                : string.Format(AppSettings.T("{0} ({1}) paired with {2}"), result.SpoolId, result.Product, result.Slot))
            .ToList();
    }
}
