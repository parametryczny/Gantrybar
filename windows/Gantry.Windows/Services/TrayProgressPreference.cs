using System.Text.Json;

namespace Gantry.Services;

/// <summary>Which printers the user pinned to the system tray (a per-printer checkbox in the edit
/// window). Each pinned printer gets an extra tray icon showing live progress. Windows counterpart
/// of the macOS MenuBarProgressPreference; stored as a serial list in defaults.json.</summary>
public static class TrayProgressPreference
{
    private const string Key = "menu-bar-progress-serials";

    public static List<string> Serials()
    {
        var raw = Defaults.GetRaw(Key);
        if (raw is null) return new();
        try { return JsonSerializer.Deserialize<List<string>>(raw) ?? new(); }
        catch { return new(); }
    }

    public static bool IsEnabled(string serial) => Serials().Contains(serial);

    public static void SetEnabled(bool enabled, string serial)
    {
        var current = Serials();
        if (enabled)
        {
            if (current.Contains(serial)) return;
            current.Add(serial);
        }
        else
        {
            current.RemoveAll(s => s == serial);
        }
        Defaults.SetRaw(Key, JsonSerializer.Serialize(current));
    }

    /// <summary>Drops serials no longer backed by a saved printer.</summary>
    public static void Prune(IEnumerable<string> validSerials)
    {
        var valid = new HashSet<string>(validSerials);
        var current = Serials();
        var filtered = current.Where(valid.Contains).ToList();
        if (filtered.Count != current.Count)
            Defaults.SetRaw(Key, JsonSerializer.Serialize(filtered));
    }
}
