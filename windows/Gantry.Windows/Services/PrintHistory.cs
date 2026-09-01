using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>A tiny rolling log of finished prints for the Telegram bot's /history. JSON in the settings
/// store, capped to the last 30. Mirrors the macOS PrintHistory.</summary>
public static class PrintHistory
{
    public sealed class Entry
    {
        public string Serial { get; set; } = "";
        public string Printer { get; set; } = "";
        public string Job { get; set; } = "";
        public DateTime Date { get; set; }
    }

    private const string Key = "print-history-v1";
    private const int Cap = 30;

    public static void Record(string serial, string printer, string job)
    {
        var entries = All();
        entries.Add(new Entry { Serial = serial, Printer = printer, Job = job, Date = DateTime.Now });
        if (entries.Count > Cap) entries.RemoveRange(0, entries.Count - Cap);
        Defaults.SetString(Key, JsonSerializer.Serialize(entries));
    }

    public static List<Entry> Recent(int count = 10)
    {
        var all = All();
        all.Reverse();
        return all.Take(count).ToList();
    }

    private static List<Entry> All()
    {
        var s = Defaults.GetString(Key);
        if (string.IsNullOrEmpty(s)) return new();
        try { return JsonSerializer.Deserialize<List<Entry>>(s) ?? new(); } catch { return new(); }
    }
}
