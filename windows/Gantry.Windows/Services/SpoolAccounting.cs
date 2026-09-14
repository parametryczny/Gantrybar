using System.Text.Json;

namespace Gantry.Services;

/// <summary>What the printer is doing, as far as the identity of a print cares.</summary>
public enum JobPhase { Other, Running, Finished }

/// <summary>One filament slot as the accounting sees it: where it is and what it reports.</summary>
public readonly record struct SlotRef(int Group, int Slot, bool External, bool Active, bool Present, string? ColorHex);

public readonly record struct SpoolCharge(string SpoolId, double Grams, string FilamentId);

/// <summary>Which print a finished job belongs to. Mirrors macOS PrintJobSessions: the hour a FINISHED
/// packet arrived used to be the identity, so two short prints of one file within an hour merged into
/// one job and a finish seen again after a restart in a later hour was subtracted twice. A session
/// starts when the printer is seen printing, ends when it finishes, and is kept on disk.
/// Free of WPF and application state, so the console tests compile it on its own.</summary>
public sealed class PrintJobSessions
{
    public sealed class Session
    {
        public string Job { get; set; } = "";
        public string Id { get; set; } = "";
        public bool Finished { get; set; }
    }

    public Dictionary<string, Session> Sessions { get; set; } = new();

    /// <summary>Feeds one update. Returns the job id when this update is the finish to account for, and
    /// whether the sessions changed, so they are only written then.</summary>
    public (string? JobId, bool Changed) Observe(string serial, bool previousFinished, JobPhase phase, string? jobName, long unixSeconds)
    {
        var job = jobName ?? "?";
        var id = $"{serial}|{job}|{unixSeconds}";
        Sessions.TryGetValue(serial, out var current);
        switch (phase)
        {
            case JobPhase.Running:
                if (current is not null && current.Job == job && !current.Finished) return (null, false);
                Sessions[serial] = new Session { Job = job, Id = id };
                return (null, true);
            case JobPhase.Finished:
                if (previousFinished) return (null, false);
                if (current is not null && current.Job == job)
                {
                    bool changed = !current.Finished;
                    current.Finished = true;
                    return (current.Id, changed);
                }
                // Finished before Gantry saw it print. One session for it, kept, so a restart reuses it.
                Sessions[serial] = new Session { Job = job, Id = id, Finished = true };
                return (id, true);
            default:
                return (null, false);
        }
    }

    public string ToJson() => JsonSerializer.Serialize(Sessions);

    public static PrintJobSessions FromJson(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return new PrintJobSessions();
        try
        {
            return new PrintJobSessions { Sessions = JsonSerializer.Deserialize<Dictionary<string, Session>>(json) ?? new() };
        }
        catch (JsonException)
        {
            return new PrintJobSessions();
        }
    }
}

public static class SpoolAccounting
{
    /// <summary>The slot a single-extruder print came from: the active one, wherever it is. With none
    /// active, only a lone loaded roll counts. Taking the first present slot charged whatever roll sat
    /// in A1 while A2 was feeding, and the first unit's roll while the second unit was feeding.</summary>
    public static SlotRef? LoadedSlot(IReadOnlyList<SlotRef> slots, Func<SlotRef, bool> hasSpool)
    {
        var active = slots.Where(s => s.Active).ToList();
        if (active.Count > 0) return active.Count == 1 ? active[0] : null;
        var loaded = slots.Where(s => s.Present && hasSpool(s)).ToList();
        return loaded.Count == 1 ? loaded[0] : null;
    }

    /// <summary>Maps each sliced filament to a slot by colour (a single filament falls back to the loaded
    /// slot) and to the roll that was assigned there when the print finished.</summary>
    public static List<SpoolCharge> BambuCharges(IReadOnlyList<SlotRef> slots,
        IReadOnlyList<(string Id, double UsedGrams, string ColorHex)> filaments, Func<SlotRef, string?> assignedSpool)
    {
        var charges = new List<SpoolCharge>();
        foreach (var filament in filaments)
        {
            if (filament.UsedGrams <= 0) continue;
            var target = ByColor(slots, filament.ColorHex)
                ?? (filaments.Count == 1 ? LoadedSlot(slots, s => assignedSpool(s) is not null) : null);
            if (target is not { } slot || assignedSpool(slot) is not { } spoolId) continue;
            charges.Add(new SpoolCharge(spoolId, filament.UsedGrams, filament.Id));
        }
        return charges;
    }

    private static string Hex6(string? value)
    {
        var hex = (value ?? "").Replace("#", "").ToUpperInvariant();
        return hex.Length >= 6 ? hex[..6] : hex;
    }

    private static SlotRef? ByColor(IReadOnlyList<SlotRef> slots, string colorHex)
    {
        var wanted = Hex6(colorHex);
        if (wanted.Length == 0) return null;
        foreach (var slot in slots)
            if (Hex6(slot.ColorHex) == wanted) return slot;
        return null;
    }
}
