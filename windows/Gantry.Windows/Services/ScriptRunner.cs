using System.Diagnostics;
using System.IO;

namespace Gantry.Services;

/// Runs (and stops) user scripts for script-action automations, keyed by automation id. On Windows a
/// script starting with a python shebang runs through the Python interpreter; otherwise it runs as a
/// batch command via cmd.exe.
///
/// A run replaces the previous one under the same id. The previous process's exit used to remove the
/// entry by id alone, so it could drop the run that replaced it and leave a script the UI no longer knew
/// how to stop. The map was also changed from the exit callback's thread without a lock, and a fast script
/// could exit before it was registered. Each run now clears only its own entry and has its own temporary
/// file. Free of WPF and application state, so the console tests compile it on its own.
public static class ScriptRunner
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, Process> Running = new();

    public static bool IsRunning(string id)
    {
        lock (Gate) return Running.ContainsKey(id);
    }

    public static bool Run(string id, string script)
    {
        Stop(id);
        string? tempFile = null;
        try
        {
            string first = script.TrimStart().Split('\n').FirstOrDefault() ?? "";
            var psi = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = true };
            var runName = $"gantry-{id}-{Guid.NewGuid():N}";

            if (first.StartsWith("#!") && first.Contains("python"))
            {
                tempFile = Path.Combine(Path.GetTempPath(), runName + ".py");
                File.WriteAllText(tempFile, script);
                psi.FileName = "python";
                psi.Arguments = $"\"{tempFile}\"";
            }
            else
            {
                tempFile = Path.Combine(Path.GetTempPath(), runName + ".cmd");
                File.WriteAllText(tempFile, script);
                psi.FileName = "cmd.exe";
                psi.Arguments = $"/c \"{tempFile}\"";
            }

            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            var file = tempFile;
            process.Exited += (_, _) =>
            {
                lock (Gate)
                {
                    // Only this run's own entry: a newer run under the same id stays registered.
                    if (Running.TryGetValue(id, out var current) && ReferenceEquals(current, process)) Running.Remove(id);
                }
                try { File.Delete(file); } catch { }
            };
            lock (Gate)
            {
                // Registered before it starts, so a script that exits at once still finds its entry to clear.
                Running[id] = process;
                try
                {
                    process.Start();
                }
                catch
                {
                    Running.Remove(id);
                    throw;
                }
            }
            return true;
        }
        catch
        {
            try { if (tempFile is not null) File.Delete(tempFile); } catch { }
            return false;
        }
    }

    public static void Stop(string id)
    {
        Process? process;
        lock (Gate)
        {
            if (!Running.Remove(id, out var removed)) return;
            process = removed;
        }
        try { if (!process.HasExited) process.Kill(true); } catch { }
    }
}
