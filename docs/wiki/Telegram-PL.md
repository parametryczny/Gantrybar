# Telegram: własny bot i flota

[English](https://github.com/parametryczny/Gantrybar/wiki/Telegram-EN) · [Spis treści](https://github.com/parametryczny/Gantrybar/wiki/Home)

Gantry łączy się bezpośrednio z Bot API Telegrama przez Twojego bota. Włączone alerty i zamówione zdjęcia kamer przechodzą przez Telegram. Komputer z Gantry musi pozostawać włączony, nieuśpiony i połączony z siecią.

## Konfiguracja

1. Otwórz zweryfikowane konto **@BotFather** w Telegramie, wyślij `/newbot` i utwórz bota.
2. Zapisz token prywatnie. Daje dostęp do bota; w razie ujawnienia unieważnij go przez BotFather.
3. Otwórz swojego nowego bota, wybierz **Start** i wyślij wiadomość.
4. Ustal docelowy `chat_id`. Odpowiedź Telegrama `getUpdates` zawiera go po wysłaniu wiadomości; na czas odczytu wyłącz integrację Telegram w Gantry, ponieważ aktualizacje powinien odbierać jeden proces.
5. W ustawieniach Telegrama w Gantry włącz integrację, wpisz token i Chat ID, a następnie wyślij test.

Nie udostępniaj adresu zawierającego token, logów ani zrzutów z tokenem. Skonfiguruj właściwy czat; znalezienie bota nie daje dostępu każdemu użytkownikowi.

## Codzienne użycie

| Polecenie | Działanie |
| --- | --- |
| `/status` | Wybór drukarki i podgląd stanu. |
| `/all` | Podsumowanie floty. |
| `/spools` | Rolki z małą ilością filamentu. |
| `/history` | Ostatnie wydruki. |
| `/watch 10m` | Cykliczne zdjęcia. |
| `/mute 2h` | Czasowe wyciszenie alertów. |
| `/help` | Dostępne polecenia. |

Wiadomości drukarki udostępniają dostępne akcje, m.in. pauzę, wznowienie, zatrzymanie, światło i zdjęcie. Polecenia nadal zależą od możliwości drukarki oraz włączonych ustawień sterowania.

## Gdy bot milczy

Sprawdź, czy Gantry działa, komputer nie śpi i ma sieć, integracja jest włączona, Chat ID jest prawidłowy, a inny proces nie odbiera aktualizacji tego samego bota. Cisza nocna i `/mute` mogą blokować alerty. Nie wklejaj tokenu do zgłoszenia.
