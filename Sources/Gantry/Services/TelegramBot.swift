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
    private var watchTask: Task<Void, Never>?
    private var offset = 0

    init(store: PrinterStore) { self.store = store; TelegramBot.shared = self }

    /// Start/stop the poll loop to match the current settings. Call on launch and whenever Telegram
    /// settings change.
    func syncWithSettings() {
        let configured = AppSettings.shared.telegramEnabled && !token.isEmpty && !chatID.isEmpty
        if configured, task == nil { task = Task { [weak self] in await self?.loop() } }
        else if !configured, task != nil { task?.cancel(); task = nil; watchTask?.cancel(); watchTask = nil }
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
            await handleText((message["text"] as? String ?? "").trimmingCharacters(in: .whitespaces))
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

    private func handleText(_ text: String) async {
        let parts = text.split(separator: " ").map(String.init)
        // Strip a trailing @botname from the command (Telegram adds it in groups).
        let command = (parts.first ?? "").split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1] : nil
        switch command {
        case "/help", "/start": await sendHelp()
        case "/all":            await sendAll()
        case "/spools":         await sendSpools()
        case "/history":        await sendHistory()
        case "/mute":           await handleMute(argument)
        case "/watch":          await handleWatch(argument)
        default:                await sendPrinterMenu(messageID: nil)   // /status, /menu, plain text
        }
    }

    // MARK: Commands

    private func sendHelp() async {
        let s = AppSettings.shared
        let text = s.text(
            """
            🖨 Gantry — komendy:
            /status — wybór drukarki + sterowanie
            /all — cała flota w skrócie
            /spools — rolki na wyczerpaniu
            /history — ostatnie wydruki
            /watch 10m — zdjęcia co 10 min (/watch off)
            /mute 2h — wycisz alerty (/mute off)
            /help — to menu
            """,
            """
            🖨 Gantry — commands:
            /status — pick a printer + controls
            /all — whole fleet at a glance
            /spools — spools running low
            /history — recent prints
            /watch 10m — a photo every 10 min (/watch off)
            /mute 2h — silence alerts (/mute off)
            /help — this menu
            """)
        await api("sendMessage", ["chat_id": chatID, "text": text, "reply_markup": commandKeyboard()])
    }

    private func sendAll() async {
        let printers = store?.printers ?? []
        guard !printers.isEmpty else { await send(text: AppSettings.shared.text("Brak drukarek.", "No printers."), replyMarkup: commandKeyboard()); return }
        let s = AppSettings.shared
        let lines = printers.map { printer -> String in
            let t = store?.telemetry[printer.serial] ?? PrinterTelemetry()
            var line = "\(iconFor(printer.serial)) \(printer.name): \(stateLabel(t.state))"
            if t.state == .printing || t.state == .paused {
                line += " · \(t.progress)%"
                if let m = t.remainingMinutes, m > 0 { line += " · ETA \(m / 60)h \(m % 60)m" }
            }
            return line
        }
        await send(text: s.text("🖨 Flota:", "🖨 Fleet:") + "\n" + lines.joined(separator: "\n"), replyMarkup: commandKeyboard())
    }

    private func sendSpools() async {
        let s = AppSettings.shared
        let spools = SpoolbaseShared.spools.spools
            .filter { $0.status != .archived && $0.status != .empty && $0.percent <= 20 }
            .sorted { $0.percent < $1.percent }
        if spools.isEmpty {
            await send(text: s.text("✅ Żadna rolka nie kończy się (≤20%).", "✅ No spools running low (≤20%)."), replyMarkup: commandKeyboard())
            return
        }
        let lines = spools.prefix(15).map { spool -> String in
            let def = SpoolbaseShared.filaments.filaments.first { $0.id == spool.filamentDefinitionID }
            let material = def?.type ?? def?.name ?? "—"
            return "\(colorDot(def?.colorHex)) \(material) · \(spool.id) · \(spool.percent)% · \(Int(spool.remainingWeightGrams)) g"
        }
        await send(text: s.text("🧵 Rolki na wyczerpaniu:", "🧵 Spools running low:") + "\n" + lines.joined(separator: "\n"), replyMarkup: commandKeyboard())
    }

    private func sendHistory() async {
        let s = AppSettings.shared
        let entries = PrintHistory.recent(10)
        guard !entries.isEmpty else { await send(text: s.text("Brak historii wydruków.", "No print history yet."), replyMarkup: commandKeyboard()); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        let lines = entries.map { entry in
            "\(formatter.string(from: entry.date)) · \(entry.printer)" + (entry.job.isEmpty ? "" : " · \(entry.job)")
        }
        await send(text: s.text("📜 Ostatnie wydruki:", "📜 Recent prints:") + "\n" + lines.joined(separator: "\n"), replyMarkup: commandKeyboard())
    }

    private func handleMute(_ argument: String?) async {
        let s = AppSettings.shared
        if argument?.lowercased() == "off" {
            AppSettings.shared.telegramMuteUntil = nil
            await send(text: s.text("🔔 Wyciszenie wyłączone.", "🔔 Mute off."), replyMarkup: commandKeyboard())
            return
        }
        guard let argument, let seconds = parseDuration(argument) else {
            if let until = s.telegramMuteUntil {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                await send(text: s.text("🔕 Wyciszone do \(f.string(from: until)). Wyłącz: /mute off",
                                        "🔕 Muted until \(f.string(from: until)). Turn off: /mute off"), replyMarkup: commandKeyboard())
            } else {
                await send(text: s.text("Podaj czas, np. /mute 2h lub /mute 30m. Wyłącz: /mute off",
                                        "Give a duration, e.g. /mute 2h or /mute 30m. Turn off: /mute off"), replyMarkup: commandKeyboard())
            }
            return
        }
        let until = Date().addingTimeInterval(seconds)
        AppSettings.shared.telegramMuteUntil = until
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        await send(text: s.text("🔕 Alerty wyciszone do \(f.string(from: until)).", "🔕 Alerts muted until \(f.string(from: until))."), replyMarkup: commandKeyboard())
    }

    private func handleWatch(_ argument: String?) async {
        let s = AppSettings.shared
        if argument?.lowercased() == "off" {
            watchTask?.cancel(); watchTask = nil
            await send(text: s.text("📷 Watch wyłączony.", "📷 Watch off."), replyMarkup: commandKeyboard())
            return
        }
        guard let argument, let seconds = parseDuration(argument), seconds >= 60 else {
            await send(text: s.text("Podaj odstęp ≥ 1 min, np. /watch 10m. Wyłącz: /watch off",
                                    "Give an interval ≥ 1 min, e.g. /watch 10m. Turn off: /watch off"), replyMarkup: commandKeyboard())
            return
        }
        watchTask?.cancel()
        watchTask = Task { [weak self] in await self?.watchLoop(interval: seconds) }
        await send(text: s.text("📷 Watch: zdjęcia drukujących drukarek co \(argument). Wyłącz: /watch off",
                                "📷 Watch: photos of printing machines every \(argument). Turn off: /watch off"), replyMarkup: commandKeyboard())
    }

    private func watchLoop(interval: TimeInterval) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { break }
            for printer in store?.printers ?? [] where store?.telemetry[printer.serial]?.state == .printing {
                guard let store, let jpeg = await CameraSnapshot.capture(printer: printer, store: store) else { continue }
                let pct = store.telemetry[printer.serial]?.progress ?? 0
                await sendPhoto(jpeg: jpeg, caption: "🖨 \(printer.name) · \(pct)%")
            }
        }
    }

    /// Parses "30m" / "2h" / "90" (minutes) into seconds.
    private func parseDuration(_ text: String) -> TimeInterval? {
        let lower = text.lowercased()
        if lower.hasSuffix("h"), let n = Double(lower.dropLast()) { return n * 3600 }
        if lower.hasSuffix("m"), let n = Double(lower.dropLast()) { return n * 60 }
        if let n = Double(lower) { return n * 60 }
        return nil
    }

    /// Persistent bottom bar, defined once in TelegramService so notifications and bot replies agree.
    private func commandKeyboard() -> String { TelegramService.commandKeyboard }

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
            let serial = parts[1]
            let name = store?.printers.first { $0.serial == serial }?.name ?? serial
            await answer(cbID, "📷…")
            await send(text: AppSettings.shared.text("📷 Robię zdjęcie z kamery \(name)…",
                                                     "📷 Grabbing a camera snapshot from \(name)…"), replyMarkup: commandKeyboard())
            if let printer = store?.printers.first(where: { $0.serial == serial }), let store,
               let jpeg = await CameraSnapshot.capture(printer: printer, store: store) {
                await sendPhoto(jpeg: jpeg, caption: "🖨 \(name)")
            } else {
                await send(text: AppSettings.shared.text("Nie udało się pobrać zdjęcia (kamera niedostępna).",
                                                         "Couldn't grab a snapshot (camera unavailable)."), replyMarkup: commandKeyboard())
            }
        default:
            await answer(cbID, "")
        }
    }

    // MARK: Screens

    private func sendPrinterMenu(messageID: Int?) async {
        let printers = store?.printers ?? []
        guard !printers.isEmpty else { await send(text: "Brak drukarek.", replyMarkup: commandKeyboard()); return }
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
        // The filament modules themselves are shown as a row of tiles in the keyboard (see actionKeyboard);
        // here only the module humidity, if reported.
        let humidity = t.filamentGroups.compactMap { g in g.humidityPercent.map { "\(g.displayName) 💧\($0)%" } }
        if !humidity.isEmpty { lines.append(humidity.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    private func actionKeyboard(serial: String) -> String {
        let s = AppSettings.shared
        var rows: [[(String, String)]] = []
        // AMS as a grid of tiles: colour dot + material + %. Display-only (tap does nothing). All loaded
        // slots across every module are flattened into one list and packed four-per-row, so a lone AMS
        // slot + EXT sit side by side instead of each taking a full-width row.
        let tiles = (store?.telemetry[serial]?.filamentGroups ?? [])
            .flatMap { $0.slots }
            .filter(\.isPresent)
            .map { slot -> (String, String) in
                // Keep it short so Telegram keeps four tiles on one row (long labels force full width).
                let active = slot.isActive ? "●" : ""
                let pct = slot.remainingPercent.map { "\($0)%" } ?? ""
                let label = "\(colorDot(slot.colorHex))\(active)\(slot.material ?? "—") \(pct)"
                    .trimmingCharacters(in: .whitespaces)
                return (label, "noop")
            }
        for chunk in stride(from: 0, to: tiles.count, by: 4) {
            rows.append(Array(tiles[chunk ..< min(chunk + 4, tiles.count)]))
        }
        rows.append([("⏸ " + s.text("Pauza", "Pause"), "a:pause:\(serial)"),
                     ("▶️ " + s.text("Wznów", "Resume"), "a:resume:\(serial)"),
                     ("⏹ " + s.text("Stop", "Stop"), "a:stopask:\(serial)")])
        rows.append([("💡 " + s.text("Wł", "On"), "a:lighton:\(serial)"),
                     ("🌑 " + s.text("Wył", "Off"), "a:lightoff:\(serial)"),
                     ("📷 " + s.text("Zdjęcie", "Photo"), "photo:\(serial)")])
        rows.append([("↻ " + s.text("Odśwież", "Refresh"), "p:\(serial)"),
                     ("‹ " + s.text("Drukarki", "Printers"), "menu")])
        return keyboard(rows)
    }

    /// A coloured circle emoji roughly matching a filament colour hex, so an AMS tile hints the colour.
    private func colorDot(_ hex: String?) -> String {
        guard let clean = hex?.replacingOccurrences(of: "#", with: ""), clean.count >= 6,
              let value = Int(clean.prefix(6), radix: 16) else { return "⚪️" }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        let maxc = max(r, g, b), minc = min(r, g, b)
        if maxc < 55 { return "⚫️" }
        if minc > 205 { return "⚪️" }
        if maxc - minc < 34 { return "⚪️" }                       // greyish
        if r >= g, r >= b { return (maxc < 150 ? "🟤" : (g > 110 ? "🟠" : "🔴")) }
        if g >= r, g >= b { return "🟢" }
        if b >= r, b >= g { return (r > 110 ? "🟣" : "🔵") }
        return "🟡"
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

    /// Uploads a JPEG via multipart/form-data (sendPhoto). The bot's only non-urlencoded call.
    private func sendPhoto(jpeg: Data, caption: String) async {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto") else { return }
        let boundary = "GantryBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("chat_id", chatID)
        if !caption.isEmpty { field("caption", caption) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"snapshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
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
