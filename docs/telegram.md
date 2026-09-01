# Gantry — powiadomienia Telegram (Etap 1: wychodzące)

Gantry może wysyłać powiadomienia na Telegram przez **oficjalne Bot API** (bez zewnętrznej bramki):
wystarczy **token bota** i **chat_id**. Wysyłane są **te same zdarzenia** co powiadomienia natywne
(koniec druku / błąd / pauza / niski filament / wilgotność), gdy Telegram jest włączony.

Ta strona opisuje wspólny kontrakt, żeby implementacja była identyczna na macOS, Windows i Linux.

## Konfiguracja u użytkownika
1. **@BotFather** → `/newbot` → **token** (np. `123456:ABC-DEF...`).
2. Napisz cokolwiek do swojego bota (żeby mógł Ci odpisywać).
3. **chat_id**: napisz do **@userinfobot** (zwróci numeryczny `id`), albo otwórz
   `https://api.telegram.org/bot<TOKEN>/getUpdates` i weź `chat.id`. Dla grupy użyj `chat_id` grupy (ujemny).

W aplikacji: **Ustawienia → TELEGRAM** → włącz, wklej token + chat_id, **Wyślij test**.

## Ustawienia (klucze wspólne na wszystkich platformach)
| Klucz | Typ | Znaczenie |
| --- | --- | --- |
| `telegram-enabled` | bool | włącza wysyłkę |
| `telegram-bot-token` | string | token z @BotFather |
| `telegram-chat-id` | string | odbiorca (osoba lub grupa) |

macOS: `AppSettings` (UserDefaults). Windows: `AppSettings` (Storage.cs). Linux: `config.data`.
Klucze są **identyczne**, więc synchronizacja między maszynami użytkownika działa bez tłumaczenia.

## Wysyłka
`POST https://api.telegram.org/bot<TOKEN>/sendMessage`
form-urlencoded: `chat_id`, `text`, `disable_web_page_preview=true`. Sukces = HTTP 200.

## Format wiadomości (jeden dla wszystkich platform)
```
🖨 <nazwa drukarki> — <tytuł zdarzenia>
<treść>
```
np.:
```
🖨 X1 — Druk zakończony
benchy.3mf
```

## Zdarzenia
Telegram odpala się w tym samym miejscu co powiadomienia natywne (funkcja `notifyChanges` /
odpowiednik), bramkowany tymi samymi przełącznikami:
- koniec druku (`notify-finished`),
- błąd / HMS (`notify-error`),
- pauza (`notify-paused`),
- niski poziom filamentu (`notify-low-filament`),
- wysoka wilgotność AMS (`notify-humidity`).

## Port na Windows / Linux
- **Model**: dodać trzy pola ustawień pod kluczami wyżej + sekcję UI (włącznik, token, chat_id, „Wyślij test").
- **Serwis**: odpowiednik `TelegramService` z `sendMessage(token, chatId, text)` i wspólnym `format(...)`.
- **Hook**: w miejscu wysyłki powiadomień natywnych wywołać `TelegramService.notify(printer, title, body)`
  obok natywnego posta (na macOS zrobione przez lokalny helper `push(title:body:)`).

## Etap 2 (planowane)
- zdjęcie z kamery w załączniku (`sendPhoto`),
- bot dwukierunkowy: `/status /photo /pause /resume /stop /light` mapowane na sterowanie Gantry.
