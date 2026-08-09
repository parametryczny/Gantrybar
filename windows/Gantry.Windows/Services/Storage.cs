using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>
/// Key/value store persisted to %AppData%\Gantry\defaults.json — the Windows equivalent
/// of the macOS UserDefaults suite used across the app.
/// </summary>
public static class Defaults
{
    private static readonly object Gate = new();
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Gantry");
    // Pre-rebrand data location; migrated once so upgrades keep saved printers, pins and settings.
    private static readonly string LegacyDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BambuBar");
    private static readonly string FilePath = Path.Combine(Dir, "defaults.json");
    private static Dictionary<string, JsonElement> _store = Load();

    private static Dictionary<string, JsonElement> Load()
    {
        try
        {
            // One-time, non-destructive adoption of settings saved by the pre-rebrand app.
            if (!File.Exists(FilePath) && Directory.Exists(LegacyDir))
            {
                try
                {
                    Directory.CreateDirectory(Dir);
                    foreach (var file in Directory.GetFiles(LegacyDir))
                    {
                        var target = Path.Combine(Dir, Path.GetFileName(file));
                        if (!File.Exists(target)) File.Copy(file, target);
                    }
                }
                catch { /* best effort */ }
            }
            if (File.Exists(FilePath))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(FilePath));
                var dict = new Dictionary<string, JsonElement>();
                foreach (var prop in doc.RootElement.EnumerateObject())
                    dict[prop.Name] = prop.Value.Clone();
                return dict;
            }
        }
        catch { /* fall through to empty */ }
        return new Dictionary<string, JsonElement>();
    }

    private static void Persist()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            using var stream = File.Create(FilePath);
            using var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true });
            writer.WriteStartObject();
            foreach (var kv in _store)
            {
                writer.WritePropertyName(kv.Key);
                kv.Value.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        catch { /* best effort */ }
    }

    private static JsonElement Wrap(object value)
        => JsonSerializer.SerializeToElement(value);

    public static string? GetString(string key)
        => _store.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public static void SetString(string key, string value)
    {
        lock (Gate) { _store[key] = Wrap(value); Persist(); }
    }

    public static bool GetBool(string key, bool fallback = false)
        => _store.TryGetValue(key, out var v) && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False)
            ? v.GetBoolean() : fallback;

    public static void SetBool(string key, bool value)
    {
        lock (Gate) { _store[key] = Wrap(value); Persist(); }
    }

    public static int GetInt(string key, int fallback = 0)
        => _store.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : fallback;

    public static void SetInt(string key, int value)
    {
        lock (Gate) { _store[key] = Wrap(value); Persist(); }
    }

    public static Dictionary<string, string> GetStringDictionary(string key)
    {
        if (_store.TryGetValue(key, out var v) && v.ValueKind == JsonValueKind.Object)
        {
            var dict = new Dictionary<string, string>();
            foreach (var prop in v.EnumerateObject())
                if (prop.Value.ValueKind == JsonValueKind.String)
                    dict[prop.Name] = prop.Value.GetString()!;
            return dict;
        }
        return new Dictionary<string, string>();
    }

    public static void SetStringDictionary(string key, Dictionary<string, string> value)
    {
        lock (Gate) { _store[key] = Wrap(value); Persist(); }
    }

    public static string? GetRaw(string key)
        => _store.TryGetValue(key, out var v) ? v.GetRawText() : null;

    public static void SetRaw(string key, string json)
    {
        lock (Gate)
        {
            using var doc = JsonDocument.Parse(json);
            _store[key] = doc.RootElement.Clone();
            Persist();
        }
    }
}

/// <summary>User-facing settings mirroring the macOS AppSettings.</summary>
public static class AppSettings
{
    private static readonly string[] SupportedLanguages = ["pl", "en", "de"];
    public static event Action? LanguageChanged;

    public static string Language
    {
        get
        {
            var stored = Defaults.GetString("app-language");
            return stored is not null && SupportedLanguages.Contains(stored) ? stored : DefaultLanguage();
        }
        set
        {
            string normalized = SupportedLanguages.Contains(value) ? value : DefaultLanguage();
            if (normalized == Language) return;
            Defaults.SetString("app-language", normalized);
            LanguageChanged?.Invoke();
        }
    }

    public static string LanguageDisplayName => Language switch
    {
        "pl" => "Polski",
        "de" => "Deutsch",
        _ => "English",
    };

    public static string LanguageShortName => Language.ToUpperInvariant();

    public static void CycleLanguage()
        => Language = Language switch { "pl" => "en", "en" => "de", _ => "pl" };

    public static bool CompactMode
    {
        get => Defaults.GetBool("dashboard-compact-mode");
        set => Defaults.SetBool("dashboard-compact-mode", value);
    }

    public static bool CompactModeChosen
    {
        get => Defaults.GetBool("dashboard-compact-mode-set");
        set => Defaults.SetBool("dashboard-compact-mode-set", value);
    }

