# Sieć drukarek

W wersji macOS otwórz **Ustawienia → Zaawansowane → Sieć drukarek**. W osobnym wydaniu LITE sekcja znajduje się w Ogólnych.

Przełącznik **Osobna sieć drukarek** jest domyślnie wyłączony. Włącz go, aby rozwinąć wybór interfejsu i opcje połączenia. Wyłączenie działa od razu: Gantry wraca do tras systemowych, zachowując ostatnio zapisany adapter i ustawienie ścisłe. Ponowne włączenie przywraca zapisaną konfigurację. Parametry poniżej przełącznika nadal zatwierdzasz przyciskiem Zapisz.

- **Automatycznie** — dotychczasowe zachowanie, według tras systemowych.
- **Wi-Fi / Ethernet** — wybierz aktywny interfejs tego typu. Lista poniżej pozwala wskazać konkretną kartę, również VPN. Zapisany jest jej identyfikator, a nie zmieniający się adres IP.
- **Tylko wybrana sieć** — domyślnie włączone. Gdy karta zniknie, Gantry czeka na jej powrót. Wyłączenie pozwala użyć tras systemowych, gdy wybrany interfejs jest niedostępny.

Kafelki zmieniają roboczy wybór. Dopiero **Zapisz** zapisuje ustawienie i odnawia połączenia drukarek oraz kamer. Zmiany stanu wybranej karty są obserwowane w tle.

**Sprawdź połączenie** sprawdza dostępność portu TCP zapisanych drukarek przez roboczo wybraną kartę. Nie wysyła haseł ani poleceń i nie potwierdza poprawności logowania lub obrazu z kamery. Starsze urządzenia korzystające wyłącznie z UDP są pomijane w tym teście.

## Przykład: Wi-Fi drukarek i internet z telefonu

Pozostaw komputer połączony z Wi-Fi drukarek. Podłącz telefon przez USB i skonfiguruj jego internet w systemie. W Gantry wybierz Wi-Fi i zapisz. System nadal decyduje o internecie pozostałych aplikacji; Gantry przypina swoje połączenia do urządzeń do wskazanej karty. Wybór nie zmienia kolejności usług, tras systemowych ani ustawień przeglądarki.

Jedna zwykła karta Wi-Fi nie łączy się jednocześnie z Wi-Fi drukarek i hotspotem telefonu. Potrzebne są dwa niezależne interfejsy: np. Wi-Fi + USB telefonu, Wi-Fi + Ethernet lub dodatkowa karta Wi-Fi. Ten wybór nie tworzy połączenia VPN i nie przekazuje drukarek do internetu.

## Ograniczenie HTTPS z adresem IP

W ręcznym trybie HTTPS przez Foundation wymaga nazwy hosta urządzenia, np. `printer.local`. System może ominąć proxy dla adresu IP w URL HTTPS, dlatego Gantry blokuje taki URL, gdy konkretna karta jest dostępna i przypięta. Użyj nazwy hosta albo trybu Automatycznie. Przy jawnie dozwolonym powrocie do tras systemowych i niedostępnej karcie to ograniczenie nie obowiązuje.

Nie dotyczy to natywnego MQTT/TLS ani kamery JPEG/RTSP Bambu, które używają bezpośredniego przypięcia Network.framework. Walidacja certyfikatów istniejących sesji HTTPS nie jest rozluźniana ani zastępowana.

## Zakres

Wybór obejmuje natywne połączenia drukarek, HTTP i WebSocket, kamery, transfery, lokalne narzędzia i gniazdka oraz wykrywanie SSDP/Elegoo i skan podsieci. Telegram, aktualizacje i połączenie z hostingiem zachowują trasy systemowe. Serwer WWW nadal nasłuchuje zgodnie ze swoją konfiguracją.

Zmiana sieci przerywa dotychczasowe sesje do urządzeń. Gantry odnawia monitorowanie; trwający transfer może wymagać ręcznego ponowienia. Sam zapis nie uruchamia wydruku i nie powtarza komend sterujących.

Sprawdzenie automatyczne transportów jest opisane w `scripts/check_printer_network.py`. Test fizycznego przełączenia Wi-Fi/USB wymaga komputera z tymi dwoma aktywnymi połączeniami.
