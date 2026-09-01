using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Threading.Tasks;

namespace Gantry.Services;

/// <summary>Outbound Telegram notifications through the official Bot API. The C# mirror of the macOS
/// TelegramService: same shared settings keys and the same message format. Fires on the same events as the
/// native notifications, only when enabled and not muted. See docs/telegram.md.</summary>
public static class TelegramService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static void Notify(string printer, string title, string body)
    {
        if (!AppSettings.TelegramEnabled) return;
        if (AppSettings.TelegramMuteUntil != null) return;   // silenced by /mute
        var token = AppSettings.TelegramBotToken.Trim();
        var chat = AppSettings.TelegramChatId.Trim();
        if (token.Length == 0 || chat.Length == 0) return;
        _ = SendMessageAsync(token, chat, Format(printer, title, body));
    }

    /// <summary>The one message format shared by every platform: "🖨 &lt;printer&gt; — &lt;title&gt;" then the body.</summary>
    public static string Format(string printer, string title, string body)
        => string.IsNullOrEmpty(body) ? $"🖨 {printer} — {title}" : $"🖨 {printer} — {title}\n{body}";

    public static async Task<bool> SendMessageAsync(string token, string chatId, string text)
    {
        try
        {
            var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["chat_id"] = chatId, ["text"] = text, ["disable_web_page_preview"] = "true"
            });
            var response = await Http.PostAsync($"https://api.telegram.org/bot{token}/sendMessage", content);
            return response.IsSuccessStatusCode;
        }
        catch { return false; }
    }
}
