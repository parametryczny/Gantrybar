import Foundation

/// Two-way Telegram bot (Etap 2): long-polls `getUpdates`, shows a printer picker and per-printer action
/// buttons, and maps them to Gantry's existing control via `PrinterStore.runAutomation`. Only the chat id
/// configured in Settings may drive it — everyone else is ignored, so a stranger who finds the bot can't
/// touch the printers. Kept self-contained so the same flow ports to Windows (C#) and Linux (Python).
///
/// Outbound notifications live in `TelegramService`; this class is only the interactive side. `/photo`
/// (camera snapshot) is stubbed until per-brand frame capture lands (Etap 2b). See docs/telegram.md.
@MainActor
final class TelegramBot {
    static weak var shared: TelegramBot?

    private weak var store: PrinterStore?
    private var task: Task<Void, Never>?
    private var offset = 0

    init(store: PrinterStore) { self.store = store; TelegramBot.shared = self }

    /// Start/stop the poll loop to match the current settings. Call on launch and whenever Telegram
    /// settings change.
    func syncWithSettings() {
        let configured = AppSettings.shared.telegramEnabled && !token.isEmpty && !chatID.isEmpty
        if configured, task == nil { task = Task { [weak self] in await self?.loop() } }
        else if !configured, task != nil { task?.cancel(); task = nil }
    }

