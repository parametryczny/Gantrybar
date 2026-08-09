using System.Diagnostics;
using System.IO;

namespace Gantry.Services;

/// <summary>Detects installed desktop slicers and launches them, so the per-printer "Open slicer"
/// action offers whatever the user actually has. Windows counterpart of the macOS SlicerLauncher.</summary>
public static class SlicerLauncher
{
    public sealed record Slicer(string Name, string Path);

    // Each slicer lists candidate executable paths; the first that exists wins.
    private static readonly (string Name, string[] Candidates)[] Known =
    {
        ("Bambu Studio", new[]
        {
            @"%ProgramFiles%\Bambu Studio\bambu-studio.exe",
            @"%ProgramW6432%\Bambu Studio\bambu-studio.exe"
        }),
        ("OrcaSlicer", new[]
        {
            @"%ProgramFiles%\OrcaSlicer\orca-slicer.exe",
            @"%LocalAppData%\Programs\OrcaSlicer\orca-slicer.exe"
        }),
        ("Creality Print", new[]
        {
            @"%ProgramFiles%\Creality\Creality Print\CrealityPrint.exe",
            @"%ProgramFiles(x86)%\Creality\Creality Print\CrealityPrint.exe"
        }),
        ("PrusaSlicer", new[]
        {
            @"%ProgramFiles%\Prusa3D\PrusaSlicer\prusa-slicer.exe"
        })
    };

    public static IReadOnlyList<Slicer> Installed()
    {
        var found = new List<Slicer>();
        foreach (var (name, candidates) in Known)
        {
            foreach (var candidate in candidates)
            {
                var path = Environment.ExpandEnvironmentVariables(candidate);
                if (File.Exists(path))
                {
                    found.Add(new Slicer(name, path));
                    break;
                }
            }
        }
        return found;
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch { /* launch failed */ }
    }
}
