using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>
/// The Wi-Fi socket or power-strip outlet that feeds a printer. Same JSON as macOS and GNU/Linux
/// (<c>smart-plugs-v1</c>, keyed by printer serial). The password or Home Assistant token is kept in
/// the DPAPI store under <c>smart-plug:&lt;serial&gt;</c>, never in the defaults.
/// </summary>
public sealed class SmartPlug
{
    public static readonly string[] Kinds = { "tasmota", "shelly", "shellyRPC", "homeAssistant", "http" };

    [JsonPropertyName("kind")] public string Kind { get; set; } = "tasmota";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("channel")] public int Channel { get; set; } = 1;
    [JsonPropertyName("entityID")] public string? EntityId { get; set; }
    [JsonPropertyName("onURL")] public string? OnUrl { get; set; }
    [JsonPropertyName("offURL")] public string? OffUrl { get; set; }
    [JsonPropertyName("username")] public string? Username { get; set; }
    [JsonPropertyName("autoOffMinutes")] public int? AutoOffMinutes { get; set; }
    [JsonPropertyName("includeInEmergency")] public bool IncludeInEmergency { get; set; } = true;

    public static string KindTitle(string kind) => kind switch
    {
        "tasmota" => "Tasmota",
        "shelly" => "Shelly Gen1",
        "shellyRPC" => "Shelly Plus / Pro / Gen3",
        "homeAssistant" => "Home Assistant",
        _ => AppSettings.T("Custom URLs"),
    };

    public string? Problem
    {
        get
        {
            switch (Kind)
            {
                case "tasmota": case "shelly": case "shellyRPC":
                    return string.IsNullOrWhiteSpace(Host) ? AppSettings.T("Enter the socket's IP address.") : null;
                case "homeAssistant":
                    if (string.IsNullOrWhiteSpace(Host)) return AppSettings.T("Enter the Home Assistant address.");
                    if (string.IsNullOrWhiteSpace(EntityId)) return AppSettings.T("Enter the Home Assistant entity, e.g. switch.printer.");
                    return null;
                default:
                    return string.IsNullOrWhiteSpace(OnUrl) || string.IsNullOrWhiteSpace(OffUrl) ? AppSettings.T("Enter both URLs.") : null;
            }
        }
    }

    private string Base()
    {
        string raw = Host.Trim();
        string withScheme = raw.Contains("://") ? raw : "http://" + raw;
        return withScheme.TrimEnd('/');
    }

    /// <summary>The request that switches the socket, or reads it when <paramref name="on"/> is null.</summary>
    public HttpRequestMessage? Request(bool? on, string? secret)
    {
        int channel = Math.Max(1, Channel);
        HttpRequestMessage? request = null;
        switch (Kind)
        {
            case "tasmota":
            {
                string command = $"Power{channel}" + (on is { } value ? (value ? " On" : " Off") : "");
                string url = $"{Base()}/cm?cmnd={Uri.EscapeDataString(command)}";
                if (!string.IsNullOrEmpty(secret))
                    url += $"&user={Uri.EscapeDataString(string.IsNullOrEmpty(Username) ? "admin" : Username)}&password={Uri.EscapeDataString(secret)}";
                request = new HttpRequestMessage(HttpMethod.Get, url);
                break;
            }
            case "shelly":
                request = new HttpRequestMessage(HttpMethod.Get,
                    $"{Base()}/relay/{channel - 1}" + (on is { } turn ? $"?turn={(turn ? "on" : "off")}" : ""));
                break;
            case "shellyRPC":
                request = new HttpRequestMessage(HttpMethod.Get, on is { } set
                    ? $"{Base()}/rpc/Switch.Set?id={channel - 1}&on={(set ? "true" : "false")}"
                    : $"{Base()}/rpc/Switch.GetStatus?id={channel - 1}");
                break;
            case "homeAssistant":
            {
                string entity = (EntityId ?? "").Trim();
                if (on is { } power)
                {
                    request = new HttpRequestMessage(HttpMethod.Post, $"{Base()}/api/services/homeassistant/turn_{(power ? "on" : "off")}")
                    {
                        Content = new StringContent(JsonSerializer.Serialize(new Dictionary<string, string> { ["entity_id"] = entity }),
                                                    Encoding.UTF8, "application/json"),
                    };
                }
                else request = new HttpRequestMessage(HttpMethod.Get, $"{Base()}/api/states/{Uri.EscapeDataString(entity)}");
                if (!string.IsNullOrEmpty(secret)) request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + secret);
                break;
            }
            default:
                if (on is not { } change) return null;
                string target = ((change ? OnUrl : OffUrl) ?? "").Trim();
                if (!Uri.TryCreate(target, UriKind.Absolute, out var uri)) return null;
                request = new HttpRequestMessage(HttpMethod.Get, uri);
                break;
        }
        return request;
    }

    /// <summary>Reads "on" out of a device's reply; null when the reply does not say.</summary>
    public static bool? ParseState(string kind, int channel, string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            var root = document.RootElement;
            bool? Word(string name)
            {
                if (!root.TryGetProperty(name, out var value)) return null;
                return value.ValueKind switch
                {
                    JsonValueKind.True => true,
                    JsonValueKind.False => false,
                    JsonValueKind.String => value.GetString()?.ToLowerInvariant() switch
                    {
                        "on" or "true" or "1" => true,
                        "off" or "false" or "0" => false,
                        _ => null,
                    },
                    JsonValueKind.Number => value.GetDouble() != 0,
                    _ => null,
                };
            }
            return kind switch
            {
                "tasmota" => Word($"POWER{channel}") ?? (channel == 1 ? Word("POWER") : null),
                "shelly" => Word("ison"),
                "shellyRPC" => Word("output"),
                "homeAssistant" => Word("state"),
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    /// <summary>Switches the socket (or reads it when <paramref name="on"/> is null) and returns what it
    /// reports. Shelly logins are answered by HttpClient: basic for Gen1, digest for Gen2 and later.</summary>
    public async Task<bool?> SendAsync(bool? on, string? secret)
    {
        if (Problem is { } problem) throw new InvalidOperationException(problem);
        using var request = Request(on, secret) ?? throw new InvalidOperationException(AppSettings.T("The address is not a valid URL."));
        var handler = new HttpClientHandler();
        if (!string.IsNullOrEmpty(secret) && Kind is "shelly" or "shellyRPC")
            handler.Credentials = new NetworkCredential(string.IsNullOrEmpty(Username) ? "admin" : Username, secret);
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(6) };
        HttpResponseMessage response;
        try { response = await http.SendAsync(request).ConfigureAwait(false); }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            throw new InvalidOperationException(ex.Message, ex);
        }
        using (response)
        {
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new InvalidOperationException(AppSettings.T("The socket refused the login. Check the password or token."));
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException(AppSettings.T("The socket answered with HTTP {0}.").Replace("{0}", ((int)response.StatusCode).ToString()));
            return ParseState(Kind, Math.Max(1, Channel), await response.Content.ReadAsStringAsync().ConfigureAwait(false));
        }
    }
}

