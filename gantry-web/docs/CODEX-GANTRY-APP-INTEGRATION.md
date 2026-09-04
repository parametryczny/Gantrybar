# Instrukcja dla Codexa — integracja aplikacji Gantry z Gantry Web

## Cel

Zmodyfikuj aplikacje Gantry na macOS, Windows i Linux tak, aby opcjonalnie publikowały bieżący, pozbawiony sekretów snapshot floty do samodzielnie hostowanego Gantry Web.

Jest to osobna funkcja o nazwie **Gantry Web Link**. Lokalny dashboard aplikacji zostaje bez zmian: pozostaje tylko do odczytu i nie przyjmuje żadnych zapisów.

## Pliki źródłowe kontraktu

- schema: [`/Users/kamilgrzegorczyk/Documents/bambu lab monitor/gantry-web/contract/gantry-web-link.schema.json`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/gantry-web/contract/gantry-web-link.schema.json)
- przykład: [`/Users/kamilgrzegorczyk/Documents/bambu lab monitor/gantry-web/contract/example-snapshot.json`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/gantry-web/contract/example-snapshot.json)
- API: [`/Users/kamilgrzegorczyk/Documents/bambu lab monitor/gantry-web/docs/API.md`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/gantry-web/docs/API.md)
- serwer referencyjny: [`/Users/kamilgrzegorczyk/Documents/bambu lab monitor/gantry-web/server.mjs`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/gantry-web/server.mjs)

## Bezwzględne wymagania bezpieczeństwa

1. Wysyłaj wyłącznie na URL z `https://`. `http://` dopuść tylko dla `localhost`, `127.0.0.1` i prywatnych adresów w trybie deweloperskim.
2. Nie wysyłaj:
   - kodów dostępu Bambu;
   - kluczy Moonraker/Prusa;
   - haseł, tokenów MQTT, certyfikatów ani pinów certyfikatów;
   - lokalnego IP/hosta drukarki;
   - pełnej konfiguracji `SavedPrinter`/`Printer`.
3. Web Link Key musi być sekretem używanym wyłącznie przez Web Link, niedzielonym z żadnym innym mechanizmem.
4. Klucz ma mieć 32 losowe bajty. Format tekstowy: `GW1-` + base64url bez paddingu. Nie używaj UUID jako klucza.
5. Na macOS klucz przechowuj w osobnym elemencie Keychain, na Windows przez DPAPI, na Linux przez Secret Service. URL i przełącznik mogą być w zwykłych ustawieniach.
6. Logi nigdy nie mogą zawierać nagłówka `Authorization`, Web Link Key ani pełnego body snapshotu.
7. Funkcja jest domyślnie wyłączona. Użytkownik musi świadomie wpisać adres i włączyć publikowanie.
8. Pierwsza wersja pozostaje tylko do odczytu. Nie dodawaj endpointu poleceń i nie odbieraj z serwera komend drukowania.

## Zachowanie wspólne

Dodaj ustawienia:

```text
webLinkEnabled: Bool = false
webLinkServerURL: String = ""
webLinkDeviceID: trwały UUID generowany raz
webLinkDeviceName: domyślna nazwa komputera, edytowalna
webLinkKey: sekret w bezpiecznym magazynie
```

Sekcja ustawień „GANTRY WEB” zawiera:

- przełącznik „Publikuj do Gantry Web”;
- pole adresu serwera;
- pole Web Link Key z przyciskiem pokaż/ukryj;
- „Generuj nowy klucz”;
- „Kopiuj klucz”;
- „Testuj połączenie”;
- stan: wyłączone / łączenie / połączono i czas ostatniej wysyłki / 401 / błąd TLS / błąd sieci.

„Generuj nowy klucz” nie może automatycznie nadpisywać istniejącego bez potwierdzenia, ponieważ odłącza serwer. Rotacja wymaga wklejenia nowego klucza również w panelu WWW.

## Algorytm publishera

1. Obserwuj zmiany `printers`, `telemetry` oraz danych Spoolbase użytych do wyświetlenia AMS.
2. Zbuduj snapshot zgodny z v1.
3. Zakoduj stabilnym JSON-em i policz SHA-256 body.
4. Jeśli hash nie zmienił się od ostatniego sukcesu, nie wysyłaj częściej niż heartbeat co 20 sekund.
5. Zmiany grupuj przez debounce 500 ms i limituj do maksymalnie jednego PUT na 2 sekundy.
6. Wyślij:

   ```http
   PUT {serverURL}/api/v1/devices/{urlEncodedDeviceID}/snapshot
   Authorization: Bearer {webLinkKey}
   Content-Type: application/json
   User-Agent: Gantry/{version} ({platform})
   ```

