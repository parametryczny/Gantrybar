using System.IO;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>
/// Resolves HMS error codes to human-readable text using Bambu Studio's bundled HMS files,
/// ported from the macOS HMSResolver. Looks the app up in the usual Windows install locations.
/// </summary>
public static class HmsResolver
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, Dictionary<string, string>> Cache = new();

    public static string? Description(IReadOnlyList<string> codes, string serial, string languageCode)
    {
        if (codes.Count == 0) return null;
        string prefix = (serial.Length >= 3 ? serial[..3] : serial).ToUpperInvariant();
        var lookup = Messages(prefix, languageCode);
        foreach (var code in codes)
        {
            var normalized = Normalize(code);
            if (lookup.TryGetValue(normalized, out var message) && message.Length > 0)
                return message;
        }
        return codes.Count > 0 ? $"HMS {codes[0]}" : null;
    }

    private static Dictionary<string, string> Messages(string prefix, string languageCode)
    {
        string cacheKey = $"{languageCode}-{prefix}";
        lock (Gate)
        {
            if (Cache.TryGetValue(cacheKey, out var cached)) return cached;
            var result = new Dictionary<string, string>();
            var path = HmsFile(languageCode, prefix);
            if (path is not null)
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(path));
                    Collect(doc.RootElement, languageCode, result);
                }
                catch { /* leave empty */ }
            }
            Cache[cacheKey] = result;
            return result;
        }
    }

    private static string? HmsFile(string languageCode, string prefix)
    {
        foreach (var root in InstallRoots())
        {
            var candidate = Path.Combine(root, "resources", "hms", $"hms_{languageCode}_{prefix}.json");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
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
            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Object &&
                    item.TryGetProperty("ecode", out var ecode) && ecode.ValueKind == JsonValueKind.String &&
                    item.TryGetProperty("intro", out var intro) && intro.ValueKind == JsonValueKind.String &&
                    intro.GetString() is { Length: > 0 } introText)
                {
                    result[Normalize(ecode.GetString()!)] = introText.Normalize(System.Text.NormalizationForm.FormC);
                }
                else
                {
                    Collect(item, languageCode, result);
                }
            }
        }
        else if (value.ValueKind == JsonValueKind.Object)
        {
            if (value.TryGetProperty(languageCode, out var localized)) Collect(localized, languageCode, result);
            foreach (var prop in value.EnumerateObject())
                if (prop.Name != languageCode) Collect(prop.Value, languageCode, result);
        }
    }

    private static string Normalize(string code) => code.Replace("_", "").ToUpperInvariant();
}
