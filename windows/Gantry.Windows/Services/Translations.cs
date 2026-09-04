using System.IO;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>
/// Translation catalogs, keyed by the English source string the way gettext keys by msgid.
///
/// Three consequences worth knowing. A key missing from a catalog falls back to the English string
/// itself, so a forgotten entry degrades to readable text instead of showing "settings.launch" to the
/// user. English needs no catalog at all, because it <em>is</em> the key. And a new language is one
/// file dropped into i18n/: nothing here or in Settings enumerates languages by hand.
///
/// Each catalog names itself under the "@name" key ("Polski", "Deutsch"), so the Settings list needs
/// no table of language names in code. Keys starting with "@" are metadata, never lookup text.
/// </summary>
public static class Translations
{
    public sealed record Language(string Code, string Name);

    public static readonly Language English = new("en", "English");

    private static readonly object Gate = new();
    private static readonly Dictionary<string, Dictionary<string, string>> Cache = new();
    private static Dictionary<string, string>? _files;

    /// <summary>Text for an English source string in the given language.</summary>
    public static string Text(string english, string language)
    {
        if (language == "en") return english;
        var table = Table(language);
        return table.TryGetValue(english, out var value) ? value : english;
    }

    /// <summary>Every language the app can offer: English plus one entry per catalog found on disk.</summary>
    public static List<Language> Available()
    {
        var found = new List<Language> { English };
        foreach (var (code, path) in Files().OrderBy(entry => entry.Key))
        {
            if (code == "en") continue;
            var table = Table(code);
            found.Add(new Language(code, table.TryGetValue("@name", out var name) ? name : code.ToUpperInvariant()));
        }
        return found;
    }

    /// <summary>Entry count for a language, used by diagnostics; never needed at runtime.</summary>
    public static int LoadedCount(string language) => Table(language).Count;

    private static Dictionary<string, string> Table(string language)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(language, out var cached)) return cached;
            var loaded = new Dictionary<string, string>();
            if (Files().TryGetValue(language, out var path))
            {
                try
                {
                    var parsed = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
                    if (parsed is not null) loaded = parsed;
                }
                catch (Exception ex)
                {
                    Gantry.App.LogError("TranslationsLoad", ex);
                }
            }
            Cache[language] = loaded;
            return loaded;
        }
    }

    /// <summary>Catalog files by language code, taking the first directory that has any.</summary>
    private static Dictionary<string, string> Files()
    {
        lock (Gate)
        {
            if (_files is not null) return _files;
            foreach (var directory in SearchPaths())
            {
                try
                {
                    if (!Directory.Exists(directory)) continue;
                    var found = Directory.GetFiles(directory, "*.json")
                        .ToDictionary(Path.GetFileNameWithoutExtension!, path => path);
                    if (found.Count > 0) return _files = found;
                }
                catch (Exception ex)
                {
                    Gantry.App.LogError("TranslationsScan", ex);
                }
            }
            return _files = new Dictionary<string, string>();
        }
    }

    private static IEnumerable<string> SearchPaths()
    {
        string baseDir = AppContext.BaseDirectory;
        yield return Path.Combine(baseDir, "i18n");
        // Running from the checkout (dotnet run) the folder sits in the repo root.
        yield return Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "i18n"));
    }
}
