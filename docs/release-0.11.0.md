# Gantry 0.11.0: powiadomienia Telegram, konserwacja drukarek i Anycubic Kobra S1

Gantry 0.11.0 wyprowadza monitorowanie poza komputer. Powiadomienia i sterowanie trafiają na Telegram, a drukarki zyskują własny plan konserwacji, historię wydruków i centrum diagnostyczne. Wszystkie trzy nowości działają na macOS, Windows i GNU/Linux. Dochodzi też obsługa Anycubic Kobra S1.

Gantry nadal działa wyłącznie lokalnie. Nie ma konta, chmury ani serwera pośredniczącego.

## Najważniejsze zmiany

- **Powiadomienia i sterowanie przez Telegram**: alerty o zakończeniu, błędzie, pauzie i niskim filamencie trafiają na telefon, a bot pozwala odpytać drukarkę i nią sterować.
- **Konserwacja i historia**: cztery zadania serwisowe rozliczane w godzinach druku, z odkładaniem i własnymi interwałami, obok listy ostatnich wydruków i statystyk skuteczności.
- **Centrum diagnostyczne**: dostępne z menu prawego przycisku na ikonie, sprawdza całą flotę i pokazuje opóźnienie oraz ocenę jakości połączenia.
- **Anycubic Kobra S1**: lokalne MQTT/TLS w trybie LAN, bez konta Anycubic Cloud.
- **Naprawione powiadomienia systemowe na Windows 11** oraz koniec skakania sekcji AMS w oknie szczegółów.

## Telegram

Każdy użytkownik zakłada **własnego bota** u BotFather i wkleja token w Ustawieniach. Token zostaje na Twoim komputerze, nie ma wspólnego bota ani serwera Gantry pośrodku. Bot odpowiada wyłącznie na skonfigurowany czat, pozostałe wiadomości ignoruje.

Powiadomienia wychodzące podlegają tym samym przełącznikom co bannery systemowe: zakończenie, błąd (z opisem kodu HMS), pauza, drukarka offline, niski poziom filamentu i wysoka wilgotność AMS.

Bot obsługuje komendy:

| Komenda | Działanie |
| --- | --- |
| `/status` | wybór drukarki, a potem stan i przyciski sterowania |
| `/all` | cała flota w jednym podsumowaniu |
| `/spools` | rolki schodzące poniżej 20 procent |
| `/history` | ostatnie wydruki |
| `/watch 10m` | cykliczne zdjęcia z kamery, `/watch off` wyłącza |
| `/mute 2h` | wyciszenie alertów, `/mute off` wyłącza |
| `/help` | ściąga z komendami |

Po wybraniu drukarki dostajesz stan zadania, postęp, warstwy, czas do końca, temperatury i wilgotność AMS, kafle załadowanych slotów (kolor, materiał, procent, aktywny slot) oraz przyciski: pauza, wznów, stop z potwierdzeniem, światło komory i zdjęcie z kamery.

Zdjęcia (`/photo`) działają na macOS i Windows: dla Bambu przez dekodowanie klatki kluczowej H.264, dla Klipper i Elegoo przez pierwszą klatkę MJPEG. Na GNU/Linux kamera jest jeszcze w przygotowaniu i bot zwraca czytelny komunikat zamiast zdjęcia.

