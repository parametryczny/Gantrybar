using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Gantry.Services;

/// <summary>Two-way LAN sync of Spoolbase, the printer list and display/notification settings between a
/// user's own computers (macOS, Windows, Linux share the same /api/sync contract). No cloud: each
/// computer talks HTTP directly to paired peers, authorised by a single shared token the user copies
/// from one machine to the other. GantryWebServer serves and receives the snapshots.</summary>
public sealed class SyncService
{
    public static SyncService? Shared { get; private set; }

    private readonly PrinterStore _store;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };
    private bool _applyingRemote;

    public string DeviceId { get; }
    public string Token { get; private set; }
    public List<SyncPeer> Peers { get; private set; }
    private DateTime _settingsClock;

    public event Action? Changed;
    public static string DeviceName => Environment.MachineName;

    public SyncService(PrinterStore store)
    {
        _store = store;
        DeviceId = Defaults.GetString("sync-device-id") ?? Persist("sync-device-id", Guid.NewGuid().ToString());
        Token = Defaults.GetString("sync-token") ?? Persist("sync-token", MakeToken());
        Peers = LoadPeers();
        var clockRaw = Defaults.GetString("sync-settings-updated-at");
        _settingsClock = clockRaw != null && long.TryParse(clockRaw, out var ticks) ? new DateTime(ticks, DateTimeKind.Utc) : DateTime.MinValue;
        Shared = this;
    }

    private static string Persist(string key, string value) { Defaults.SetString(key, value); return value; }

    // MARK: token & peers

    public static string MakeToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(8);
        var hex = Convert.ToHexString(bytes);   // uppercase
        var groups = new List<string> { "GANTRY" };
        for (int i = 0; i < hex.Length; i += 4) groups.Add(hex.Substring(i, 4));
        return string.Join('-', groups);
    }

    public void RegenerateToken() { Token = Persist("sync-token", MakeToken()); Changed?.Invoke(); }

    public void SetToken(string token)
    {
        var t = token.Trim();
        if (t.Length == 0) return;
        Token = Persist("sync-token", t);
        Changed?.Invoke();
    }

    public void AddPeer(string rawAddress)
    {
        var address = Normalize(rawAddress);
        if (address.Length == 0 || Peers.Any(p => p.Address == address)) return;
        Peers.Add(new SyncPeer { Name = address, Address = address });
        SavePeers();
        Changed?.Invoke();
        SyncNow();
    }

    public void RemovePeer(string id)
    {
        Peers.RemoveAll(p => p.Id == id);
        SavePeers();
        Changed?.Invoke();
    }

    /// <summary>Accepts "gantry.local", "192.168.1.20", "host:8787" and normalises to host[:port] with the
    /// default web-server port when none was given. Strips any scheme the user pasted.</summary>
    public static string Normalize(string address)
    {
        var v = address.Trim();
        foreach (var scheme in new[] { "http://", "https://" })
            if (v.StartsWith(scheme, StringComparison.OrdinalIgnoreCase)) v = v.Substring(scheme.Length);
        v = v.Trim('/');
        if (v.Length == 0) return "";
        if (!v.Contains(':')) v += ":" + GantryWebServer.Port;
        return v;
    }

    private List<SyncPeer> LoadPeers()
    {
        var raw = Defaults.GetRaw("sync-peers");
        if (raw is null) return new();
        try { return JsonSerializer.Deserialize<List<SyncPeer>>(raw) ?? new(); } catch { return new(); }
    }
    private void SavePeers() => Defaults.SetRaw("sync-peers", JsonSerializer.Serialize(Peers));

    // MARK: snapshot build / apply

    public SyncSnapshot LocalSnapshot() => new()
    {
        DeviceID = DeviceId,
        DeviceName = DeviceName,
        GeneratedAt = DateTime.UtcNow,
        Spools = SpoolbaseShared.Spools.Spools.ToList(),
        UsageEvents = SpoolbaseShared.Spools.UsageEvents.ToList(),
        Catalog = SpoolbaseShared.Filaments.Filaments.ToList(),
        Printers = _store.Printers.Select(p => new SyncPrinter
        {
            Serial = p.Serial, Name = p.Name, Model = p.Model, Host = p.Host,
            Kind = SyncPrinter.KindToString(p.Kind), Port = p.Port
        }).ToList(),
        Settings = CurrentSettings(),
    };

    public void Apply(SyncSnapshot remote)
    {
        bool changed = false;
        changed |= SpoolbaseShared.Spools.MergeRemote(remote.Spools, remote.UsageEvents);
        changed |= SpoolbaseShared.Filaments.MergeRemote(remote.Catalog);
        changed |= _store.MergeRemote(remote.Printers);
        if (remote.Settings is { } s && s.UpdatedAt > _settingsClock)
        {
            ApplySettings(s);
            _settingsClock = s.UpdatedAt;
            Defaults.SetString("sync-settings-updated-at", _settingsClock.Ticks.ToString());
            changed = true;
        }
        if (changed) Changed?.Invoke();
    }

    /// <summary>Called by the Settings window when a synced setting changes, so the newer side wins.</summary>
    public void NoteSettingsChanged()
    {
        if (_applyingRemote) return;
        _settingsClock = DateTime.UtcNow;
        Defaults.SetString("sync-settings-updated-at", _settingsClock.Ticks.ToString());
    }

    private SyncSettings CurrentSettings() => new()
    {
        UpdatedAt = _settingsClock,
        Theme = "dark",
        Language = AppSettings.Polish ? "pl" : "en",
        PanelTransparency = AppSettings.PanelTransparency switch { 0 => "low", 2 => "high", _ => "medium" },
        SpoolbaseEnabled = AppSettings.SpoolbaseEnabled,
        WebDashboardEnabled = AppSettings.WebDashboardEnabled,
        Monochrome = AppSettings.Monochrome,
        AutoUpdate = AppSettings.AutoUpdate,
        CardShowFileName = AppSettings.CardShowFileName,
        CardShowProgress = AppSettings.CardShowProgress,
        CardShowTemperatures = AppSettings.CardShowTemperatures,
        CardShowFilaments = AppSettings.CardShowFilaments,
        NotifyFinished = AppSettings.NotifyPrintFinished,
        NotifyError = AppSettings.NotifyPrinterError,
        NotifyPaused = AppSettings.NotifyPrintPaused,
        NotifyLowFilament = AppSettings.NotifyLowFilament,
        NotifyHumidity = AppSettings.NotifyHighAmsHumidity,
    };

    private void ApplySettings(SyncSettings v)
    {
        _applyingRemote = true;
        try
        {
            // Only accept a language this machine actually has a catalog for, so a peer on a newer
            // build cannot strand it on a code it cannot render.
            if (Translations.Available().Any(entry => entry.Code == v.Language)) AppSettings.Language = v.Language;
            AppSettings.PanelTransparency = v.PanelTransparency switch { "low" => 0, "high" => 2, _ => 1 };
            AppSettings.SpoolbaseEnabled = v.SpoolbaseEnabled;
            AppSettings.WebDashboardEnabled = v.WebDashboardEnabled;
            if (v.Monochrome is { } mono) AppSettings.Monochrome = mono;
            AppSettings.AutoUpdate = v.AutoUpdate;
            AppSettings.CardShowFileName = v.CardShowFileName;
            AppSettings.CardShowProgress = v.CardShowProgress;
            AppSettings.CardShowTemperatures = v.CardShowTemperatures;
            AppSettings.CardShowFilaments = v.CardShowFilaments;
            AppSettings.NotifyPrintFinished = v.NotifyFinished;
            AppSettings.NotifyPrinterError = v.NotifyError;
            AppSettings.NotifyPrintPaused = v.NotifyPaused;
            AppSettings.NotifyLowFilament = v.NotifyLowFilament;
            AppSettings.NotifyHighAmsHumidity = v.NotifyHumidity;
        }
        finally { _applyingRemote = false; }
    }

    // MARK: sync over HTTP (pull peer, then push ours)

    public async void SyncNow()
    {
        if (Peers.Count == 0) return;
        var snapshot = LocalSnapshot();
        foreach (var peer in Peers.ToList()) await SyncOne(peer, snapshot);
    }

    private async Task SyncOne(SyncPeer peer, SyncSnapshot snapshot)
    {
        try
        {
            var remote = await Exchange(peer, HttpMethod.Get, null);
            if (remote != null) Apply(remote);
            await Exchange(peer, HttpMethod.Post, snapshot);
            UpdatePeer(peer.Id, p => { p.LastSyncAt = DateTime.UtcNow; p.LastError = null; });
        }
        catch (Exception ex)
        {
            UpdatePeer(peer.Id, p => p.LastError = ex.Message);
        }
    }

    private async Task<SyncSnapshot?> Exchange(SyncPeer peer, HttpMethod method, SyncSnapshot? body)
    {
        using var req = new HttpRequestMessage(method, $"http://{peer.Address}/api/sync");
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Token);
        if (body != null)
            req.Content = new StringContent(JsonSerializer.Serialize(body, SyncJson.Options), Encoding.UTF8, "application/json");
        using var resp = await _http.SendAsync(req);
        if ((int)resp.StatusCode == 401) throw new Exception("Token odrzucony (401).");
        var text = await resp.Content.ReadAsStringAsync();
        try { return JsonSerializer.Deserialize<SyncSnapshot>(text, SyncJson.Options); } catch { return null; }
    }

    private void UpdatePeer(string id, Action<SyncPeer> transform)
    {
        var peer = Peers.FirstOrDefault(p => p.Id == id);
        if (peer is null) return;
        transform(peer);
        SavePeers();
        Changed?.Invoke();
    }

    /// <summary>Validates a bearer token presented by an incoming request.</summary>
    public bool Authorize(string? authorization)
    {
        if (authorization is null) return false;
        var presented = authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? authorization.Substring(7) : authorization;
        return presented == Token;
    }
}