public static class SmartPlugStore
{
    private const string Key = "smart-plugs-v1";
    public static event Action? Changed;

    private static Dictionary<string, SmartPlug> All()
    {
        var raw = Defaults.GetRaw(Key);
        if (raw is null) return new();
        try { return JsonSerializer.Deserialize<Dictionary<string, SmartPlug>>(raw) ?? new(); }
        catch { return new(); }
    }

    public static SmartPlug? Plug(string serial) => All().TryGetValue(serial, out var plug) ? plug : null;
    public static IReadOnlyCollection<string> Serials => All().Keys;
    public static bool IsEmpty => All().Count == 0;

    public static string SecretKey(string serial) => "smart-plug:" + serial;
    public static string? Secret(string serial) => AccessCodeStore.AccessCode(SecretKey(serial));

    public static void Set(string serial, SmartPlug? plug, string? secret)
    {
        var all = All();
        if (plug is null) all.Remove(serial); else all[serial] = plug;
        Defaults.SetRaw(Key, JsonSerializer.Serialize(all));
        if (plug is not null && !string.IsNullOrEmpty(secret)) AccessCodeStore.Save(secret, SecretKey(serial));
        else AccessCodeStore.Delete(SecretKey(serial));
        Changed?.Invoke();
    }
}

/// <summary>Switches printers' sockets, the emergency "everything off", and switching off some minutes
/// after a print. Mirrors macOS SmartPlugController. Called on the UI thread.</summary>
public static class SmartPlugController
{
    private static PrinterStore? _store;
    private static readonly Dictionary<string, PrinterState> LastStates = new();
    private static readonly Dictionary<string, CancellationTokenSource> AutoOff = new();

    public static void Attach(PrinterStore store)
    {
        _store = store;
        store.Updated += (_, _) => Observe();
    }

    public static bool HasPlugs => !SmartPlugStore.IsEmpty;

    private static string Name(string serial) => _store?.Printers.FirstOrDefault(p => p.Serial == serial)?.Name ?? serial;

    private static bool IsBusy(string serial) =>
        _store?.Telemetry.TryGetValue(serial, out var t) == true && t.State is PrinterState.Printing or PrinterState.Paused;

