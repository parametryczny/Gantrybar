using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Gantry.Models;

namespace Gantry.Services;

/// <summary>Two-way Telegram bot (the C# mirror of the macOS TelegramBot): long-polls getUpdates, shows a
/// printer picker with per-printer controls and AMS tiles, and the commands /all /status /spools /history
/// /mute /watch /photo /help. Only the configured chat id may drive it. Store access is marshalled to the
/// UI thread. See docs/telegram.md.</summary>
public sealed class TelegramBot
{
    public static TelegramBot? Shared { get; private set; }

    private readonly PrinterStore _store;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(70) };
    private CancellationTokenSource? _cts;
    private CancellationTokenSource? _watchCts;
    private long _offset;

    public TelegramBot(PrinterStore store) { _store = store; Shared = this; }

    private static string Token => AppSettings.TelegramBotToken.Trim();
    private static string ChatId => AppSettings.TelegramChatId.Trim();

    public void SyncWithSettings()
    {
        bool configured = AppSettings.TelegramEnabled && Token.Length > 0 && ChatId.Length > 0;
        if (configured && _cts == null)
        {
            _cts = new CancellationTokenSource();
            _ = LoopAsync(_cts.Token);
        }
        else if (!configured && _cts != null)
        {
            _cts.Cancel(); _cts = null;
            _watchCts?.Cancel(); _watchCts = null;
        }
    }

    // Poll loop

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && AppSettings.TelegramEnabled && Token.Length > 0 && ChatId.Length > 0)
        {
            foreach (var update in await GetUpdatesAsync(ct))
            {
                if (ct.IsCancellationRequested) break;
                await HandleAsync(update);
            }
        }
    }

    private async Task<List<JsonElement>> GetUpdatesAsync(CancellationToken ct)
    {
        var root = await ApiAsync("getUpdates", new Dictionary<string, string>
        {
            ["offset"] = _offset.ToString(), ["timeout"] = "25",
            ["allowed_updates"] = "[\"message\",\"callback_query\"]"
        });
        if (root == null || !root.Value.TryGetProperty("result", out var result) || result.ValueKind != JsonValueKind.Array)
        {
            try { await Task.Delay(3000, ct); } catch { }
            return new();
        }
        var updates = result.EnumerateArray().ToList();
        foreach (var u in updates)
            if (u.TryGetProperty("update_id", out var id)) _offset = Math.Max(_offset, id.GetInt64() + 1);
        return updates;
    }

    // Routing

    private async Task HandleAsync(JsonElement update)
    {
        if (update.TryGetProperty("message", out var message))
        {
            if (!Authorized(message)) return;
            var text = message.TryGetProperty("text", out var t) ? (t.GetString() ?? "") : "";
            await HandleTextAsync(text.Trim());
        }
        else if (update.TryGetProperty("callback_query", out var callback))
        {
            var id = callback.TryGetProperty("id", out var cid) ? cid.GetString() ?? "" : "";
            int? messageId = callback.TryGetProperty("message", out var m) && m.TryGetProperty("message_id", out var mid) ? mid.GetInt32() : null;
            if (!Authorized(callback.TryGetProperty("message", out var cm) ? cm : default)) { await AnswerAsync(id, "Brak dostępu"); return; }
            var data = callback.TryGetProperty("data", out var d) ? d.GetString() ?? "" : "";
            await HandleCallbackAsync(data, id, messageId);
        }
    }

    private static bool Authorized(JsonElement message)
    {
        if (message.ValueKind != JsonValueKind.Object || !message.TryGetProperty("chat", out var chat)
            || !chat.TryGetProperty("id", out var id)) return false;
        return id.ToString() == ChatId;
    }

    private async Task HandleTextAsync(string text)
    {
        var parts = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var command = (parts.FirstOrDefault() ?? "").Split('@')[0].ToLowerInvariant();
        var argument = parts.Length > 1 ? parts[1] : null;
        switch (command)
        {
            case "/help": case "/start": await SendHelpAsync(); break;
            case "/all": await SendAllAsync(); break;
            case "/spools": await SendSpoolsAsync(); break;
            case "/history": await SendHistoryAsync(); break;
            case "/mute": await HandleMuteAsync(argument); break;
            case "/watch": await HandleWatchAsync(argument); break;
            default: await SendPrinterMenuAsync(null); break;
        }
    }

    private async Task HandleCallbackAsync(string data, string cbId, int? messageId)
    {
        var parts = data.Split(':');
        switch (parts.ElementAtOrDefault(0))
        {
            case "p" when parts.Length > 1: await ShowStatusAsync(parts[1], messageId); await AnswerAsync(cbId, ""); break;
            case "menu": await SendPrinterMenuAsync(messageId); await AnswerAsync(cbId, ""); break;
            case "a" when parts.Length >= 3: await RunActionAsync(parts[1], parts[2], cbId, messageId); break;
            case "photo" when parts.Length > 1: await HandlePhotoAsync(parts[1], cbId); break;
            default: await AnswerAsync(cbId, ""); break;
        }
    }

    // Screens

    private async Task SendPrinterMenuAsync(int? messageId)
    {
        var printers = OnUi(() => _store.Printers.ToList());
        if (printers.Count == 0) { await SendAsync(AppSettings.Text("Brak drukarek.", "No printers."), null); return; }
        var rows = printers.Select(p => new[] { Btn($"{Icon(p.Serial)} {p.Name}", $"p:{p.Serial}") }).ToArray();
        var text = AppSettings.Text("Wybierz drukarkę:", "Pick a printer:");
        if (messageId is { } id) await EditAsync(id, text, Keyboard(rows));
        else await SendAsync(text, Keyboard(rows));
    }

    private async Task ShowStatusAsync(string serial, int? messageId)
    {
        var text = OnUi(() => StatusText(serial));
        var markup = OnUi(() => ActionKeyboard(serial));
        if (messageId is { } id) await EditAsync(id, text, markup);
        else await SendAsync(text, markup);
    }

    private async Task RunActionAsync(string action, string serial, string cbId, int? messageId)
    {
        var name = OnUi(() => _store.Printers.FirstOrDefault(p => p.Serial == serial)?.Name ?? serial);
        void Exec(string kind) => OnUi(() => { _store.RunAutomation(new PrinterAutomation { Name = "telegram", ActionKind = kind }, serial); return 0; });
        switch (action)
        {
            case "pause": Exec("pause"); await AnswerAsync(cbId, "⏸ Wstrzymano"); break;
            case "resume": Exec("resume"); await AnswerAsync(cbId, "▶️ Wznowiono"); break;
            case "lighton": Exec("lightOn"); await AnswerAsync(cbId, "💡 Włączono"); break;
            case "lightoff": Exec("lightOff"); await AnswerAsync(cbId, "🌑 Wyłączono"); break;
            case "stopask":
                if (messageId is { } mid)
                    await EditAsync(mid, AppSettings.Text($"⏹ Zatrzymać wydruk na {name}? Tego nie cofniesz.",
                                                         $"⏹ Cancel the print on {name}? This cannot be undone."),
                        Keyboard(new[] { new[] {
                            Btn(AppSettings.Text("Tak, zatrzymaj", "Yes, cancel"), $"a:stop:{serial}"),
                            Btn(AppSettings.Text("Anuluj", "Back"), $"p:{serial}") } }));
                await AnswerAsync(cbId, "");
                return;
            case "stop": Exec("stop"); await AnswerAsync(cbId, "⏹ Zatrzymano"); break;
            default: await AnswerAsync(cbId, ""); return;
        }
        await Task.Delay(700);
        await ShowStatusAsync(serial, messageId);
    }

    private async Task HandlePhotoAsync(string serial, string cbId)
    {
        var printer = OnUi(() => _store.Printers.FirstOrDefault(p => p.Serial == serial));
        var name = printer?.Name ?? serial;
        await AnswerAsync(cbId, "📷…");
        await SendAsync(AppSettings.Text($"📷 Robię zdjęcie z kamery {name}…", $"📷 Grabbing a camera snapshot from {name}…"), null);
        byte[]? jpeg = printer == null ? null : await CameraSnapshot.CaptureAsync(printer, _store);
        if (jpeg != null) await SendPhotoAsync(jpeg, $"🖨 {name}");
        else await SendAsync(AppSettings.Text("Nie udało się pobrać zdjęcia (kamera niedostępna).", "Couldn't grab a snapshot (camera unavailable)."), null);
    }

    // Commands

    private async Task SendHelpAsync()
    {
        var text = AppSettings.Text(
            "🖨 Gantry — komendy:\n/status — wybór drukarki + sterowanie\n/all — cała flota w skrócie\n/spools — rolki na wyczerpaniu\n/history — ostatnie wydruki\n/watch 10m — zdjęcia co 10 min (/watch off)\n/mute 2h — wycisz alerty (/mute off)\n/help — to menu",
            "🖨 Gantry — commands:\n/status — pick a printer + controls\n/all — whole fleet at a glance\n/spools — spools running low\n/history — recent prints\n/watch 10m — a photo every 10 min (/watch off)\n/mute 2h — silence alerts (/mute off)\n/help — this menu");
        await ApiAsync("sendMessage", new Dictionary<string, string> { ["chat_id"] = ChatId, ["text"] = text, ["reply_markup"] = CommandKeyboard() });
    }

    private async Task SendAllAsync()
    {
        var lines = OnUi(() =>
        {
            var printers = _store.Printers.ToList();
            if (printers.Count == 0) return null;
            return printers.Select(p =>
            {
                var t = _store.Telemetry.TryGetValue(p.Serial, out var v) ? v : new PrinterTelemetry();
                var line = $"{Icon(p.Serial)} {p.Name}: {StateLabel(t.State)}";
                if (t.State is PrinterState.Printing or PrinterState.Paused)
                {
                    line += $" · {t.Progress}%";
                    if (t.RemainingMinutes is { } m && m > 0) line += $" · ETA {m / 60}h {m % 60}m";
                }
                return line;
            }).ToList();
        });
        if (lines == null) { await SendAsync(AppSettings.Text("Brak drukarek.", "No printers."), null); return; }
        await SendAsync(AppSettings.Text("🖨 Flota:", "🖨 Fleet:") + "\n" + string.Join("\n", lines), null);
    }

    private async Task SendSpoolsAsync()
    {
        var lines = OnUi(() =>
        {
            var low = SpoolbaseShared.Spools.Spools
                .Where(s => s.Status != SpoolStatus.Archived && s.Status != SpoolStatus.Empty && s.Percent <= 20)
                .OrderBy(s => s.Percent).Take(15).ToList();
            return low.Select(s =>
            {
                var def = SpoolbaseShared.Filaments.Filaments.FirstOrDefault(f => f.Id == s.FilamentDefinitionId);
                var material = def?.Type ?? def?.Name ?? "—";
                return $"{ColorDot(def?.ColorHex)} {material} · {s.Id} · {s.Percent}% · {(int)s.RemainingWeightGrams} g";
            }).ToList();
        });
        if (lines.Count == 0) { await SendAsync(AppSettings.Text("✅ Żadna rolka nie kończy się (≤20%).", "✅ No spools running low (≤20%)."), null); return; }
        await SendAsync(AppSettings.Text("🧵 Rolki na wyczerpaniu:", "🧵 Spools running low:") + "\n" + string.Join("\n", lines), null);
    }

    private async Task SendHistoryAsync()
    {
        var entries = PrintHistory.Recent(10);
        if (entries.Count == 0) { await SendAsync(AppSettings.Text("Brak historii wydruków.", "No print history yet."), null); return; }
        var lines = entries.Select(e => $"{e.Date:dd.MM HH:mm} · {e.Printer}" + (string.IsNullOrEmpty(e.Job) ? "" : $" · {e.Job}"));
        await SendAsync(AppSettings.Text("📜 Ostatnie wydruki:", "📜 Recent prints:") + "\n" + string.Join("\n", lines), null);
    }

    private async Task HandleMuteAsync(string? argument)
    {
        if (string.Equals(argument, "off", StringComparison.OrdinalIgnoreCase))
        {
            AppSettings.TelegramMuteUntil = null;
            await SendAsync(AppSettings.Text("🔔 Wyciszenie wyłączone.", "🔔 Mute off."), null);
            return;
        }
        var seconds = ParseDuration(argument);
        if (seconds == null)
        {
            if (AppSettings.TelegramMuteUntil is { } until)
                await SendAsync(AppSettings.Text($"🔕 Wyciszone do {until.ToLocalTime():HH:mm}. Wyłącz: /mute off", $"🔕 Muted until {until.ToLocalTime():HH:mm}. Turn off: /mute off"), null);
            else
                await SendAsync(AppSettings.Text("Podaj czas, np. /mute 2h lub /mute 30m. Wyłącz: /mute off", "Give a duration, e.g. /mute 2h or /mute 30m. Turn off: /mute off"), null);
            return;
        }
        var muteUntil = DateTime.UtcNow.AddSeconds(seconds.Value);
        AppSettings.TelegramMuteUntil = muteUntil;
        await SendAsync(AppSettings.Text($"🔕 Alerty wyciszone do {muteUntil.ToLocalTime():HH:mm}.", $"🔕 Alerts muted until {muteUntil.ToLocalTime():HH:mm}."), null);
    }

    private async Task HandleWatchAsync(string? argument)
    {
        if (string.Equals(argument, "off", StringComparison.OrdinalIgnoreCase))
        {
            _watchCts?.Cancel(); _watchCts = null;
            await SendAsync(AppSettings.Text("📷 Watch wyłączony.", "📷 Watch off."), null);
            return;
        }
        var seconds = ParseDuration(argument);
        if (seconds == null || seconds < 60)
        {
            await SendAsync(AppSettings.Text("Podaj odstęp ≥ 1 min, np. /watch 10m. Wyłącz: /watch off", "Give an interval ≥ 1 min, e.g. /watch 10m. Turn off: /watch off"), null);
            return;
        }
        _watchCts?.Cancel();
        _watchCts = new CancellationTokenSource();
        _ = WatchLoopAsync(seconds.Value, _watchCts.Token);
        await SendAsync(AppSettings.Text($"📷 Watch: zdjęcia drukujących drukarek co {argument}. Wyłącz: /watch off", $"📷 Watch: photos of printing machines every {argument}. Turn off: /watch off"), null);
    }

    private async Task WatchLoopAsync(double interval, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(interval), ct); } catch { break; }
            if (ct.IsCancellationRequested) break;
            var printing = OnUi(() => _store.Printers.Where(p => _store.Telemetry.TryGetValue(p.Serial, out var t) && t.State == PrinterState.Printing).ToList());
            foreach (var printer in printing)
            {
                var jpeg = await CameraSnapshot.CaptureAsync(printer, _store);
                if (jpeg == null) continue;
                var pct = OnUi(() => _store.Telemetry.TryGetValue(printer.Serial, out var t) ? t.Progress : 0);
                await SendPhotoAsync(jpeg, $"🖨 {printer.Name} · {pct}%");
            }
        }
    }

    // Content

    private string StatusText(string serial)
    {
        var name = _store.Printers.FirstOrDefault(p => p.Serial == serial)?.Name ?? serial;
        var t = _store.Telemetry.TryGetValue(serial, out var v) ? v : new PrinterTelemetry();
        string Temp(double? cur, double? tgt) => cur == null ? "—" : $"{(int)cur}°" + (tgt is { } g && g > 0 ? $"/{(int)g}°" : "");
        var lines = new List<string> { $"🖨 {name} — {StateLabel(t.State)}" };
        if (t.State is PrinterState.Printing or PrinterState.Paused)
        {
            var line = $"{AppSettings.Text("Postęp", "Progress")}: {t.Progress}%";
            if (t.CurrentLayer != null) line += $" · {AppSettings.Text("warstwa", "layer")} {t.CurrentLayer}/{t.TotalLayers ?? 0}";
            lines.Add(line);
            if (t.RemainingMinutes is { } m && m > 0) lines.Add($"ETA: {m / 60}h {m % 60}m");
            if (!string.IsNullOrEmpty(t.JobName)) lines.Add(t.JobName!);
        }
        lines.Add($"{AppSettings.Text("Dysza", "Nozzle")} {Temp(t.NozzleTemperature, t.NozzleTargetTemperature)} · {AppSettings.Text("stół", "bed")} {Temp(t.BedTemperature, t.BedTargetTemperature)}"
            + (t.ChamberTemperature != null ? $" · {AppSettings.Text("komora", "chamber")} {Temp(t.ChamberTemperature, null)}" : ""));
        var humidity = t.FilamentGroups.Where(g => g.HumidityPercent != null).Select(g => $"{g.DisplayName} 💧{g.HumidityPercent}%").ToList();
        if (humidity.Count > 0) lines.Add(string.Join(" · ", humidity));
        return string.Join("\n", lines);
    }

    private string ActionKeyboard(string serial)
    {
        var rows = new List<object[]>();
        var tiles = _store.Telemetry.TryGetValue(serial, out var t)
            ? t.FilamentGroups.SelectMany(g => g.Slots).Where(s => s.IsPresent).Select(s =>
            {
                var active = s.IsActive ? "●" : "";
                var pct = s.RemainingPercent is { } p ? $"{p}%" : "";
                return Btn($"{ColorDot(s.ColorHex)}{active}{(string.IsNullOrEmpty(s.Material) ? "—" : s.Material)} {pct}".Trim(), "noop");
            }).ToList()
            : new List<object>();
        for (int i = 0; i < tiles.Count; i += 4) rows.Add(tiles.Skip(i).Take(4).ToArray());
        rows.Add(new[] { Btn("⏸ " + AppSettings.Text("Pauza", "Pause"), $"a:pause:{serial}"), Btn("▶️ " + AppSettings.Text("Wznów", "Resume"), $"a:resume:{serial}"), Btn("⏹ " + AppSettings.Text("Stop", "Stop"), $"a:stopask:{serial}") });
        rows.Add(new[] { Btn("💡 " + AppSettings.Text("Wł", "On"), $"a:lighton:{serial}"), Btn("🌑 " + AppSettings.Text("Wył", "Off"), $"a:lightoff:{serial}"), Btn("📷 " + AppSettings.Text("Zdjęcie", "Photo"), $"photo:{serial}") });
        rows.Add(new[] { Btn("↻ " + AppSettings.Text("Odśwież", "Refresh"), $"p:{serial}"), Btn("‹ " + AppSettings.Text("Drukarki", "Printers"), "menu") });
        return Keyboard(rows.ToArray());
    }

    private static string StateLabel(PrinterState state) => state switch
    {
        PrinterState.Printing => AppSettings.Text("Drukowanie", "Printing"),
        PrinterState.Paused => AppSettings.Text("Wstrzymana", "Paused"),
        PrinterState.Finished => AppSettings.Text("Zakończono", "Finished"),
        PrinterState.Error => AppSettings.Text("Błąd", "Error"),
        PrinterState.Idle => AppSettings.Text("Gotowa", "Ready"),
        _ => "Offline"
    };

    private string Icon(string serial) => (_store.Telemetry.TryGetValue(serial, out var t) ? t.State : PrinterState.Offline) switch
    {
        PrinterState.Printing => "🟢", PrinterState.Paused => "⏸", PrinterState.Error => "🔴", PrinterState.Offline => "⚪️", _ => "🖨"
    };

    private static string ColorDot(string? hex)
    {
        if (hex == null) return "⚪️";
        var clean = hex.Replace("#", "");
        if (clean.Length < 6 || !int.TryParse(clean.Substring(0, 6), System.Globalization.NumberStyles.HexNumber, null, out var value)) return "⚪️";
        double r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        if (max < 55) return "⚫️";
        if (min > 205) return "⚪️";
        if (max - min < 34) return "⚪️";
        if (r >= g && r >= b) return max < 150 ? "🟤" : (g > 110 ? "🟠" : "🔴");
        if (g >= r && g >= b) return "🟢";
        if (b >= r && b >= g) return r > 110 ? "🟣" : "🔵";
        return "🟡";
    }

    private static double? ParseDuration(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        var lower = text.ToLowerInvariant();
        if (lower.EndsWith("h") && double.TryParse(lower[..^1], out var h)) return h * 3600;
        if (lower.EndsWith("m") && double.TryParse(lower[..^1], out var m)) return m * 60;
        if (double.TryParse(lower, out var n)) return n * 60;
        return null;
    }

    // Telegram API

    private static object Btn(string text, string data) => new { text, callback_data = data };

    private static string Keyboard(object[][] rows) => JsonSerializer.Serialize(new { inline_keyboard = rows });

    private static string CommandKeyboard()
    {
        var rows = new[] { new[] { "/status", "/all" }, new[] { "/spools", "/history" }, new[] { "/watch 10m", "/mute 2h" }, new[] { "/help" } };
        return JsonSerializer.Serialize(new { keyboard = rows.Select(r => r.Select(t => new { text = t }).ToArray()).ToArray(), resize_keyboard = true });
    }

    private async Task SendAsync(string text, string? replyMarkup)
    {
        var p = new Dictionary<string, string> { ["chat_id"] = ChatId, ["text"] = text };
        if (!string.IsNullOrEmpty(replyMarkup)) p["reply_markup"] = replyMarkup;
        await ApiAsync("sendMessage", p);
    }

    private async Task EditAsync(int messageId, string text, string? replyMarkup)
    {
        var p = new Dictionary<string, string> { ["chat_id"] = ChatId, ["message_id"] = messageId.ToString(), ["text"] = text };
        if (!string.IsNullOrEmpty(replyMarkup)) p["reply_markup"] = replyMarkup;
        await ApiAsync("editMessageText", p);
    }

    private async Task AnswerAsync(string callbackId, string text)
        => await ApiAsync("answerCallbackQuery", new Dictionary<string, string> { ["callback_query_id"] = callbackId, ["text"] = text });

    private async Task SendPhotoAsync(byte[] jpeg, string caption)
    {
        try
        {
            using var content = new MultipartFormDataContent();
            content.Add(new StringContent(ChatId), "chat_id");
            if (!string.IsNullOrEmpty(caption)) content.Add(new StringContent(caption), "caption");
            var photo = new ByteArrayContent(jpeg);
            photo.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("image/jpeg");
            content.Add(photo, "photo", "snapshot.jpg");
            await _http.PostAsync($"https://api.telegram.org/bot{Token}/sendPhoto", content);
        }
        catch { }
    }

    private async Task<JsonElement?> ApiAsync(string method, Dictionary<string, string> parameters)
    {
        try
        {
            var response = await _http.PostAsync($"https://api.telegram.org/bot{Token}/{method}", new FormUrlEncodedContent(parameters));
            if (!response.IsSuccessStatusCode) return null;
            var json = await response.Content.ReadAsStringAsync();
            return JsonDocument.Parse(json).RootElement.Clone();
        }
        catch { return null; }
    }

    /// <summary>Runs a store-touching read/action on the UI thread (the store is updated there).</summary>
    private static T OnUi<T>(Func<T> body)
        => Application.Current?.Dispatcher.Invoke(body) ?? body();
}
