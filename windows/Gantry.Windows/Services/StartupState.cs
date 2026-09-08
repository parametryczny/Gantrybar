using System.Diagnostics;

namespace Gantry.Services;

/// <summary>One launch gate, independent of WPF and transport reconnects. Monotonic timeout.</summary>
public sealed class StartupState
{
    private readonly HashSet<string> _initial;
    public HashSet<string> Received { get; } = new();
    private readonly Func<double> _clock;
    private readonly double _deadline;
    private bool _finished, _guideClaimed;
    public int Total => _initial.Count;
    public int Ready => _initial.Count(Received.Contains);
    public bool Loading
    {
        get
        {
            if (_clock() >= _deadline || Ready >= (Total * 3 + 4) / 5) _finished = true;
            return !_finished;
        }
    }
    public StartupState(IEnumerable<string> serials, Func<double>? clock = null)
    {
        _initial = serials.ToHashSet();
        _clock = clock ?? (() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency);
        _deadline = _clock() + 15;
        _finished = Total == 0;
    }
    public void Report(string serial) { Received.Add(serial); _ = Loading; }
    public void Remove(string serial) { _initial.Remove(serial); Received.Remove(serial); _ = Loading; }
    public void Finish() => _finished = true;
    public bool ClaimGuide(bool seen)
    {
        if (seen || _guideClaimed) return false;
        _guideClaimed = true;
        return true;
    }
    public static void RunSelfTest()
    {
        double now = 0;
        var state = new StartupState(new[] { "a", "b", "c", "d", "e" }, () => now);
        state.Report("a"); state.Report("a"); state.Report("b");
        if (!state.Loading || state.Ready != 2) throw new Exception("Premature startup dismissal");
        state.Report("c");
        if (state.Loading) throw new Exception("60% threshold not reached");
        state.Remove("c");
        if (state.Loading) throw new Exception("Startup gate reopened");
        if (!state.ClaimGuide(false) || state.ClaimGuide(false)) throw new Exception("Repeated guide");
        state = new StartupState(new[] { "a" }, () => now);
        now = 15;
        if (state.Loading || state.Received.Count != 0) throw new Exception("Timeout fabricated data");
        if (new StartupState(Array.Empty<string>()).Loading) throw new Exception("Empty fleet blocked");
    }
}