    private static void OnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action(); else dispatcher.BeginInvoke(action);
    }

    public static void Power(bool on, string serial, bool confirmIfPrinting = true, string? reason = null)
    {
        var plug = SmartPlugStore.Plug(serial);
        string printer = Name(serial);
        if (plug is null)
        {
            NotificationService.Post(printer, AppSettings.T("No smart socket is set up for this printer."));
            return;
        }
        if (!on && confirmIfPrinting && IsBusy(serial))
        {
            var answer = MessageBox.Show(
                AppSettings.T("The printer is printing. Cutting the power ends the print and it cannot be resumed."),
                AppSettings.T("Cut the power to {0}?").Replace("{0}", printer),
                MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel);
            if (answer != MessageBoxResult.OK) return;
        }
        if (!on && AutoOff.Remove(serial, out var pending)) pending.Cancel();
        string? secret = SmartPlugStore.Secret(serial);
        _ = Task.Run(async () =>
        {
            try
            {
                await plug.SendAsync(on, secret).ConfigureAwait(false);
                string title = on ? AppSettings.T("Socket switched on") : AppSettings.T("Socket switched off");
                OnUi(() => NotificationService.Post(title, reason is null ? printer : AppSettings.T("Automation: {0}").Replace("{0}", reason), printer));
                TelegramService.Notify(printer, title, reason ?? "");
            }
            catch (Exception ex)
            {
                OnUi(() => NotificationService.Post(AppSettings.T("Could not switch the socket"), ex.Message, printer));
                TelegramService.Notify(printer, AppSettings.T("Could not switch the socket"), ex.Message);
            }
        });
    }

    private static T OnUiResult<T>(Func<T> body)
    {
        var dispatcher = Application.Current?.Dispatcher;
        return dispatcher is null || dispatcher.CheckAccess() ? body() : dispatcher.Invoke(body);
    }

    /// <summary>Safe from any thread (the Telegram bot calls it from its own).</summary>
    public static async Task<List<string>> EmergencyOffAsync()
    {
        var jobs = OnUiResult(() =>
        {
            foreach (var pending in AutoOff.Values) pending.Cancel();
            AutoOff.Clear();
            return SmartPlugStore.Serials
                .Select(serial => (Serial: serial, Printer: Name(serial), Plug: SmartPlugStore.Plug(serial), Secret: SmartPlugStore.Secret(serial)))
                .Where(job => job.Plug is { IncludeInEmergency: true })
                .ToList();
        });
        // Every request leaves at once; a socket that does not answer must not hold up the others.
        var results = await Task.WhenAll(jobs.Select(async job =>
        {
            try { await job.Plug!.SendAsync(false, job.Secret).ConfigureAwait(false); return (job.Printer, Failure: (string?)null); }
            catch (Exception ex) { return (job.Printer, Failure: (string?)ex.Message); }
        })).ConfigureAwait(false);
        var lines = results.OrderBy(result => result.Printer, StringComparer.CurrentCulture)
            .Select(result => result.Failure is null ? $"✓ {result.Printer}" : $"✕ {result.Printer}: {result.Failure}").ToList();
        int failed = results.Count(result => result.Failure is not null);
        string title = failed == 0 ? AppSettings.T("Emergency: every socket is off")
                                   : AppSettings.T("Emergency: {0} sockets did not switch off").Replace("{0}", failed.ToString());
        OnUi(() => NotificationService.Post(title, string.Join("\n", lines)));
        TelegramService.Notify("Gantry", title, string.Join("\n", lines));
        return lines;
    }

    /// <summary>The button: one question, then everything off at once.</summary>
    public static async void ConfirmEmergencyOff()
    {
        int count = SmartPlugStore.Serials.Count(serial => SmartPlugStore.Plug(serial)?.IncludeInEmergency == true);
        if (count == 0)
        {
            MessageBox.Show(AppSettings.T("Add a socket to a printer: its card ⋯ menu → Power → Set up socket…"),
                            AppSettings.T("No smart sockets are set up"));
            return;
        }
        var names = SmartPlugStore.Serials
            .Where(serial => SmartPlugStore.Plug(serial)?.IncludeInEmergency == true)
            .Select(Name).OrderBy(name => name, StringComparer.CurrentCulture).ToList();
        if (!Gantry.UI.EmergencyWindow.Confirm(names)) return;
        try
        {
            var lines = await EmergencyOffAsync();
            MessageBox.Show(string.Join("\n", lines), AppSettings.T("Emergency power-off"));
        }
        catch (Exception ex) { Gantry.App.LogError("EmergencyOff", ex); }
    }

    private static void Observe()
    {
        if (_store is null) return;
        foreach (var (serial, telemetry) in _store.Telemetry.ToList())
        {
            LastStates.TryGetValue(serial, out var previous);
            bool known = LastStates.ContainsKey(serial);
            LastStates[serial] = telemetry.State;
            if (telemetry.State is PrinterState.Printing or PrinterState.Paused)
            {
                if (AutoOff.Remove(serial, out var running)) running.Cancel();
                continue;
            }
            if (telemetry.State != PrinterState.Finished || !known || previous == PrinterState.Finished) continue;
            if (SmartPlugStore.Plug(serial)?.AutoOffMinutes is not { } minutes || minutes <= 0) continue;
            if (AutoOff.Remove(serial, out var old)) old.Cancel();
            var cancel = new CancellationTokenSource();
            AutoOff[serial] = cancel;
            _ = Task.Delay(TimeSpan.FromMinutes(minutes), cancel.Token).ContinueWith(task =>
            {
                if (task.IsCanceled) return;
                OnUi(() =>
                {
                    AutoOff.Remove(serial);
                    // Somebody may have started the next print in the meantime.
                    if (IsBusy(serial)) return;
                    Power(false, serial, confirmIfPrinting: false,
                          reason: AppSettings.T("{0} min after the print finished").Replace("{0}", minutes.ToString()));
                });
            }, TaskScheduler.Default);
        }
    }
}
