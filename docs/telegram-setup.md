# Gantry — Telegram: dodanie bota krok po kroku

Gantry wysyła powiadomienia na Telegram i pozwala sterować drukarkami z czatu (status, pauza, wznów,
stop, światło, zdjęcie z kamery). Wszystko działa **lokalnie** — każdy tworzy **własnego bota** (nie
korzystasz z cudzego). Konfiguracja to dwa kody: **token bota** i **chat_id**. Zajmuje ~2 minuty.

> **Ważne: mostkiem jest Twój komputer.**
> Gantry nie ma serwera w chmurze. To komputer albo laptop z uruchomionym Gantry rozmawia z drukarkami
> i z Telegramem, więc powiadomienia i komendy działają **tylko wtedy, gdy ta maszyna jest włączona,
> nie śpi i ma dostęp do sieci**. Jeśli zamkniesz laptopa albo go uśpisz, bot przestanie odpowiadać, a
> alerty nie dojdą. Po ponownym uruchomieniu Gantry wszystko wraca samo.
>
> Jeśli chcesz mieć to dostępne bez przerwy, trzymaj Gantry na maszynie, która i tak chodzi cały czas:
> serwerze domowym, mini PC albo Raspberry Pi z wersją dla GNU/Linux.

---

## Krok 1. Token bota (z @BotFather)

To „hasło" bota — pozwala Gantry wysyłać i odbierać wiadomości.

1. W Telegramie w wyszukiwarce wpisz **@BotFather** (z niebieskim znaczkiem weryfikacji) i otwórz.
2. Wyślij **`/start`**, potem **`/newbot`**.
3. Podaj:
   - **nazwę** bota (dowolna, np. „Moje drukarki"),
   - **username** — musi kończyć się na `bot` (np. `mojedrukarki_bot`); jeśli zajęty, podaj inny.
4. BotFather odeśle **token** w formacie:

   ```
   123456789:AAExampleTokenABCdef...
   ```

   Skopiuj **całość razem z dwukropkiem**. To jest **Token bota**.

> 🔒 Token trzymaj prywatnie — daje pełną kontrolę nad botem. Gdyby wyciekł: w @BotFather wyślij
> `/revoke`, wybierz bota, dostaniesz nowy token (stary przestaje działać).

---

## Krok 2. chat_id (dokąd wysyłać)

Token to „nadawca"; `chat_id` to **odbiorca** (Ty albo grupa).

1. **Najpierw napisz cokolwiek do swojego bota** — znajdź go po username, otwórz, kliknij **Start** i wyślij
   np. „hej". Bez tego bot nie może Ci nic wysłać.
2. Zdobądź `chat_id` jednym ze sposobów:
   - **Prościej:** napisz do **@userinfobot** — odeśle Twój numeryczny **Id** (np. `123456789`). To jest
     Twój `chat_id`.
   - **Alternatywnie:** otwórz w przeglądarce (podstaw swój token):
     `https://api.telegram.org/bot<TOKEN>/getUpdates`
     i znajdź wartość `"chat":{"id":123456789,...}`.

> ⚠️ **`getUpdates` pokazuje `{"result":[]}`?** To normalne, jeśli Gantry już działa z włączonym
> Telegramem — bot cały czas pobiera wiadomości (long‑polling) i „zjada" je, więc dla Ciebie lista jest
> pusta. Użyj **@userinfobot** (działa niezależnie) albo na chwilę **wyłącz** Telegram w Gantry, odczytaj
> `getUpdates`, i włącz z powrotem.

---

## Krok 3. Wpisz kody w Gantry

1. **Ustawienia → sekcja TELEGRAM.**
2. Zaznacz **„Wysyłaj powiadomienia na Telegram"**.
3. Wklej **Token bota** (Krok 1) i **Chat ID** (Krok 2).
4. Kliknij **„Wyślij test"** — na Telegramie powinna pojawić się wiadomość testowa.

Gotowe. Od teraz Gantry wyśle powiadomienia (koniec druku, błąd, pauza, niski filament, wilgotność) — te
same zdarzenia, którymi sterujesz w sekcji **POWIADOMIENIA**.

---

## Sterowanie z Telegrama (bot dwukierunkowy)

Napisz do bota cokolwiek (albo `/start`). Bot odpowie **listą drukarek** (przyciski). Wybierz jedną:

- **status** — stan, %, warstwa, ETA, temperatury; AMS jako rząd kafli (kolor + materiał + %),
- **⏸ Pauza · ▶️ Wznów · ⏹ Stop** (Stop pyta o potwierdzenie),
- **💡 Wł · 🌑 Wył** — światło komory,
- **📷 Zdjęcie** — klatka z kamery.

> 🔒 Bot reaguje **tylko na Twój `chat_id`**. Ktoś, kto znajdzie bota, nic nie zrobi.

---

## Grupa zamiast prywatnie (opcjonalnie)

1. Dodaj swojego bota do grupy.
2. Napisz coś w grupie.
3. W `https://api.telegram.org/bot<TOKEN>/getUpdates` weź `chat_id` grupy — będzie **ujemny**
   (np. `-1001234567890`).
4. Wpisz ten `chat_id` w Gantry. Powiadomienia i sterowanie trafią do grupy.

---

## Problemy

- **„Wyślij test" nie działa / Failed:**
  - czy **napisałeś do bota** (Krok 2.1)? Bez tego wysyłka nie przejdzie,
  - sprawdź **token** (cały, z dwukropkiem) i **chat_id** (bez spacji),
  - token nie może być obcięty.
- **Bot nie odpowiada na komendy:** upewnij się, że w Gantry jest włączony Telegram i wpisany `chat_id`
  zgadza się z kontem, z którego piszesz.
- **Zdjęcie nie przychodzi (Bambu):** kamera wymaga **kodu dostępu** drukarki (zapisany przy drukarce) i
  chwili na dekodowanie klatki. Sprawdź też uprawnienie **Sieć lokalna** (macOS).
- **Zmieniłeś token/chat_id:** Gantry przełącza się automatycznie po zapisaniu w Ustawieniach.
- **Bot nagle zamilkł, a wcześniej działał:** najczęściej komputer z Gantry jest wyłączony, uśpiony albo
  stracił sieć. To on jest mostkiem, więc bez niego nie ma kto odebrać komendy ani wysłać alertu.
  Sprawdź też, czy alerty nie są wyciszone komendą `/mute` (`/mute off` je przywraca).

---

## Bezpieczeństwo w skrócie

- **Nie udostępniaj tokenu.** Kto ma token, kontroluje bota.
- Wszystko działa lokalnie — Twoje drukarki i kody dostępu **nie wychodzą** poza Twój Telegram i Twój
  komputer.
- Techniczny opis integracji: [`docs/telegram.md`](telegram.md).
