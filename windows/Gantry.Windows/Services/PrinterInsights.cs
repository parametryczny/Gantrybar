using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Vendor-neutral print history, statistics and per-printer maintenance schedules.</summary>
public static class PrinterInsights
{
    public enum PrintResult { Completed, Failed, Cancelled }
    public enum SignalKind { None, Planned, Due, Urgent }
    public sealed class HistoryEntry
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Job { get; set; } = "";
        public DateTime StartedAt { get; set; }
        public DateTime EndedAt { get; set; }
        public PrintResult Result { get; set; }
        public double DurationSeconds { get; set; }
    }
    public sealed class TaskState
    {
        public double IntervalHours { get; set; }
        public double CompletedAtPrintHours { get; set; }
        public DateTime? SnoozedUntil { get; set; }
    }
    public sealed class PrinterRecord
    {
        public double TotalPrintSeconds { get; set; }
        public DateTime? ActiveStartedAt { get; set; }
        public string? ActiveJob { get; set; }
        public List<HistoryEntry> History { get; set; } = new();
        public Dictionary<string, TaskState> Tasks { get; set; } = new();
    }
    public sealed record TaskStatus(string Id, string Title, double IntervalHours, double RemainingHours,
                                    double OverdueHours, bool IsDue, bool IsUrgent, DateTime? SnoozedUntil);
    public sealed record Snapshot(double TotalPrintHours, IReadOnlyList<HistoryEntry> History,
                                  IReadOnlyList<TaskStatus> Tasks, double ConsumedGrams)
    {
        public int CompletedCount => History.Count(value => value.Result == PrintResult.Completed);
        public int? SuccessPercent => History.Count == 0 ? null : (int)Math.Round(CompletedCount * 100.0 / History.Count);
    }
    public readonly record struct Signal(SignalKind Kind, int Count);
    private sealed record Definition(string Id, string Polish, string English, double Hours);

    private const string Key = "printer-insights-v1";
    private static readonly Definition[] Definitions =
    {
        new("clean-rods", "Czyszczenie prowadnic", "Clean guide rods", 100),
        new("lubricate-axes", "Smarowanie osi", "Lubricate axes", 200),
        new("inspect-belts", "Kontrola pasków", "Inspect belts", 300),
        new("inspect-nozzle", "Kontrola dyszy", "Inspect nozzle", 500),
    };
    private static readonly Dictionary<string, PrinterRecord> Records = Load();
    private static DateTime _lastPersistedAt = DateTime.MinValue;
    public static event Action? Changed;

    private static Dictionary<string, PrinterRecord> Load()
    {
        var json = Defaults.GetRaw(Key);
        if (string.IsNullOrWhiteSpace(json)) return new();
        try { return JsonSerializer.Deserialize<Dictionary<string, PrinterRecord>>(json) ?? new(); }
        catch { return new(); }
    }

    private static PrinterRecord Record(string serial)
    {
        if (!Records.TryGetValue(serial, out var value)) Records[serial] = value = new();
        return value;
    }

    public static void Observe(SavedPrinter printer, PrinterTelemetry? previous, PrinterTelemetry current)
    {
        var record = Record(printer.Serial);
        var now = current.LastUpdated ?? DateTime.Now;
        bool wasActive = previous?.State is PrinterState.Printing or PrinterState.Paused;
        bool active = current.State is PrinterState.Printing or PrinterState.Paused;
        if (active && record.ActiveStartedAt is null)
        {
            record.ActiveStartedAt = now;
            record.ActiveJob = current.JobName;
        }
        if (current.State == PrinterState.Printing && previous?.LastUpdated is { } last)
            record.TotalPrintSeconds += Math.Clamp((now - last).TotalSeconds, 0, 120);

        PrintResult? result = null;
        if (current.State == PrinterState.Finished && previous?.State != PrinterState.Finished &&
            (wasActive || record.ActiveStartedAt is not null)) result = PrintResult.Completed;
        else if (wasActive && current.State == PrinterState.Error) result = PrintResult.Failed;
        else if (wasActive && current.State == PrinterState.Idle && previous is { Progress: > 0 and < 100 }) result = PrintResult.Cancelled;
        if (result is { } terminal)
        {
            var start = record.ActiveStartedAt ?? now;
            var job = current.JobName ?? previous?.JobName ?? record.ActiveJob ?? "";
            bool duplicate = record.History.LastOrDefault() is { } lastEntry && lastEntry.Result == terminal &&
                             lastEntry.Job == job && Math.Abs((lastEntry.EndedAt - now).TotalSeconds) < 30;
            if (!duplicate)
            {
                record.History.Add(new HistoryEntry { Job = job, StartedAt = start, EndedAt = now,
                    Result = terminal, DurationSeconds = Math.Max(0, (now - start).TotalSeconds) });
                if (record.History.Count > 100) record.History.RemoveRange(0, record.History.Count - 100);
            }
            record.ActiveStartedAt = null; record.ActiveJob = null;
        }
        else if (!active && current.State != PrinterState.Offline && !wasActive)
        {
            record.ActiveStartedAt = null; record.ActiveJob = null;
        }
        Save(result is not null);
    }

    public static Snapshot GetSnapshot(string serial, bool polish)
    {
        var record = Record(serial);
        double hours = record.TotalPrintSeconds / 3600;
        var tasks = Definitions.Select(definition =>
        {
            if (!record.Tasks.TryGetValue(definition.Id, out var state))
                state = new TaskState { IntervalHours = definition.Hours };
            double remaining = state.CompletedAtPrintHours + state.IntervalHours - hours;
            bool due = remaining <= 0 && !(state.SnoozedUntil is { } until && until > DateTime.Now);
            double overdue = Math.Max(0, -remaining);
            return new TaskStatus(definition.Id, polish ? definition.Polish : definition.English,
                state.IntervalHours, Math.Max(0, remaining), overdue, due,
                due && overdue >= Math.Max(24, state.IntervalHours * .15), state.SnoozedUntil);
        }).ToList();
        double grams = SpoolbaseShared.Spools.UsageEvents.Where(value => value.PrinterSerial == serial).Sum(value => value.ConsumedGrams);
        return new Snapshot(hours, record.History.AsEnumerable().Reverse().ToList(), tasks, grams);
    }

    public static Signal GetSignal(string serial)
    {
        var tasks = GetSnapshot(serial, true).Tasks;
        int urgent = tasks.Count(value => value.IsUrgent);
        if (urgent > 0) return new(SignalKind.Urgent, urgent);
        int due = tasks.Count(value => value.IsDue);
        if (due > 0) return new(SignalKind.Due, due);
        bool planned = tasks.Any(value => !value.IsDue && !(value.SnoozedUntil is { } until && until > DateTime.Now)
                                              && value.RemainingHours <= Math.Max(24, value.IntervalHours * .1));
        return planned ? new(SignalKind.Planned, 0) : new(SignalKind.None, 0);
    }

    public static void Complete(string serial, string taskId) => Change(serial, taskId, completed: true);
    public static void Snooze(string serial, string taskId) => Change(serial, taskId, snooze: true);
    public static void SetInterval(string serial, string taskId, double hours)
    {
        if (hours >= 1) Change(serial, taskId, interval: hours);
    }

    private static void Change(string serial, string taskId, bool completed = false, bool snooze = false, double? interval = null)
    {
        var record = Record(serial);
        if (!record.Tasks.TryGetValue(taskId, out var state))
        {
            var definition = Definitions.FirstOrDefault(value => value.Id == taskId);
            record.Tasks[taskId] = state = new TaskState { IntervalHours = definition?.Hours ?? 200 };
        }
        if (completed) { state.CompletedAtPrintHours = record.TotalPrintSeconds / 3600; state.SnoozedUntil = null; }
        if (snooze) state.SnoozedUntil = DateTime.Now.AddDays(7);
        if (interval is { } value) state.IntervalHours = value;
        Save(true);
    }

    private static void Save(bool notify)
    {
        if (notify || (DateTime.Now - _lastPersistedAt).TotalSeconds >= 60)
        {
            Defaults.SetRaw(Key, JsonSerializer.Serialize(Records));
            _lastPersistedAt = DateTime.Now;
        }
        if (notify) Changed?.Invoke();
    }
}