7. Jeden request aktywny naraz. Jeśli podczas wysyłania pojawi się nowa telemetria, ustaw `needsAnotherPush` i wyślij ponownie po zakończeniu.
8. Backoff po błędzie: 2, 5, 10, 30, 60 sekund plus jitter 0–20%. Sukces zeruje backoff.
9. `401` zatrzymuje automatyczne próby do czasu zmiany URL/klucza albo kliknięcia „Testuj”.
10. Przy wyłączaniu aplikacji nie blokuj procesu; ostatni snapshot jest best effort.

## Mapowanie snapshotu

### Identyfikator drukarki

Użyj stabilnego `serial`, ale przed wysłaniem można go pseudonimizować:

```text
printer.id = base64url(SHA256("gantry-web-v1:" + serial)).prefix(32)
```

Pseudonimizacja jest rekomendowana, ponieważ serwer nie potrzebuje prawdziwego numeru seryjnego. Musi być identyczna na wszystkich platformach, aby merge nie dublował tej samej drukarki.

### Connection type

- Bambu → `MQTT`
- Klipper → `KLIPPER`
- Prusa → `PRUSALINK`
- Snapmaker → `SNAPMAKER`

### Job

- `fileName`: tylko dla `printing`/`paused`; dla idle nie wysyłaj ostatniego zadania;
- `progress`: 0–100;
- `remainingSeconds`: lokalne minuty × 60;
- `eta`: aktualny czas + remaining, ISO-8601 UTC;
- warstwy: 0, jeśli brak danych.

### Temperatury

- pojedyncza drukarka: jeden element `nozzles` z pustym `label`;
- X2/H2D: dwa elementy, etykiety `L` i `P` albo zgodne z tym, co pokazuje karta desktopowa;
- brak sensora reprezentuj jako `null`, nie jako zero;
- target komory może być `null`.

### Filamenty

Użyj tych samych znormalizowanych grup, które trafiają do bento desktopowego:

- zwykły AMS → `ams`;
- AMS HT → `ams-ht`;
- zewnętrzna szpula → `ext`;
- pusty slot: `present=false`, pusty `material`, ale zachowaj etykietę slotu;
- `colorHex` bez `#`;
- procenty i gramy mogą być `null`.

## macOS — konkretne zmiany

### Nowe pliki

Utwórz:

- `Sources/Gantry/Services/GantryWebLinkModels.swift` — wyłącznie struktury `Codable`, `Sendable` odpowiadające schema v1;
- `Sources/Gantry/Services/GantryWebLinkSecretStore.swift` — osobny Keychain service `pl.gantry.web-link-key.v1`, account `default`;
- `Sources/Gantry/Services/GantryWebLinkService.swift` — `@MainActor final class`, obserwacja store, debounce, heartbeat, PUT i backoff.

### Ustawienia

W [`AppSettings.swift`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/Sources/Gantry/App/AppSettings.swift) dodaj `@Published` dla enabled, URL i device name oraz trwałe device ID. Nie dodawaj sekretu do `UserDefaults`.

W [`GantryApp.swift`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/Sources/Gantry/App/GantryApp.swift:103) po utworzeniu `PrinterStore` utwórz jeden `GantryWebLinkService`, zachowaj go jako pole `AppDelegate` i uruchom po `store.reconnectAll()`. Publisher ma reagować na zmianę ustawienia bez restartu.

W [`SettingsWindowController.swift`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/Sources/Gantry/Views/SettingsWindowController.swift) dodaj osobną sekcję poniżej lokalnego „Podgląd w przeglądarce”. Nie zmieniaj obecnego przełącznika LAN i nie nazywaj hostowanego panelu „Sync”.

### Transport

Użyj osobnej `URLSession` z:

- `ephemeral` configuration;
- `waitsForConnectivity = true`;
- timeout request 10 s, resource 15 s;
- bez cache i cookies;
- domyślna walidacja TLS, bez customowego `URLSessionDelegate` i bez akceptowania niezaufanych certyfikatów.

### Testy macOS

Dodaj testy:

- encoder generuje body zgodne z example/schema;
- body nie zawiera pól `host`, `accessCode`, `apiKey`, `token`;
- podwójna dysza zachowuje dwa elementy i małe etykiety;
- kilka AMS + EXT zachowuje kolejność i typy;
- publisher debouncuje i nie wykonuje dwóch requestów równolegle;
- `401` ustawia stan wymagający działania użytkownika;
- URL HTTP jest odrzucany poza localhostem/trybem deweloperskim.

## Windows — konkretne zmiany

