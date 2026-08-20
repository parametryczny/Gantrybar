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
}

/// Runs (and stops) user scripts for script-action automations, keyed by automation id. On Windows a
/// script starting with a python shebang runs through the Python interpreter; otherwise it runs as a
/// batch command via cmd.exe.
public static class ScriptRunner
{
    private static readonly Dictionary<string, Process> Running = new();

    public static bool IsRunning(string id) => Running.ContainsKey(id);

    public static bool Run(string id, string script)
    {
        Stop(id);
        try
        {
            string first = script.TrimStart().Split('\n').FirstOrDefault() ?? "";
            var psi = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = true };
            string? tempFile = null;

            if (first.StartsWith("#!") && first.Contains("python"))
            {
                tempFile = Path.Combine(Path.GetTempPath(), $"gantry-{id}.py");
                File.WriteAllText(tempFile, script);
                psi.FileName = "python";
                psi.Arguments = $"\"{tempFile}\"";
            }
            else
            {
                tempFile = Path.Combine(Path.GetTempPath(), $"gantry-{id}.cmd");
                File.WriteAllText(tempFile, script);
                psi.FileName = "cmd.exe";
                psi.Arguments = $"/c \"{tempFile}\"";
            }

            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            var file = tempFile;
            process.Exited += (_, _) =>
            {
                Running.Remove(id);
                try { if (file is not null) File.Delete(file); } catch { }
            };
            process.Start();
            Running[id] = process;
            return true;
        }
        catch { return false; }
    }

    public static void Stop(string id)
    {
        if (Running.Remove(id, out var process))
        {
            try { if (!process.HasExited) process.Kill(true); } catch { }
        }
    }
}