    private var token: String { AppSettings.shared.telegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var chatID: String { AppSettings.shared.telegramChatID.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Poll loop

    private func loop() async {
        while !Task.isCancelled {
            guard AppSettings.shared.telegramEnabled, !token.isEmpty, !chatID.isEmpty else { break }
            for update in await getUpdates() where !Task.isCancelled { await handle(update) }
        }
    }

    private func getUpdates() async -> [[String: Any]] {
        let params = ["offset": String(offset), "timeout": "25",
                      "allowed_updates": "[\"message\",\"callback_query\"]"]
        guard let root = await api("getUpdates", params, timeout: 60),
              let result = root["result"] as? [[String: Any]] else {
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // brief backoff on network error
            return []
        }
        for update in result { if let id = update["update_id"] as? Int { offset = max(offset, id + 1) } }
        return result
    }

    // MARK: Routing

    private func handle(_ update: [String: Any]) async {
        if let message = update["message"] as? [String: Any] {
            guard authorized(message["chat"] as? [String: Any]) else { return }
            await sendPrinterMenu(messageID: nil)
        } else if let callback = update["callback_query"] as? [String: Any] {
            let id = callback["id"] as? String ?? ""
            let message = callback["message"] as? [String: Any]
            guard authorized(message?["chat"] as? [String: Any]) else { await answer(id, "Brak dostępu"); return }
            await handleCallback(callback["data"] as? String ?? "", cbID: id, messageID: message?["message_id"] as? Int)
        }
    }

    private func authorized(_ chat: [String: Any]?) -> Bool {
        guard let id = chat?["id"] else { return false }
        return "\(id)" == chatID
    }

    private func handleCallback(_ data: String, cbID: String, messageID: Int?) async {
        let parts = data.split(separator: ":").map(String.init)
        switch parts.first {
        case "p" where parts.count > 1:
            await showStatus(serial: parts[1], messageID: messageID); await answer(cbID, "")
        case "menu":
            await sendPrinterMenu(messageID: messageID); await answer(cbID, "")
        case "a" where parts.count >= 3:
            await runAction(parts[1], serial: parts[2], cbID: cbID, messageID: messageID)
        case "photo" where parts.count > 1:
            await answer(cbID, "📷")
            await send(text: AppSettings.shared.text(
                "📷 Zdjęcie z kamery jest w przygotowaniu. Kamery Bambu nadają H.264 (RTSP), więc snapshot wymaga dekodowania klatki — dodam to wkrótce.",
                "📷 Camera snapshot is in preparation. Bambu cameras stream H.264 (RTSP), so a snapshot needs a frame decode — coming soon."),
                replyMarkup: nil)
        default:
            await answer(cbID, "")
        }
    }

    // MARK: Screens

    private func sendPrinterMenu(messageID: Int?) async {
        let printers = store?.printers ?? []
        guard !printers.isEmpty else { await send(text: "Brak drukarek.", replyMarkup: nil); return }
        let rows = printers.map { [(iconFor($0.serial) + " " + $0.name, "p:\($0.serial)")] }
        let text = AppSettings.shared.text("Wybierz drukarkę:", "Pick a printer:")
        if let messageID { await edit(messageID: messageID, text: text, replyMarkup: keyboard(rows)) }
        else { await send(text: text, replyMarkup: keyboard(rows)) }
    }

    private func showStatus(serial: String, messageID: Int?) async {
        let text = statusText(serial: serial)
        let markup = actionKeyboard(serial: serial)
        if let messageID { await edit(messageID: messageID, text: text, replyMarkup: markup) }
        else { await send(text: text, replyMarkup: markup) }
    }

    private func runAction(_ action: String, serial: String, cbID: String, messageID: Int?) async {
        let name = store?.printers.first { $0.serial == serial }?.name ?? serial
        func exec(_ a: AutomationAction) {
            store?.runAutomation(PrinterAutomation(name: "telegram", action: a), serial: serial)
        }
        switch action {
        case "pause":  exec(.pause);        await answer(cbID, "⏸ Wstrzymano")
        case "resume": exec(.resume);       await answer(cbID, "▶️ Wznowiono")
        case "lighton":  exec(.light(true));  await answer(cbID, "💡 Włączono")
        case "lightoff": exec(.light(false)); await answer(cbID, "🌑 Wyłączono")
        case "stopask":
            // Stop cancels the print and is not reversible, so ask once before doing it.
            if let messageID {
                await edit(messageID: messageID,
                           text: AppSettings.shared.text("⏹ Zatrzymać wydruk na \(name)? Tego nie cofniesz.",
                                                         "⏹ Cancel the print on \(name)? This cannot be undone."),
                           replyMarkup: keyboard([[
                               (AppSettings.shared.text("Tak, zatrzymaj", "Yes, cancel"), "a:stop:\(serial)"),
                               (AppSettings.shared.text("Anuluj", "Back"), "p:\(serial)")]]))
            }
            await answer(cbID, "")
            return
        case "stop":   exec(.stop);         await answer(cbID, "⏹ Zatrzymano")
        default:       await answer(cbID, ""); return
        }
        // Reflect the new state right in the message (small settle delay so telemetry can catch up).
        try? await Task.sleep(nanoseconds: 700_000_000)
        await showStatus(serial: serial, messageID: messageID)
    }

    // MARK: Content

    private func statusText(serial: String) -> String {
        let s = AppSettings.shared
        let name = store?.printers.first { $0.serial == serial }?.name ?? serial
        let t = store?.telemetry[serial] ?? PrinterTelemetry()
        func temp(_ cur: Double?, _ tgt: Double?) -> String {
            guard let cur else { return "—" }
            let target = (tgt ?? 0) > 0 ? "/\(Int(tgt!))°" : ""
            return "\(Int(cur))°\(target)"
        }
        var lines = ["🖨 \(name) — \(stateLabel(t.state))"]
        if t.state == .printing || t.state == .paused {
            lines.append("\(s.text("Postęp", "Progress")): \(t.progress)%"
                + (t.currentLayer != nil ? " · \(s.text("warstwa", "layer")) \(t.currentLayer!)/\(t.totalLayers ?? 0)" : ""))
            if let m = t.remainingMinutes, m > 0 {
                lines.append("ETA: \(m / 60)h \(m % 60)m")
            }
            if let job = t.jobName, !job.isEmpty { lines.append(job) }
        }
        lines.append("\(s.text("Dysza", "Nozzle")) \(temp(t.nozzleTemperature, t.nozzleTargetTemperature))"
            + " · \(s.text("stół", "bed")) \(temp(t.bedTemperature, t.bedTargetTemperature))"
            + (t.chamberTemperature != nil ? " · \(s.text("komora", "chamber")) \(temp(t.chamberTemperature, nil))" : ""))
        // Filament modules (AMS / AMS HT / CFS / EXT): one line each, only the loaded slots, with an
        // active marker so you see which spool is printing.
        for group in t.filamentGroups {
            let loaded = group.slots.filter(\.isPresent).map { slot -> String in
                let marker = slot.isActive ? "● " : ""
                let pct = slot.remainingPercent.map { " \($0)%" } ?? ""
                return "\(marker)\(slot.label) \(slot.material ?? "")\(pct)".trimmingCharacters(in: .whitespaces)
            }
            guard !loaded.isEmpty else { continue }
            let humidity = group.humidityPercent.map { " · 💧\($0)%" } ?? ""
            lines.append("\(group.displayName)\(humidity): " + loaded.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    private func actionKeyboard(serial: String) -> String {
        let s = AppSettings.shared
        return keyboard([
            [("⏸ " + s.text("Pauza", "Pause"), "a:pause:\(serial)"),
             ("▶️ " + s.text("Wznów", "Resume"), "a:resume:\(serial)"),
             ("⏹ " + s.text("Stop", "Stop"), "a:stopask:\(serial)")],
            [("💡 " + s.text("Wł", "On"), "a:lighton:\(serial)"),
             ("🌑 " + s.text("Wył", "Off"), "a:lightoff:\(serial)"),
             ("📷 " + s.text("Zdjęcie", "Photo"), "photo:\(serial)")],
            [("↻ " + s.text("Odśwież", "Refresh"), "p:\(serial)"),
             ("‹ " + s.text("Drukarki", "Printers"), "menu")]
        ])
    }

    private func stateLabel(_ state: PrinterState) -> String {
        let s = AppSettings.shared
        switch state {
        case .printing: return s.text("Drukowanie", "Printing")
        case .paused:   return s.text("Wstrzymana", "Paused")
        case .finished: return s.text("Zakończono", "Finished")
        case .error:    return s.text("Błąd", "Error")
        case .idle:     return s.text("Gotowa", "Ready")
        case .offline:  return s.text("Offline", "Offline")
        }
    }

    private func iconFor(_ serial: String) -> String {
        switch store?.telemetry[serial]?.state {
        case .printing: return "🟢"
        case .paused:   return "⏸"
        case .error:    return "🔴"
        case .offline:  return "⚪️"
        default:        return "🖨"
        }
    }

    // MARK: Telegram API

    private func keyboard(_ rows: [[(String, String)]]) -> String {
        let inline = rows.map { row in row.map { ["text": $0.0, "callback_data": $0.1] } }
        let data = (try? JSONSerialization.data(withJSONObject: ["inline_keyboard": inline])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func send(text: String, replyMarkup: String?) async {
        var params = ["chat_id": chatID, "text": text]
        if let replyMarkup, !replyMarkup.isEmpty { params["reply_markup"] = replyMarkup }
        await api("sendMessage", params)
    }

    private func edit(messageID: Int, text: String, replyMarkup: String?) async {
        var params = ["chat_id": chatID, "message_id": String(messageID), "text": text]
        if let replyMarkup, !replyMarkup.isEmpty { params["reply_markup"] = replyMarkup }
        await api("editMessageText", params)
    }

    private func answer(_ callbackID: String, _ text: String) async {
        await api("answerCallbackQuery", ["callback_query_id": callbackID, "text": text])
    }

    @discardableResult
    private func api(_ method: String, _ params: [String: String], timeout: TimeInterval = 20) async -> [String: Any]? {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
