using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Shared Spoolbase stores so the inventory window, the AMS assign popover and the consumption
/// tracker all read/write one source of truth.</summary>
public static class SpoolbaseShared
{
    public static FilamentStore Filaments { get; } = new();
    public static PhysicalSpoolStore Spools { get; } = new();
}

/// <summary>Persists physical spools + consumption history to %AppData%\Spoolbase\ (JSON, keys shared
/// with macOS/Linux). Mirrors the Swift PhysicalSpoolStore.</summary>
public sealed class PhysicalSpoolStore
{
    private readonly List<PhysicalSpool> _spools;
    private readonly List<SpoolUsageEvent> _usage;
    private readonly string _spoolsPath;
    private readonly string _usagePath;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public event Action? Changed;

    public IReadOnlyList<PhysicalSpool> Spools => _spools;

    public PhysicalSpoolStore()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spoolbase");
        _spoolsPath = Path.Combine(dir, "spools-v1.json");
        _usagePath = Path.Combine(dir, "usage-v1.json");
        _spools = Load<List<PhysicalSpool>>(_spoolsPath) ?? new();
        _usage = Load<List<SpoolUsageEvent>>(_usagePath) ?? new();
    }

    // Lookup

    public PhysicalSpool? Spool(string id) => _spools.FirstOrDefault(s => s.Id == id);

    public PhysicalSpool? SpoolAt(SpoolLocation location) =>
        location.IsStorage ? null : _spools.FirstOrDefault(s => s.Location.SameSlot(location));

    public string NextSpoolId()
    {
        var max = _spools
            .Where(s => s.Id.StartsWith("SP-", StringComparison.Ordinal))
            .Select(s => int.TryParse(s.Id.AsSpan(3), out var n) ? n : 0)
            .DefaultIfEmpty(0).Max();
        return $"SP-{max + 1:00000}";
    }

    // Mutations

    public void Add(PhysicalSpool spool) { _spools.Add(spool); ChangedInternal(SaveSpools); }

    /// <summary>Creates <paramref name="count"/> fresh rolls of one definition, each with its own id,
    /// dropped straight into storage (spec §1: adding a filament creates one physical roll per spool). A
    /// full roll has remaining == nominal == <paramref name="weight"/>; an opened roll passes a smaller
    /// <paramref name="remaining"/>.</summary>
    public void CreateRolls(Guid definitionId, int count, double weight, double? remaining = null)
    {
        if (count <= 0) return;
        for (int i = 0; i < count; i++)
        {
            double rest = remaining ?? weight;
            _spools.Add(new PhysicalSpool
            {
                Id = NextSpoolId(),
                FilamentDefinitionId = definitionId,
                NominalWeightGrams = weight,
                RemainingWeightGrams = rest,
                Status = rest < weight ? SpoolStatus.Active : SpoolStatus.New,
                Location = SpoolLocation.Storage(),
                OpenedAt = rest < weight ? DateTime.UtcNow : null
            });
        }
        ChangedInternal(SaveSpools);
    }

    public void Delete(string id) { _spools.RemoveAll(s => s.Id == id); ChangedInternal(SaveSpools); }

    public void SetRemaining(string id, double grams)
    {
        var s = Spool(id);
        if (s is null) return;
        s.RemainingWeightGrams = Math.Max(0, Math.Min(grams, s.NominalWeightGrams));
        if (s.RemainingWeightGrams <= 0) s.Status = SpoolStatus.Empty;
        s.UpdatedAt = DateTime.UtcNow;
        ChangedInternal(SaveSpools);
    }

    /// <summary>Manual weighing (spec §5 "Skoryguj wagę"): store a freshly measured net amount and stamp
    /// the weighing date. <paramref name="tare"/> (empty-spool weight) is remembered for next time; the
    /// caller passes an already-net value (gross minus tare).</summary>
    public void CorrectWeight(string id, double netGrams, double? tare = null)
    {
        var s = Spool(id);
        if (s is null) return;
        s.RemainingWeightGrams = Math.Max(0, Math.Min(netGrams, s.NominalWeightGrams));
        if (tare is not null) s.TareGrams = tare;
        s.WeighedAt = DateTime.UtcNow;
        if (s.RemainingWeightGrams <= 0) { s.Status = SpoolStatus.Empty; s.EmptiedAt = DateTime.UtcNow; }
        else if (s.Status == SpoolStatus.Empty) s.Status = s.Location.IsStorage ? SpoolStatus.Stored : SpoolStatus.Active;
        s.UpdatedAt = DateTime.UtcNow;
        ChangedInternal(SaveSpools);
    }

    /// <summary>Reset a roll back to a full nominal amount (spec §6): the same physical roll, refilled —
    /// e.g. a spent roll swapped for a fresh one of the same product without minting a new id. Clears this
    /// roll's consumption/lifecycle so history starts over.</summary>
    public void ResetToFull(string id, double? nominal = null)
    {
        var s = Spool(id);
        if (s is null) return;
        double full = Math.Max(0, nominal ?? s.NominalWeightGrams);
        s.NominalWeightGrams = full;
        s.RemainingWeightGrams = full;
        s.TotalConsumedGrams = 0;
        s.OpenedAt = null;
        s.EmptiedAt = null;
        s.WeighedAt = null;
        s.Status = s.Location.IsStorage ? SpoolStatus.New : SpoolStatus.Active;
        s.UpdatedAt = DateTime.UtcNow;
        ChangedInternal(SaveSpools);
    }

    /// <summary>Move a spool to a slot, freeing whatever slot it or the target held (single location).</summary>
    public void Assign(string spoolId, SpoolLocation location)
    {
        var spool = Spool(spoolId);
        if (spool is null) return;
        if (!location.IsStorage)
            foreach (var other in _spools.Where(o => o.Id != spoolId && o.Location.SameSlot(location)))
            {
                other.Location = SpoolLocation.Storage();
                if (other.Status != SpoolStatus.Empty) other.Status = SpoolStatus.Stored;
                other.UpdatedAt = DateTime.UtcNow;
            }
        spool.Location = location;
        if (!location.IsStorage)
        {
            spool.Status = spool.RemainingWeightGrams <= 0 ? SpoolStatus.Empty : SpoolStatus.Active;
            spool.OpenedAt ??= DateTime.UtcNow;
        }
        else if (spool.Status == SpoolStatus.Active) spool.Status = SpoolStatus.Stored;
        spool.UpdatedAt = DateTime.UtcNow;
        ChangedInternal(SaveSpools);
    }

    /// <summary>When a real RFID/NFC spool is newly inserted into a slot that still holds a manually
    /// assigned Spoolbase spool, the assignment is stale (that roll was taken out) - send it back to
    /// storage so the slot shows the inserted NFC roll's own data. Fires only on the insert transition
    /// (the slot gains an NFC reading), so a deliberate later assignment is left alone.</summary>
    public List<(string SpoolId, string Slot)> DetachAssignmentsReplacedByNfc(string printerSerial, List<FilamentGroup> previous, List<FilamentGroup> current)
    {
        var detached = new List<(string, string)>();
        for (int gi = 0; gi < current.Count; gi++)
        {
            var group = current[gi];
            for (int si = 0; si < group.Slots.Count; si++)
            {
                if (group.Slots[si].RemainingWeightGrams is null) continue;
                bool hadNfc = gi < previous.Count && si < previous[gi].Slots.Count
                    && previous[gi].Slots[si].RemainingWeightGrams is not null;
                if (hadNfc) continue;
                var location = SpoolLocation.At(printerSerial, group.IsExternal ? SpoolFeeder.Ext : SpoolFeeder.Ams, gi, si);
                if (SpoolAt(location) is { } assigned)
                {
                    string slotLabel = group.IsExternal ? group.DisplayName : $"{group.DisplayName} {group.Slots[si].Label}";
                    Assign(assigned.Id, SpoolLocation.Storage());
                    detached.Add((assigned.Id, slotLabel));
                }
            }
        }
        return detached;
    }

    /// <summary>Idempotent per print job: a job id already recorded is ignored (no double-count).</summary>
    public bool Consume(string spoolId, double grams, string printerSerial, string printJobId)
    {
        if (grams <= 0) return false;
        if (_usage.Any(u => u.PrintJobId == printJobId && u.SpoolId == spoolId)) return false;
        var s = Spool(spoolId);
        if (s is null) return false;
        s.RemainingWeightGrams = Math.Max(0, s.RemainingWeightGrams - grams);
        s.TotalConsumedGrams += grams;
        s.LastUsedAt = DateTime.UtcNow;
        s.UpdatedAt = DateTime.UtcNow;
        if (s.RemainingWeightGrams <= 0) { s.Status = SpoolStatus.Empty; s.EmptiedAt = DateTime.UtcNow; }
        _usage.Add(new SpoolUsageEvent { SpoolId = spoolId, PrinterSerial = printerSerial, PrintJobId = printJobId, ConsumedGrams = grams });
        Save(_usagePath, _usage);
        ChangedInternal(SaveSpools);
        return true;
    }

    // Persistence

    public IReadOnlyList<SpoolUsageEvent> UsageEvents => _usage;

    private void ChangedInternal(Action save) { save(); Changed?.Invoke(); }
    private void SaveSpools() => Save(_spoolsPath, _spools);

    private static T? Load<T>(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options) : default; }
        catch { return default; }
    }

    private static void Save<T>(string path, T value)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(value, Options));
        }
        catch { /* best effort */ }
    }
}