Instrukcja krok po kroku: [`docs/telegram-setup.md`](https://github.com/parametryczny/gantrybar/blob/main/docs/telegram-setup.md).

## Konserwacja, historia i diagnostyka

Każda drukarka ma panel konserwacji z czterema zadaniami rozliczanymi w **godzinach faktycznego druku**, a nie w dniach kalendarzowych:

| Zadanie | Domyślny interwał |
| --- | --- |
| Czyszczenie prowadnic | 100 h |
| Smarowanie osi | 200 h |
| Kontrola pasków | 300 h |
| Kontrola dyszy | 500 h |

Zadanie po terminie podświetla się na karcie. Możesz oznaczyć je jako wykonane, odłożyć o siedem dni albo ustawić własny interwał. Obok panelu znajdziesz listę ostatnich wydruków ze statusem i czasem trwania oraz statystyki: liczbę ukończonych zadań, skuteczność i zużycie filamentu w gramach.

Panel otwiera się jako nakładka wewnątrz aplikacji, a nie w osobnym oknie, więc nie odbiera fokusu i zamyka się kliknięciem obok. Akcje zostały skrócone do zwartego rzędu przycisków, a otwarcie panelu nie powoduje już podskoku całego okna.

Uwagi drukarki (kody HMS) są teraz oddzielone od zadań konserwacji, więc awaria sprzętu nie miesza się z planem serwisowym.

Centrum diagnostyczne otwierasz z menu prawego przycisku na ikonie Gantry. Dla każdej drukarki sprawdza dwie rzeczy: czy odpowiada jej port (z opóźnieniem w milisekundach i oceną jakości) oraz czy Gantry ma z nią żywe połączenie, a przy jego braku podaje powód. W trakcie widzisz nazwę aktualnie badanej drukarki i pasek postępu, a każda drukarka ma twardy limit trzech sekund, więc jeden host, który nie odpowiada, nie zatrzyma przebiegu. Na macOS panel jest nakładką w stylu pozostałych paneli aplikacji.

## Anycubic Kobra S1

Przy dodawaniu drukarki wybierasz markę **Anycubic**, model **Kobra S1**, włączasz w drukarce tryb LAN i podajesz jej adres IP. Gantry sam pobiera lokalną sesję MQTT, więc konto Anycubic Cloud ani kod dostępu nie są potrzebne.

Obsługa obejmuje stan zadania, temperatury, sterowanie drukiem, światło komory, moduł ACE Pro oraz kamerę FLV na porcie 18088. Szczegóły: [`docs/anycubic-kobra-s1.md`](https://github.com/parametryczny/gantrybar/blob/main/docs/anycubic-kobra-s1.md).

## Poprawki

- **Powiadomienia systemowe na Windows 11**: rejestracja powiadomień odbywa się teraz na wątku STA aplikacji. Telemetria drukarek przychodzi na wątkach roboczych, gdzie inicjalizacja WinRT potrafiła po cichu zawieść, przez co nie pojawiało się nic. Gantry sprawdza dodatkowo, czy powiadomienia nie zostały wyłączone przez użytkownika lub politykę firmową, i w takim wypadku wraca do dymka w zasobniku zamiast milczeć. Błędy trafiają do logu.
- **Sekcja AMS przestała skakać w oknie szczegółów**: widok filamentów przebudowywał się przy każdym pakiecie telemetrii, nawet gdy nic się nie zmieniło. Dodatkowo pakiet częściowy zawierający wyłącznie tacę zewnętrzną chwilowo usuwał znane moduły AMS, przez co karta zmieniała wysokość i wracała. Bambu wysyła dane AMS i tacy zewnętrznej w niezależnych pakietach, więc każdy z nich aktualizuje teraz tylko tę część, którą faktycznie niesie.
- **Centrum diagnostyczne nie wywraca już aplikacji ani nie zawiesza się w połowie**: okno trzymał kontroler ustawień, więc zamknięcie ustawień zostawiało je osierocone i pierwszy ruch myszy sięgał po zwolnione widoki. Panel żyje teraz wewnątrz aplikacji, tak jak konserwacja. Osobno naprawiony został przebieg testu, który potrafił zamilknąć po pierwszej drukarce.
- **Panel konserwacji na macOS otwiera się poprawnie**: wcześniej potrafił nie zareagować na kliknięcie. Przy okazji zniknął podskok okna przy otwieraniu.
- **Panel konserwacji, układ**: wyrównane wiersze akcji, szersze pole interwału mieszczące wartości czterocyfrowe i nazwy zadań, które nie urywają się wielokropkiem.
- **Kody HMS**: poprawione rozpoznawanie katalogów i wycentrowane pola formularzy.

## Uwaga dla macOS 26 i nowszych

Na najnowszych wersjach macOS runtime współbieżności Swifta potrafi przewrócić aplikację przy wewnętrznej kontroli izolacji wątku, w miejscach zupełnie niezwiązanych z tym, co robisz. Objawiało się to nagłym zamknięciem Gantry przy ruchu myszy albo w trakcie testu diagnostycznego. Wydanie jest budowane bez tych kontroli, które i tak były zbędne, bo interfejs działa wyłącznie na głównym wątku.

Wydania są teraz budowane w konfiguracji release. Wcześniej skrypt pakował build debug, wolniejszy i z dodatkowymi asercjami.

## Zgodność i aktualizacja

- **macOS:** macOS 13 lub nowszy;
- **Windows:** 64-bitowy Windows 10 lub 11;
- **GNU/Linux:** GTK 3, pakiety `.deb`, `.rpm` i `.AppImage`.

Aktualizacja zachowuje zapisane drukarki, ustawienia, Spoolbase i bezpiecznie przechowywane kody dostępu. Historia wydruków i liczniki konserwacji zaczynają się naliczać od pierwszego uruchomienia nowej wersji.

Po aktualizacji na macOS system może poprosić o ponowne przyznanie dostępu do sieci lokalnej. Znajdziesz to w Ustawieniach systemowych, w sekcji Prywatność i ochrona, Sieć lokalna.

## Kontrola jakości

- automatyczna kontrola zgodności kontraktu UI macOS, Windows i Linux;
- 28 testów jednostkowych macOS i 57 testów rdzenia oraz integracji wersji Linux;
- osobne workflow budujące macOS, Windows oraz pakiety `.deb`, `.rpm` i `.AppImage`.
