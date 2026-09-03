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
    public static string Theme
    {
        get => Defaults.GetString("app-theme") is "light" ? "light" : "dark";
        set => Defaults.SetString("app-theme", value == "light" ? "light" : "dark");
    }

    public static bool Polish
    {
        get => (Defaults.GetString("app-language") ?? DefaultLanguage()) == "pl";
        set => Defaults.SetString("app-language", value ? "pl" : "en");
    }

    /// Developer mode: reveals the printer control + automations tile in the detail window.
    public static bool DeveloperMode
    {
        get => Defaults.GetBool("developer-mode");
        set => Defaults.SetBool("developer-mode", value);
    }

    /// Security kill switch for automation actions that execute code: "script" (runs a program on this
    /// PC) and "command" (sends an arbitrary raw MQTT/G-code command to the printer). OFF by default so a
    /// tampered or planted automation config cannot run code silently — the same class of issue as
    /// KeePass triggers (CVE-2023-24055). The rule engine refuses these actions unless this is enabled.
    public static bool AllowScriptActions
    {
        get => Defaults.GetBool("allow-script-actions", false);
        set => Defaults.SetBool("allow-script-actions", value);
    }

    /// Ids of script/command rules the user has explicitly approved (per-rule, first-run consent), so
    /// the confirmation prompt only appears once per rule rather than on every trigger.
    public static bool IsScriptRuleApproved(string id)
        => (Defaults.GetString("approved-script-rules") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Contains(id);

    public static void ApproveScriptRule(string id)
    {
        var set = new HashSet<string>((Defaults.GetString("approved-script-rules") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries));
        if (set.Add(id)) Defaults.SetString("approved-script-rules", string.Join("\n", set));
    }

    public static bool CompactMode
    {
        get => Defaults.GetBool("dashboard-compact-mode");
        set => Defaults.SetBool("dashboard-compact-mode", value);
    }

    // Panel background transparency: 0 = low (most opaque), 1 = medium, 2 = high (most see-through).
    // Affects only the panel backdrop, not the cards.
    public static int PanelTransparency
    {
        get => Math.Clamp(Defaults.GetInt("panel-transparency", 1), 0, 2);
        set => Defaults.SetInt("panel-transparency", Math.Clamp(value, 0, 2));
    }

    public static bool CompactModeChosen
    {
        get => Defaults.GetBool("dashboard-compact-mode-set");
        set => Defaults.SetBool("dashboard-compact-mode-set", value);
    }

    // Fleet grid columns in the expanded (card) view: 1 or 2, user-toggled (macOS parity).
    public static int DashboardColumns
    {
        get => Math.Clamp(Defaults.GetInt("dashboard-columns", 2), 1, 2);
        set => Defaults.SetInt("dashboard-columns", Math.Clamp(value, 1, 2));
    }

    // What each fleet card shows (Settings → "Karty drukarek"). All on by default.
    public static bool CardShowFileName
    {
        get => Defaults.GetBool("card-show-filename", true);
        set => Defaults.SetBool("card-show-filename", value);
    }
    public static bool CardShowProgress
    {
        get => Defaults.GetBool("card-show-progress", true);
        set => Defaults.SetBool("card-show-progress", value);
    }
    public static bool CardShowTemperatures
    {
        get => Defaults.GetBool("card-show-temps", true);
        set => Defaults.SetBool("card-show-temps", value);
    }
    public static bool CardShowFilaments
    {
        get => Defaults.GetBool("card-show-filaments", true);
        set => Defaults.SetBool("card-show-filaments", value);
    }
    /// <summary>Show remaining grams on the spool under AMS NFC / Spoolbase slots (off by default).</summary>
    public static bool CardShowSpoolGrams
    {
        get => Defaults.GetBool("card-show-spool-grams", false);
        set => Defaults.SetBool("card-show-spool-grams", value);
    }
    /// <summary>Calmer palette: temperatures stay grey and filament colours are muted toward grey.</summary>
    public static bool Monochrome
    {
        get => Defaults.GetBool("monochrome", false);
        set => Defaults.SetBool("monochrome", value);
    }

    // Whether the embedded Spoolbase filament-stock tool appears in the tray menu.
    public static bool SpoolbaseEnabled
    {
        get => Defaults.GetBool("spoolbase-enabled", true);
        set => Defaults.SetBool("spoolbase-enabled", value);
    }

    /// <summary>Whether the read-only LAN web dashboard (http://&lt;ip&gt;:8787) runs.</summary>
    public static bool WebDashboardEnabled
    {
        get => Defaults.GetBool("web-dashboard-enabled", true);
        set => Defaults.SetBool("web-dashboard-enabled", value);
    }

    // Download and install new releases automatically instead of only notifying about them.
    public static bool AutoUpdate
    {
        get => Defaults.GetBool("auto-update", false);
        set => Defaults.SetBool("auto-update", value);
    }

    public static bool NotifyPrintFinished
    {
        get => Defaults.GetBool("notifications-print-finished", true);
        set => Defaults.SetBool("notifications-print-finished", value);
    }

    /// Heads-up shortly before a job ends, so a long print can be collected without watching the ETA.
    /// Off by default: on a busy fleet it is one extra alert per job on top of the finished one.
    public static bool NotifyFinishingSoon
    {
        get => Defaults.GetBool("notify-finishing-soon", false);
        set => Defaults.SetBool("notify-finishing-soon", value);
    }

    /// Minutes of remaining print time that trigger the heads-up above.
    public static int FinishingSoonMinutes
    {
        get => Defaults.GetInt("notify-finishing-soon-minutes", 10);
        set => Defaults.SetInt("notify-finishing-soon-minutes", value);
    }

    // Edge dock: the narrow always-on-top strip pinned to a screen edge. Keys shared verbatim with
    // macOS/Linux. Off by default, because it is an opt-in second surface, not a tray replacement.
    public static bool EdgeDockEnabled
    {
        get => Defaults.GetBool("edge-dock-enabled", false);
        set => Defaults.SetBool("edge-dock-enabled", value);
    }

    /// "left" or "right"; anything else falls back to the right edge.
    public static string EdgeDockEdge
    {
        get { var s = Defaults.GetString("edge-dock-edge"); return s == "left" ? "left" : "right"; }
        set => Defaults.SetString("edge-dock-edge", value == "left" ? "left" : "right");
    }

    /// Hide printers that are neither printing nor paused.
    public static bool EdgeDockOnlyPrinting
    {
        get => Defaults.GetBool("edge-dock-only-printing", false);
        set => Defaults.SetBool("edge-dock-only-printing", value);
    }

    /// Serials the user unticked, stored as an exclusion list so a newly added printer shows up by
    /// itself instead of silently missing from the strip.
    public static HashSet<string> EdgeDockHiddenPrinters
    {
        get => new((Defaults.GetString("edge-dock-hidden") ?? "")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries));
        set => Defaults.SetString("edge-dock-hidden", string.Join("\n", value.OrderBy(x => x)));
    }

    // Telegram push + bot. Keys shared verbatim with macOS/Linux (see docs/telegram.md).
    public static bool TelegramEnabled
    {
        get => Defaults.GetBool("telegram-enabled", false);
        set => Defaults.SetBool("telegram-enabled", value);
    }
    public static string TelegramBotToken
    {
        get => Defaults.GetString("telegram-bot-token") ?? "";
        set => Defaults.SetString("telegram-bot-token", value);
    }
    public static string TelegramChatId
    {
        get => Defaults.GetString("telegram-chat-id") ?? "";
        set => Defaults.SetString("telegram-chat-id", value);
    }
    /// Alerts silenced (Telegram) until this UTC time; set by the bot's /mute. Null/past = not muted.
    public static DateTime? TelegramMuteUntil
    {
        get { var s = Defaults.GetString("telegram-mute-until"); return DateTime.TryParse(s, null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var d) && d > DateTime.UtcNow ? d : null; }
        set => Defaults.SetString("telegram-mute-until", value?.ToUniversalTime().ToString("o") ?? "");
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

    /// Order of the cards in the printer detail window, as a comma-separated list of card keys.
    /// Empty = default order. Shared across printers (like the macOS "detail-card-order").
    public static string DetailCardOrder
    {
        get => Defaults.GetString("detail-card-order") ?? string.Empty;
        set => Defaults.SetString("detail-card-order", value);
    }

    // Hidden detail modules (CSV of keys: camera, ams, temps, fans, control) — the "Dostosuj" menu.
    public static string DetailHiddenModules
    {
        get => Defaults.GetString("detail-hidden-modules") ?? string.Empty;
        set => Defaults.SetString("detail-hidden-modules", value);
    }

    public static string Text(string polish, string english) => Polish ? polish : english;

    private static string DefaultLanguage()
        => System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "pl" ? "pl" : "en";
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
            AppSettings.Text("Brak zapisanego kodu dostępu.", "No stored access code."));

    public static void Delete(string serial)
    {
        var dict = Defaults.GetStringDictionary(Key);
        if (dict.Remove(serial)) Defaults.SetStringDictionary(Key, dict);
    }
}
