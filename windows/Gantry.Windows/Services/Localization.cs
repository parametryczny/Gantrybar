using System.IO;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>
/// The shipped translation catalog, keyed by the English source string the way gettext keys by msgid.
///
/// Two consequences worth knowing. A key missing from the catalog falls back to the English string
/// itself, so a forgotten entry degrades to readable text instead of showing "settings.launch" to the
/// user. And adding a language means adding one JSON file, without touching any call site.
///
/// The catalog is the repository's i18n/pl.json, copied next to the executable by the project file.
/// </summary>
public static class Localization
{
    private static readonly Dictionary<string, string> Polish = Load();

    /// <summary>Polish text for an English source string, or the string itself when not in the catalog.</summary>
    public static string ToPolish(string english) =>
        Polish.TryGetValue(english, out var value) ? value : english;

    /// <summary>Entry count, used by diagnostics; never needed at runtime.</summary>
    public static int LoadedCount => Polish.Count;

    private static Dictionary<string, string> Load()
    {
        foreach (var path in Candidates())
        {
            try
            {
                if (!File.Exists(path)) continue;
                var parsed = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
                if (parsed is { Count: > 0 }) return parsed;
            }
            catch (Exception ex)
            {
                Gantry.App.LogError("LocalizationLoad", ex);
            }
        }
        return new Dictionary<string, string>();
    }

    private static IEnumerable<string> Candidates()
    {
        string baseDir = AppContext.BaseDirectory;
        yield return Path.Combine(baseDir, "i18n", "pl.json");
        // Running from the checkout (dotnet run) the file sits three levels up, in the repo root.
        yield return Path.Combine(baseDir, "..", "..", "..", "..", "..", "i18n", "pl.json");
    }
}
