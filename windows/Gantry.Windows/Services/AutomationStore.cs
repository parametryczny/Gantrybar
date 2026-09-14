using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// Persists per-printer automations (keyed by serial) in the shared defaults.
public static class AutomationStore
{
    private const string Key = "printer-automations-v1";

    public static List<PrinterAutomation> For(string serial)
        => Load().TryGetValue(serial, out var list) ? list : new();

    public static void Set(string serial, List<PrinterAutomation> list)
    {
        var all = Load();
        if (list.Count == 0) all.Remove(serial); else all[serial] = list;
        Defaults.SetRaw(Key, JsonSerializer.Serialize(all));
    }

    private static Dictionary<string, List<PrinterAutomation>> Load()
    {
        var raw = Defaults.GetRaw(Key);
        if (string.IsNullOrEmpty(raw)) return new();
        try { return JsonSerializer.Deserialize<Dictionary<string, List<PrinterAutomation>>>(raw) ?? new(); }
        catch { return new(); }
    }

    /// Automations are loaded ONLY from this app's own settings — they are never imported from an
    /// external file, a shared bundle, or another user (the CSV printer import carries no automations).
    /// That's deliberate: it stops a shared/planted config from delivering a code-executing rule.
    /// If an import or restore path is ever added, it MUST pass the lists through Sanitize() first, which
    /// disables any code-executing action ("script"/"command") so imported rules can't run code silently.
    public static List<PrinterAutomation> Sanitize(IEnumerable<PrinterAutomation> items)
    {
        var safe = new List<PrinterAutomation>();
        foreach (var a in items)
        {
            if (a.ActionKind is "script" or "command") a.Enabled = false;
            safe.Add(a);
        }
        return safe;
    }
}

