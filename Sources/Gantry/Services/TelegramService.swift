import Foundation

/// Outbound Telegram notifications through the official Bot API (https://core.telegram.org/bots/api).
/// No third-party gateway: a bot token + chat id are all it needs. Deliberately small and
/// dependency-free so the same shape ports 1:1 to the Windows (C#) and Linux (Python) clients.
///
/// Settings live in `AppSettings` under keys shared verbatim across platforms:
/// `telegram-enabled` / `telegram-bot-token` / `telegram-chat-id`. Telegram fires on the same events as
/// the native notifications (finished / error / paused / low filament / humidity), only when enabled and
/// configured. See docs/telegram.md.
enum TelegramService {
    /// Sends a message for one event when Telegram is enabled and configured. `title` + `body` mirror the
    /// native notification; the visible text is the shared `format` below. Main-actor because it reads
    /// `AppSettings.shared`; the actual network call hops off to a detached Task.
    @MainActor
    static func notify(printer: String, title: String, body: String) {
        let settings = AppSettings.shared
        guard settings.telegramEnabled else { return }
        if settings.telegramMuteUntil != nil { return }   // alerts silenced by /mute
        let token = settings.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = settings.telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !chat.isEmpty else { return }
        let text = format(printer: printer, title: title, body: body)
        Task { await sendMessage(token: token, chatID: chat, text: text) }
    }

    /// The one message format every platform uses: `🖨 <printer> — <title>` then the body on a new line.
    static func format(printer: String, title: String, body: String) -> String {
        var text = "🖨 \(printer) — \(title)"
        if !body.isEmpty { text += "\n\(body)" }
        return text
    }

    /// Low-level send. Returns true on HTTP 200, so the Settings "Test" button can report success.
    @discardableResult
    static func sendMessage(token: String, chatID: String, text: String) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "chat_id", value: chatID),
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "disable_web_page_preview", value: "true")
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