### Nowe pliki

Utwórz w `windows/Gantry.Windows/Services/`:

- `GantryWebLinkModels.cs`;
- `GantryWebLinkSecretStore.cs`;
- `GantryWebLinkService.cs`.

Modele oznacz `[JsonPropertyName]` albo użyj spójnych `JsonSerializerOptions` z camelCase.

### Sekret i ustawienia

W [`Storage.cs`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/windows/Gantry.Windows/Services/Storage.cs) dodaj niesekretne pola do `AppSettings`. Klucz zaszyfruj `ProtectedData.Protect(..., DataProtectionScope.CurrentUser)` i zapisz osobno pod `%AppData%\Gantry\web-link-key.dat`. Ustaw prawa pliku możliwie restrykcyjnie; nie zapisuj base64 klucza w `defaults.json`.

W [`App.xaml.cs`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/windows/Gantry.Windows/App.xaml.cs:77) utwórz i zachowaj `GantryWebLinkService` po `PrinterStore.ReconnectAll()`. Zatrzymaj/dispose w `OnExit`.

W [`SettingsWindow.xaml`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/windows/Gantry.Windows/UI/SettingsWindow.xaml) oraz [`SettingsWindow.xaml.cs`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/windows/Gantry.Windows/UI/SettingsWindow.xaml.cs) dodaj identyczne znaczeniowo kontrolki jak na macOS.

### Transport

Użyj jednego `HttpClient` z timeoutem 10 s. Nie twórz nowego klienta na każdą wysyłkę. Domyślna walidacja certyfikatu ma pozostać aktywna. Serializuj ISO-8601 w UTC.

### Testy Windows

Dodaj osobny projekt testowy, jeśli nadal go nie ma. Testuj mapper, brak sekretów, DPAPI round-trip, throttling, 401 i odrzucenie publicznego HTTP. Nie ograniczaj weryfikacji do `--self-test`.

## Linux — konkretne zmiany

### Nowe pliki

Utwórz:

- `linux/gantry/web_link.py` — dataclasses/dict mapper, worker publishera, backoff;
- `linux/tests/test_web_link.py` — mapper i transport przez lokalny testowy HTTP server.

W [`storage.py`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/linux/gantry/storage.py) dodaj URL, enabled, device ID i device name do `DEFAULTS`. Klucz przechowuj przez `secret-tool` pod osobnym zestawem atrybutów:

```text
application Gantry purpose web-link account default
```

Nie używaj identyfikatora drukarki jako klucza Web Link.

W [`app.py`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/linux/gantry/app.py:750) uruchom publisher po `reconnect_all()`, a w `quit()` zatrzymaj worker. Wysyłanie wykonuj poza wątkiem GTK i wracaj do UI przez `GLib.idle_add` tylko przy aktualizacji widocznego stanu.

Do HTTP można użyć istniejącej warstwy z [`http_clients.py`](/Users/kamilgrzegorczyk/Documents/bambu%20lab%20monitor/linux/gantry/http_clients.py), ale nie wolno wyłączać walidacji TLS. Jeśli warstwa nie obsługuje PUT lub nagłówków Bearer, rozszerz ją bez kopiowania klienta.

## Test po integracji wszystkich platform

1. Uruchom Gantry Web lokalnie z losowym setup tokenem.
2. Skonfiguruj panel przykładowym kluczem długości co najmniej 32 znaków.
3. Na każdej platformie sprawdź „Testuj połączenie”.
4. Zweryfikuj w DevTools/serwerze, że body nie zawiera `host`, kodów dostępu ani kluczy API.
5. Uruchom dwie aplikacje z tą samą drukarką; w panelu ma pozostać jeden kafel z nowszego snapshotu.
6. Zamknij publisher; po TTL drukarka ma przejść w offline.
7. Zmień klucz w panelu; stary klient ma dostać 401 i zatrzymać retry.
8. Sprawdź pojedynczą dyszę, dwie dysze, AMS, AMS HT, EXT, kilka AMS oraz puste sloty.
9. Sprawdź widok na 360 px, 640 px, 1024 px i dużym ekranie.

## Kryterium ukończenia

Integracja jest ukończona dopiero, gdy:

- macOS, Windows i Linux generują ten sam JSON dla tej samej telemetrii;
- wszystkie testy przechodzą;
- klucze są w magazynach sekretów;
- po wyłączeniu Web Link nie działa żaden timer ani request;
- aplikacja nie loguje sekretów;
- panel działa przez HTTPS i aktualizuje się bez ręcznego odświeżania;
- dokumentacja użytkownika rozróżnia lokalny dashboard i hostowany Gantry Web.
