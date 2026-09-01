using System.IO;
using System.Text;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Resolves Bambu HMS codes from every locally installed Bambu Studio model catalogue.</summary>
public static class HmsResolver
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, Dictionary<string, string>> Cache = new();

    public static IReadOnlyList<string> ActionableCodes(IReadOnlyList<string> codes, string serial, bool polish)
    {
        if (codes.Count == 0) return Array.Empty<string>();
        var lookup = Messages(polish ? "pl" : "en", serial);
        return codes.Where(code => !lookup.TryGetValue(Normalize(code), out var known) ||
                                   !string.IsNullOrWhiteSpace(known)).ToList();
    }

    public static string? Description(IReadOnlyList<string> codes, string serial, bool polish)
    {
        var actionable = ActionableCodes(codes, serial, polish);
        if (actionable.Count == 0) return null;
        var lookup = Messages(polish ? "pl" : "en", serial);
        foreach (var code in actionable)
            if (lookup.TryGetValue(Normalize(code), out var message) && !string.IsNullOrWhiteSpace(message))
                return message;
        return $"HMS {actionable[0]}";
    }

    private static Dictionary<string, string> Messages(string languageCode, string serial)
    {
        string cacheKey = $"{languageCode}-all-models";
        lock (Gate)
        {
            if (Cache.TryGetValue(cacheKey, out var cached)) return cached;
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string prefix = (serial.Length >= 3 ? serial[..3] : serial).ToUpperInvariant();
            string exactName = $"hms_{languageCode}_{prefix}.json";
            var files = HmsDirectories()
                .SelectMany(directory => SafeFiles(directory, $"hms_{languageCode}_*.json"))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(path => Path.GetFileName(path).Equals(exactName, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .ThenBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase);
            foreach (var path in files)
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(path));
                    Collect(doc.RootElement, languageCode, result);
                }
                catch { }
            }
            Cache[cacheKey] = result;
            return result;
        }
    }

    private static IEnumerable<string> SafeFiles(string directory, string pattern)
    {
        try { return Directory.Exists(directory) ? Directory.EnumerateFiles(directory, pattern) : Array.Empty<string>(); }
        catch { return Array.Empty<string>(); }
    }

    private static IEnumerable<string> HmsDirectories()
    {
        var configured = Environment.GetEnvironmentVariable("BAMBU_STUDIO_RESOURCES");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            yield return configured;
            yield return Path.Combine(configured, "hms");
        }
        foreach (var root in InstallRoots())
        {
            yield return Path.Combine(root, "resources", "hms");
            yield return Path.Combine(root, "Resources", "hms");
            yield return Path.Combine(root, "hms");
        }
    }

    private static IEnumerable<string> InstallRoots()
    {
        foreach (var special in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.LocalApplicationData })
        {
            var baseDir = Environment.GetFolderPath(special);
            if (string.IsNullOrEmpty(baseDir)) continue;
            yield return Path.Combine(baseDir, "Bambu Studio");
            yield return Path.Combine(baseDir, "BambuStudio");
            yield return Path.Combine(baseDir, "Programs", "Bambu Studio");
        }
    }

    private static void Collect(JsonElement value, string languageCode, Dictionary<string, string> result)
    {
        if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray()) Collect(item, languageCode, result);
            return;
        }
        if (value.ValueKind != JsonValueKind.Object) return;
        if (value.TryGetProperty("ecode", out var ecode) && ecode.ValueKind == JsonValueKind.String &&
            value.TryGetProperty("intro", out var intro) && intro.ValueKind == JsonValueKind.String)
        {
            var key = Normalize(ecode.GetString() ?? "");
            var message = (intro.GetString() ?? "").Normalize(NormalizationForm.FormC);
            if (!result.TryGetValue(key, out var old) || (old.Length == 0 && message.Length > 0)) result[key] = message;
        }
        if (value.TryGetProperty(languageCode, out var localized)) Collect(localized, languageCode, result);
        foreach (var prop in value.EnumerateObject())
            if (prop.Name is not ("ecode" or "intro") && prop.Name != languageCode) Collect(prop.Value, languageCode, result);
    }

    private static string Normalize(string code) => code.Replace("_", "").ToUpperInvariant();
}