    public static bool NotifyPrintFinished
    {
        get => Defaults.GetBool("notifications-print-finished", true);
        set => Defaults.SetBool("notifications-print-finished", value);
    }

    public static bool NotifyPrinterError
    {
        get => Defaults.GetBool("notifications-printer-error", true);
        set => Defaults.SetBool("notifications-printer-error", value);
    }

    public static bool NotifyPrintPaused
    {
        get => Defaults.GetBool("notifications-print-paused", true);
        set => Defaults.SetBool("notifications-print-paused", value);
    }

    public static bool NotifyLowFilament
    {
        get => Defaults.GetBool("notifications-low-filament", true);
        set => Defaults.SetBool("notifications-low-filament", value);
    }

    public static bool NotifyHighAmsHumidity
    {
        get => Defaults.GetBool("notifications-high-ams-humidity", true);
        set => Defaults.SetBool("notifications-high-ams-humidity", value);
    }

    /// Extra discovery targets (IPs / CIDR / ranges) scanned in addition to the local subnet — lets a
    /// printer reached over a VPN like Tailscale be found.
    public static string SubnetScanTargets
    {
        get => Defaults.GetString("discovery-subnet-targets") ?? string.Empty;
        set => Defaults.SetString("discovery-subnet-targets", value.Trim());
    }

    public static string Text(string polish, string english, string german)
        => TextForLanguage(Language, polish, english, german);

    internal static string TextForLanguage(string language, string polish, string english, string german)
        => language switch { "pl" => polish, "de" => german, _ => english };

    internal static string LanguageForCulture(string? cultureName)
    {
        var code = cultureName?.Split('-', '_')[0].ToLowerInvariant();
        return code is "pl" or "de" ? code : "en";
    }

    private static string DefaultLanguage()
        => LanguageForCulture(System.Globalization.CultureInfo.CurrentUICulture.Name);

    internal static void RunLocalizationSelfTest()
    {
        if (LanguageForCulture("pl-PL") != "pl" || LanguageForCulture("de-DE") != "de" ||
            LanguageForCulture("fr-FR") != "en" || LanguageForCulture(null) != "en")
            throw new InvalidOperationException("Language detection self-test failed.");
        if (TextForLanguage("de", "Gotowa", "Ready", "Bereit") != "Bereit" ||
            TextForLanguage("unknown", "Gotowa", "Ready", "Bereit") != "Ready")
            throw new InvalidOperationException("Language selection self-test failed.");
        var telemetry = new PrinterTelemetry { State = PrinterState.Printing, CurrentStage = 13 };
        if (telemetry.ActivityLabel("de") != "Referenzfahrt")
            throw new InvalidOperationException("German print-stage self-test failed.");
    }
}

/// <summary>Persists the configured printer list (saved-printers-v1), same schema as macOS.</summary>
public static class SavedPrinterStore
{
    private const string Key = "saved-printers-v1";

    public static List<SavedPrinter> Load()
    {
        var raw = Defaults.GetRaw(Key);
        if (raw is null) return new List<SavedPrinter>();
        try { return JsonSerializer.Deserialize<List<SavedPrinter>>(raw) ?? new(); }
        catch { return new List<SavedPrinter>(); }
    }

    public static void Save(List<SavedPrinter> printers)
        => Defaults.SetRaw(Key, JsonSerializer.Serialize(printers));
}

/// <summary>
/// Stores each printer access code encrypted with Windows DPAPI (per-user) — the Windows
/// counterpart of the macOS Keychain. Encrypted blobs live in defaults under a dedicated key.
/// </summary>
public static class AccessCodeStore
{
    public const string ModeName = "DPAPI";
    private const string Key = "printer-access-codes-dpapi-v1";
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("pl.gantry.access-code.v1");

    public static void Save(string accessCode, string serial)
    {
        if (string.IsNullOrEmpty(accessCode)) throw new ArgumentException("empty access code");
        var protectedBytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(accessCode), Entropy, DataProtectionScope.CurrentUser);
        var dict = Defaults.GetStringDictionary(Key);
        dict[serial] = Convert.ToBase64String(protectedBytes);
        Defaults.SetStringDictionary(Key, dict);
    }

    public static string? AccessCode(string serial)
    {
        var dict = Defaults.GetStringDictionary(Key);
        if (!dict.TryGetValue(serial, out var stored)) return null;
        try
        {
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(stored), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch { return null; }
    }

    public static string ReadAccessCode(string serial)
        => AccessCode(serial) ?? throw new InvalidOperationException(
            AppSettings.Text("Brak zapisanego kodu dostępu.", "No stored access code.", "Kein Zugriffscode gespeichert."));

    public static void Delete(string serial)
    {
        var dict = Defaults.GetStringDictionary(Key);
        if (dict.Remove(serial)) Defaults.SetStringDictionary(Key, dict);
    }
}
