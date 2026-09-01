# Historia zmian Gantry

Wszystkie istotne zmiany w aplikacji Gantry (dawniej BambuBar / PrismBar) są opisane w tym pliku.

## 0.10.0 - 2026-09-01

To wydanie ujednolica macOS, Windows i GNU/Linux wokół dopracowanego interfejsu oraz flow wersji macOS. Windows i Linux otrzymują zgodny pulpit, proporcje sekcji AMS / AMS HT / EXT, krótkie pastylki filamentu, spójne okna Szczegółów, Ustawień, edycji i dodawania drukarki, a także poprawione Spoolbase i przypisywanie fizycznych rolek.

### Najważniejsze

- dodano obsługę **Elegoo Centauri Carbon (CC1)** przez lokalny SDCP/WebSocket oraz **Centauri Carbon 2 (CC2)** przez lokalny MQTT w trybie LAN-only, wraz z wykrywaniem, telemetrią i kamerą MJPEG;
- zmiana motywu i przezroczystości odświeża interfejs natychmiast, także na Windows, bez przechodzenia do Szczegółów lub restartu;
- ujednolicono zachowanie przycisków głównego paska, nawigację widoku Szczegółów i obsługę okien dodatkowych;
- dodano automatyczny kontrakt zgodności UI dla macOS, Windows i Linux oraz testy układu kart;
- przygotowano workflow i skrypty budowania Linuxa jako `.deb`, `.rpm` oraz przenośnego `.AppImage`.

### GNU/Linux

Pakiety Linux dla 0.10.0 są **w przygotowaniu** i przechodzą testy integracyjne. `.deb` i `.rpm` zapewnią klasyczną instalację systemową, a `.AppImage` będzie pojedynczym przenośnym plikiem z aplikacją i większością wymaganych bibliotek.

Pełny opis wydania: [`docs/release-0.10.0.md`](docs/release-0.10.0.md).

## 0.9.0 - 2026-08-29

Dalej dopracowujemy wygląd i wydajność oraz sukcesywnie dodajemy personalizację. W tym wydaniu dochodzą też duże rzeczy: **śledzenie fizycznych rolek filamentu w Spoolbase** (z automatycznym odejmowaniem wagi po wydruku), **podgląd floty w przeglądarce**, **synchronizacja między komputerami**, a na macOS **uniwersalny build (Intel + Apple Silicon)**. Na Windows dochodzi natywny efekt szkła i dopracowanie karty do parytetu 1:1 z macOS.

Najważniejsze: to wydanie domyka **parytet na trzech platformach**. Linux dostaje pełny komplet nowości i nadrabia to, co dotąd było tylko na macOS/Windows: **widok „Szczegóły”, automatyzacje ze sterowaniem i podgląd kamery na żywo**, a do tego fizyczne rolki z odejmowaniem wagi, podgląd floty w przeglądarce, synchronizację i efekt szkła. Ten sam zestaw funkcji i ten sam układ karty działają teraz na macOS, Windows i Linux; różni się tylko natywny rendering każdego systemu (czcionki, sposób realizacji frosted‑glass).

### Fizyczne rolki filamentu (nowość)

Do tej pory Spoolbase znał tylko rodzaje filamentu. Teraz możesz prowadzić konkretne rolki z wagą, przypisane do slotów AMS/EXT. Stan należy do rolki, nie do slotu, więc gdy przełożysz ją do innej drukarki, gramy jadą razem z nią.

Jak dodać filament do AMS, krok po kroku:

1. Kliknij pastylkę slotu (fasolkę AMS albo EXT) na karcie drukarki. Otworzy się panel przypisania dla tego slotu (np. „AMS A2").
2. Panel pokazuje materiał widziany przez AMS, aktualnie przypisaną rolkę (albo „Brak") i listę Twoich rolek.
3. Masz już rolkę w bazie? Wybierz ją z listy. Pasujące materiałem i kolorem są na górze i podświetlone. Jeśli rolka jest w innej drukarce, Gantry zapyta „Przenieść tutaj?" i zwolni poprzedni slot.
4. Nowa rolka? Kliknij „+ Nowa rolka":
   * wybierz filament ze swojego katalogu Spoolbase (albo „Nowa definicja z AMS", która weźmie materiał i kolor prosto z drukarki),
   * podaj ilość na start: 1000, 750, 500 g albo własną wartość,
   * gotowe. Rolka dostaje własne ID, np. `SP-00001`.
5. Od teraz slot pokazuje realny procent i gramy (liczone lokalnie z pozostałej wagi), w kolorze wybranego filamentu, nawet dla filamentu bez RFID.
6. Wymiana lub zdjęcie: kliknij slot ponownie i użyj „Odepnij", albo przypisz inną rolkę.
7. Przenoszenie między drukarkami: wyjmujesz rolkę, w drugiej drukarce klikasz slot i wybierasz tę samą rolkę (`SP-000xx`). Stan zostaje bez zmian.

Działa dla AMS i zewnętrznej szpuli (EXT), wspólnie dla wszystkich drukarek, dane są trwale zapisywane. Jedna rolka może być tylko w jednym miejscu naraz.

Jeśli do slotu z ręcznie przypisaną rolką **włożysz rolkę z tagiem NFC/RFID**, Gantry rozpozna, że tamta rolka została wyjęta, i **automatycznie odpina** przypisaną (wraca do magazynu). Na karcie pojawia się wtedy krótka informacja z przyciskiem **OK**, np. „SP-00003 wróciła do magazynu (wykryto tag NFC w AMS A3)".

### Automatyczne odejmowanie wagi po wydruku (nowość)

Po zakończonym wydruku Gantry odejmuje realnie zużyty filament od przypisanej rolki, lokalnie i bez chmury:

* **Klipper / Moonraker:** realne `filament_used` (mm) przeliczone na gramy (Ø1,75),
* **Bambu:** `used_g` z wydrukowanego pliku `.gcode.3mf` pobranego po **lokalnym FTPS** (bez logowania do chmury, bez chmury Bambu).

Odejmowanie jest **idempotentne per zadanie**, więc reconnect, restart albo dwa komputery patrzące na tę samą drukarkę nie policzą zużycia podwójnie.

### Gramy z AMS (tag NFC/RFID)

* nowy przełącznik w Ustawieniach, w sekcji „Karty drukarek": **„Gramy na rolce (AMS NFC / Spoolbase)"**, domyślnie wyłączony,
* po włączeniu pod slotem widać pozostałe gramy: dla rolek Bambu **z tagiem RFID/NFC** liczone z odczytu tagu (`tray_weight × remain%`), a dla rolek przypisanych w Spoolbase z ich wagi,
* rolka bez tagu i bez przypisania nie ma skąd wziąć wagi (można przypisać rolkę Spoolbase).

### Podgląd floty w przeglądarce (nowość)

* lekki, **tylko do odczytu** serwer WWW w sieci lokalnej: całą flotę widać z telefonu albo innego komputera w tej samej sieci Wi-Fi, bez logowania i bez chmury,
* **na żywo przez WebSocket** (push przy każdej zmianie), z automatycznym fallbackiem na odpytywanie,
* ta sama estetyka co aplikacja: karty, kolorowe temperatury, sloty AMS/EXT, procent,
* w Ustawieniach nowa sekcja z **adresami** (`<nazwa>.local` i IP), **kodem QR** do zeskanowania telefonem oraz **przełącznikiem włączania serwera** (wyłączony = zero otwartych portów).

### Synchronizacja między komputerami (nowość)

* dwukierunkowa synchronizacja **Spoolbase, listy drukarek i ustawień** między Twoimi komputerami, **tylko w sieci lokalnej** (bez chmury),
* parowanie przez **wspólny token**: kopiujesz go z jednego komputera na drugi i podajesz adres, reszta dzieje się sama,
* scalanie „ostatni wygrywa" po czasie; zużycie filamentu jest idempotentne, więc wspólny wydruk nie odejmie się podwójnie,
* **kody dostępu do drukarek nie są przesyłane** (zostają w Keychain każdego komputera).

### Uniwersalny build macOS i niższy próg systemu

* aplikacja macOS jest teraz **uniwersalna (Apple Silicon + Intel)** — koniec z przekreśloną ikoną i komunikatem „tylko na układach Apple" na Intelu,
* **obniżony próg do macOS 13 (Ventura)**: jedyne API blokujące starsze systemy (efekt „liquid glass") ma teraz łagodny fallback.

### Windows: natywny efekt szkła i parytet karty z macOS

* główny dymek to teraz prawdziwy **Desktop Acrylic** (rozmyte tło pulpitu pod ciemnym, półprzezroczystym tintem, zaokrąglone rogi); przełącznik **Przezroczystość (Mała / Średnia / Duża)** steruje tylko siłą tintu, bez restartu, z fallbackiem na solidny ciemny panel,
* karta dopracowana do macOS: **wordmark GANTRY** i licznik „X drukarek · Y pracuje", **ikona wykresu** zamiast napisu „Szczegóły", uchwyt przeciągania i „⋯" w zaokrąglonych pigułkach, temperatury z **„/ —"** przy braku wartości zadanej, **kreskowanie** pustych slotów, karta offline bez dublowania komunikatu.

### Linux: parytet funkcji z macOS

* **widok „Szczegóły”**: wykres temperatur w czasie (dysza / stół / komora), temperatury z wartościami zadanymi, wentylatory (części / aux / komora), poziom prędkości i średnica dyszy, moduły AMS/EXT oraz postęp / warstwy / ETA; wejście z ikony wykresu na karcie i z menu,
* **automatyzacje ze sterowaniem**: reguły per drukarka (wyzwalacz: po warstwie / po % / na stan; akcja: światło komory, pauza/wznów/stop, powiadomienie, własna komenda MQTT/G‑code, skrypt), odpalane raz na wydruk; akcje „komenda” i „skrypt” są domyślnie wyłączone i wymagają jednorazowej zgody (kill‑switch w Ustawieniach),
* **podgląd kamery na żywo**: Bambu przez RTSPS:322 (ffmpeg jako dekoder H.264, akceptacja self‑signed), Klipper/Moonraker jako MJPEG czytany natywnie; wejście z karty i z Szczegółów,
* **fizyczne rolki w Spoolbase**: klik w slot AMS/EXT otwiera panel przypisania (rolka z katalogu, nowa rolka, przeniesienie istniejącej, ustawienie pozostałych gramów, odłączenie do magazynu); slot pokazuje kolor i gramy przypisanej rolki,
* **automatyczne odejmowanie wagi po wydruku** (Klipper realnie z `filament_used`, Bambu z `used_g` w `.gcode.3mf` pobieranym po FTPS), idempotentne per zadanie,
* **auto‑odpięcie** przy włożeniu rolki z tagiem NFC/RFID, z **krótką informacją na karcie** i przyciskiem OK,
* **podgląd floty w przeglądarce** i **dwukierunkowa synchronizacja** (Spoolbase, katalog filamentów, lista drukarek i ustawienia) w sieci lokalnej, zgodna z macOS/Windows,
* frosted‑glass dymka tray (rozmycie na KWin, przezroczystość w innych środowiskach).

### Personalizacja

* Przełącznik kolumn 1 / 2 w nagłówku (szeroka lub ostatnia samotna karta zajmuje pełną szerokość, zasada 2-2-1).
* „Karty drukarek" w Ustawieniach: włącz albo wyłącz Nazwę pliku, Postęp, Temperatury, Filamenty / AMS (a teraz również Gramy na rolce).
* „Dostosuj…" w Szczegółach: ukryj moduły (Kamera, AMS, Temperatury, Wentylatory, Sterowanie), przestawiaj kafle, wróć do domyślnego układu.

### Spokojniejsze, płaskie karty

* Stonowana kolorystyka: stan czyta się z tekstu i ikony, kolor niosą tylko wartości temperatur i realne kolory filamentu.
* Płaski układ: zamiast pudełek w pudełku sekcje (zadanie, temperatury, filamenty) rozdzielają długie, cienkie linie. Między urządzeniami (AMS, HT, EXT) delikatna pionowa kreska.
* Temperatury: kolor tylko na liczbie (dysza, stół, komora), a kafel komory znika, gdy nie ma czujnika.
* Filamenty: procent wewnątrz kolorowej fasolki z auto-kontrastem, poziom wypełnia się od dołu z delikatną falą, a każdy kafelek ma cienki obrys, więc pusta lub 0% rolka nie ginie.
* **Sloty pojedyncze (AMS HT / EXT)** to szerszy, wyśrodkowany prostokąt skalujący się z kartą (35% kolumny, min 60 px); grupa AMS jest ~3× szersza od pojedynczej, a dwie pojedyncze obok siebie (HT + EXT) są równe. Sloty nie migają ani nie skaczą przy odświeżaniu.

### Offline

* Gdy drukarka traci połączenie, jej karta przygasa i pokazuje komunikat błędu. Menu i Szczegóły dalej są dostępne.

### Poprawki

* **Nazwa pliku po wydruku:** karta pokazuje nazwę zadania tylko podczas druku; po zakończeniu i w bezczynności wraca „BRAK AKTYWNEGO ZADANIA" (koniec ze starą nazwą wiszącą po zakończeniu i po odświeżeniu).
* **[#27] Fałszywy „Filament low" dla rolek bez chipa:** ostrzeżenie (czerwona kropka i powiadomienie) odpala się tylko przy wiarygodnym odczycie poziomu, czyli tag RFID/NFC (waga) albo przypisana rolka Spoolbase; rolka bez chipa (remain=0 „nieznane") już nie wywoła alarmu.

### Pod maską

* Segmentowy pasek postępu, licznik warstw przy ETA (pełna nazwa pliku przestała się ucinać).
* Kompaktowy nagłówek i węższe okno, więcej drukarek na ekranie.

## 0.8.0 — 2026-08-20

Duże wydanie: pełny widok **„Szczegóły"** drukarki, **podgląd kamery na żywo**, **automatyzacje ze sterowaniem** i **nadpisania per‑drukarka** — najpierw na macOS, a w tym wydaniu doprowadzone do **parytetu 1:1 na Windows**.

### Szczegóły drukarki (nowość)

- nowy widok **„Szczegóły"** otwierany **w obrębie głównego dymka** (z przyciskiem **„‹ Wróć"**), nie jako osobne okno — spójnie na macOS i Windows
- wejście prosto z karty: **widoczny przycisk „Szczegóły"** przy nazwie (oraz nadal z menu ⋯)
- zawartość: **wykres temperatur w czasie** (dysza / stół / komora), temperatury z wartościami zadanymi, **wentylatory** (part / aux / komora), **poziom prędkości** i **średnica dyszy**, **AMS/filamenty** tym samym widokiem co okno główne (AMS / AMS+EXT / EXT / AMS HT) z **pozostałym %** i wizualnym wypełnieniem szpuli, oraz postęp / warstwy / ETA
- **kafle Szczegółów można przestawiać** metodą przeciągnij‑i‑upuść (uchwyt ⠿); kolejność jest zapamiętywana
- widok tylko‑do‑odczytu jest domyślny; sterowanie pojawia się w trybie deweloperskim

### Kamera na żywo

- **Bambu (macOS):** natywny odbiór **RTSPS na porcie 322** (`rtsps://…/streaming/live/1`, LIVE555, autoryzacja Digest) — działa nawet przy połączeniu z chmurą, wystarczy **„LAN Mode Live View"** na drukarce; dekodowanie H.264 przez VideoToolbox. Zastępuje nieskuteczny na nowszym firmware strumień portu 6000
- **Bambu (Windows):** własny natywny klient **RTSPS/RTSP/JPEG** — aplikacja sama nawiązuje TLS i **akceptuje self‑signed certyfikat drukarki**, a `ffmpeg` służy wyłącznie jako dekoder H.264 (bez sieci/TLS). Kolejność prób **322 → 554 → 6000** (A1/P1), autoryzacja Digest/Basic. W rogu obrazu **plakietka trybu i rozdzielczości** (np. `RTSPS · 1920×1080`)
- **Klipper / Creality (Moonraker):** podgląd jako **MJPEG** (z `/server/webcams/list`, fallback `/webcam/?action=snapshot`)
- czytelne komunikaty, gdy drukarka nie oddaje obrazu (np. wyłączony podgląd LAN)

### Automatyzacje i sterowanie

- Gantry potrafi teraz **wysyłać komendy** (dotąd tylko czytał): **światło komory**, **pauza / wznów / stop**
- **silnik reguł „raz na wydruk":** wyzwalacz (ręcznie / po warstwie ≥ N / po ≥ % / zmiana stanu) → akcja: **LED**, **pauza/wznów/stop**, **powiadomienie**, **własna komenda** (Bambu: JSON MQTT / Klipper: G‑code) lub **skrypt**
- **skrypty własne:** wskazanie pliku albo **wklejenie kodu** z obsługą **shebang** (`#!/usr/bin/env python3` itd.), więc można wklejać czysty kod `.py`
- osobny **edytor reguł** (dodaj / edytuj / usuń, Uruchom / Stop, skrypt z potwierdzeniem)
- reset licznika reguł następuje **tylko przy realnym końcu wydruku** (idle/finished) — koniec z regułą odpalaną w kółko (np. gaszeniem lampy) przez chwilowe gubienie nazwy zadania w raportach MQTT
- dokumentacja: **[`docs/automations.md`](docs/automations.md)** — komendy, przykłady skryptów i przepisy (w tym Python)

### Nadpisania per‑drukarka („Zaawansowane…")

- **opcjonalne IP kamery** — gdy kamera jest pod innym adresem niż drukarka (np. Raspberry Pi z kamerą)
- **własne komendy światła** wł./wył. (Bambu: JSON MQTT / Klipper: G‑code)
- **nazwy obiektów Moonraker** dla niestandardowych konfiguracji Klippera: **dysza / stół / czujnik komory / wentylator** (puste = domyślne/auto); zapis od razu ponawia połączenie

### Tryb deweloperski

- nowy przełącznik w Ustawieniach; odsłania **kafel „Sterowanie i automatyzacje"** w Szczegółach oraz (macOS) diagnostyczny **podgląd surowego AMS** (JSON `ams`/`vt_tray`/`vir_slot`)

### Parytet Windows (1:1 z macOS)

- pełna migracja powyższych funkcji na Windows: Szczegóły, telemetria wentylatorów / prędkości / ⌀ dyszy, historia temperatur, sterowanie + automatyzacje, nadpisania per‑drukarka, tryb deweloperski i kamera

### Wygląd i poprawki

- **spokojniejsze okno główne (macOS):** karty nie zalewają się kolorem stanu — kolor zostaje na kropce, pasku i tekście, błąd to cienka statyczna krawędź; „Szczegóły" jako stonowany chip z obrysem
- **Windows:** po wejściu i wyjściu ze Szczegółów okno od razu dobiera właściwą wysokość (bez chwilowego „za dużego" okna)
- pod maską: kamera Bambu na Windows przez statyczny `ffmpeg.exe` (dokładany przez CI) zamiast LibVLC, który nie obsługiwał schematu `rtsps://`

## 0.6.0 — 2026-08-09

- **Linux hotfix:** jawne przypięcie `Gdk 3.0`, `Gtk 3.0`, `GLib 2.0` i `Pango 1.0` przed importem PyGObject; usuwa awarię startu na Ubuntu 26.04, gdy równolegle zainstalowane są biblioteki GTK 3 i GTK 4
- **nowa nazwa i logo: Gantry** — litera **G** na pasku menu / w zasobniku i jako ikona aplikacji (macOS `.icns`, Windows `.ico`); zapisane drukarki, kody i uprawnienia pozostają bez zmian
- **modularny filament** — każdy fizyczny moduł (AMS, AMS HT, CFS, MMU, EXT) to osobna grupa z własną nazwą, wilgotnością i temperaturą; AMS HT / pojedyncza szpula pokazują 1 slot, standardowy AMS trzyma 4 pozycje (puste zostają szare)
- **Creality CFS** — każdy box jako osobny zestaw (`CFS 1`, `CFS 2`), szpula zewnętrzna jako `EXT`; **Klipper / Happy Hare** — dowolna liczba bramek `T0…Tn` bez sztucznego dzielenia po cztery
- **dwie dysze** na drukarkach dwudyszowych (H2D) pokazywane jawnie jako **L / P** (PL) lub **L / R** (EN); **temperatura komory** tylko dla drukarek z realnym czujnikiem
- **prywatność: import konfiguracji Bambu Studio za jawną zgodą** — nic nie jest czytane z plików slicera, dopóki nie zaznaczysz zgody (checkbox + komunikat) przy dodawaniu drukarki
- przeprojektowane kafle: duże kafelki koloru z etykietą pod spodem, aktywny slot z białym pierścieniem, równa wysokość kafli w wierszu
- **poprawka:** biała ramka aktywnego slotu AMS nie znika już po połączeniu — częściowy raport MQTT nie kasuje aktywnego slotu ani grup
- ten sam model danych i układ na macOS, Windows i GNU/Linux

## 0.5.0 — 2026-08-05

- dodano pierwszą wersję beta **Gantry dla GNU/Linux** z interfejsem GTK 3 i ikoną w zasobniku systemowym
- wersja Linux łączy się bezpośrednio z drukarkami Bambu przez MQTT/TLS, pokazuje stan, postęp, ETA, warstwy, temperatury oraz sloty AMS
- dodano w Linux i kiosku RPi wybór **Bambu Lab / Klipper / Prusa**; Moonraker obsługuje status, temperatury, ETA, Happy Hare MMU i Creality CFS, a PrusaLink status, postęp, czas, temperatury i nazwę pliku
- formularz dodawania, panel telefonu oraz import CSV rozpoznają typ drukarki i właściwe porty: Bambu `8883`, Moonraker `7125`, PrusaLink `80`
- dodano automatyczne wykrywanie przez SSDP i certyfikat MQTT, ręczne IP i port oraz dodatkowe cele VPN w formie IP, zakresu lub CIDR
- kody dostępu są przechowywane w systemowym Secret Service, a certyfikaty drukarek przypinane po pierwszym zaufanym połączeniu (TOFU)
- dodano import konfiguracji Bambu Studio z natywnych i Flatpakowych lokalizacji GNU/Linux
- dodano język polski i angielski, jasny i ciemny wygląd, powiadomienia, autostart po zalogowaniu oraz tryb zwarty dla większej liczby drukarek
- dodano paczkę instalacyjną `.deb`, testy rdzenia i lokalnie przygotowany workflow budowania dla Ubuntu
- dodano tryb **Gantry Workshop** dla Raspberry Pi: pełnoekranowy kiosk, układ monitoringu większej floty, alerty, bezpieczny panel WWW ze statusem drukarek oraz automatyczny start po zalogowaniu
- dodano lokalny panel konfiguracji HTTPS dostępny z telefonu lub komputera, chroniony sześciocyfrowym kodem parowania wyświetlanym na ekranie
- dodano masowy import drukarek z CSV (`kind,name,host,serial,access_code,port`), pobieranie i lokalne generowanie szablonu oraz import z Dokumentów lub pendrive'a
- ujednolicono numer wersji macOS, Windows i GNU/Linux oraz poprawiono wersję deklarowaną przez instalator Windows

## 0.4.0 — 2026-08-03

- dodano obsługę drukarek Prusa przez PrusaLink (macOS i Windows) — lokalnie po IP + klucz API, bez konta Prusy; odczyt stanu, postępu, czasu, temperatur i nazwy pliku
- dodano godziny ciszy — wyciszenie powiadomień w wybranym oknie dobowym (domyślnie 22:00–07:00), ustawiane w Ustawieniach i przełączane z menu PPM / zasobnika
- tryb kompaktowy z akordeonem: pełne kafle do 8 drukarek, powyżej zwarta lista (z przełącznikiem), klik w wiersz rozwija pełną kartę pod spodem; na Windows okno panelu powiększa się do rozwiniętej karty
- przenoszenie kolejności drukarek metodą przeciągnij-i-upuść na obu platformach
- dodano rozwijaną „Legendę kolorów" w PPM / zasobniku objaśniającą kolory statusu na kartach
- macOS wykrywa język systemu przy pierwszym uruchomieniu (parytet z Windows); ręczny wybór ma pierwszeństwo

### Poprawki

- okno dodawania drukarki nie nadpisuje już wpisanych danych, gdy w tle odświeża się inna drukarka podczas skanowania (macOS i Windows)
- Windows: menu „…" na karcie nie miga i nie zamyka się natychmiast (nakładka w oknie zamiast Popup)
- Windows: karty aktualizowane przyrostowo zamiast przebudowy całego panelu przy każdym odczycie (koniec zacięć)
- Windows: menu karty w bieżącym języku po przełączeniu PL/EN; log błędów do %AppData%\BambuBar\error.log
- macOS: stan rozwinięcia czyszczony po usunięciu drukarki

## 0.3.0 — 2026-08-02

- dodano obsługę systemu filamentów Creality CFS na drukarkach Klipper (macOS i Windows) — odczyt przez WebSocket drukarki (`ws://host:9999`), sloty CFS (materiał, kolor, % pozostałości, aktywna szpula) pokazywane jako AMS; drukarki Klipper bez CFS działają bez zmian
- opcje kamery i Bambu Studio pokazują się tylko dla drukarek Bambu; dla pozostałych dostępne jest podmenu „Otwórz slicer" z auto-wykrywaniem (Bambu Studio, OrcaSlicer, Creality Print, PrusaSlicer)
- w edycji drukarki można przypiąć jej postęp do paska menu (macOS) / zasobnika (Windows) jako osobny wskaźnik %
- dodano powiadomienie o dostępnej aktualizacji (macOS i Windows) — automatyczne sprawdzanie GitHub; kliknięcie instaluje (macOS) lub otwiera stronę wydania (Windows)

### Windows

- panel drukarek działa jak popover przy zasobniku (chowany po utracie fokusu), z zaokrąglonymi rogami, tłem acrylic i kafelkami w stylu macOS
- przebudowane, czytelne okno ustawień ze skonsolidowanymi opcjami: język, autostart, powiadomienia oraz „Sprawdź aktualizacje"
- karta drukarki ma menu „…" jak na macOS (Połącz ponownie, Kamera w Bambu Studio, Otwórz slicer, Kopiuj adres IP, Edytuj, Usuń)

## 0.2.0 — 2026-08-02

### Klipper (macOS i Windows)

- dodano obsługę drukarek Klipper (Moonraker) — dodawanie przez adres IP/host, opcjonalny port (domyślnie 7125) i klucz API, bez kodu dostępu i numeru seryjnego
- wieloszpulowe systemy MMU (Happy Hare) są pokazywane jako sloty AMS: materiał, kolor i aktywna szpula

### macOS

- przebudowane menu prawego przycisku na ikonie paska — większe, czytelniejsze wiersze z szybkimi akcjami: „Szukaj drukarek…", „Połącz ponownie (wszystkie)", „Sprawdź aktualizacje…" oraz przełącznik języka PL/EN, bez wchodzenia w Ustawienia

### Bezpieczeństwo (macOS)

- kody dostępu do drukarek są teraz szyfrowane w pęku kluczy (Keychain) zamiast zwykłego tekstu; przechowywane w jednej pozycji, więc macOS nie pyta o dostęp osobno dla każdej drukarki. Istniejące kody są przenoszone automatycznie przy pierwszym uruchomieniu
- auto-aktualizacja weryfikuje podpis pobranej wersji przed instalacją (musi być podpisana tą samą tożsamością co bieżąca aplikacja) — obcy lub zmodyfikowany pakiet jest odrzucany

## 0.1.19 — 2026-08-01

- powiadomienia macOS są teraz natywne: mają własną ikonę BambuBar, a kliknięcie otwiera pulpit aplikacji zamiast Edytora skryptów
- w ustawieniach macOS można wybrać, które powiadomienia mają się pojawiać (druk zakończony, błąd drukarki, druk wstrzymany, niski poziom filamentu, wysoka wilgotność AMS)
- okno pulpitu dopasowuje wysokość do liczby drukarek — przy 1–3 drukarkach nie ma już pustej przestrzeni, a przy dużej flocie pojawia się przewijanie
- dodano przycisk „Sprawdź aktualizacje" w ustawieniach macOS, który pobiera i instaluje nowszą wersję oraz uruchamia aplikację ponownie
- AMS i kolory pozostają widoczne przez cały czas druku (wcześniej znikały przy cząstkowych aktualizacjach statusu, m.in. na A1 mini z AMS lite)
- temperatura komory jest pokazywana wyłącznie dla drukarek z rzeczywistym czujnikiem (X1, X2, P2), a ukrywana tam, gdzie go nie ma (A1, A1 mini, P1) — wykrywane bezpośrednio z telemetrii drukarki

### Windows

- dodano okno ustawień z wyborem, które powiadomienia mają się pojawiać (druk zakończony, błąd, wstrzymany, niski poziom filamentu, wysoka wilgotność AMS) oraz przełącznikami języka i autostartu
- AMS pozostaje widoczny przez cały czas druku — ta sama poprawka cząstkowych aktualizacji statusu co w macOS
- temperatura komory jest odczytywana z tego samego pola telemetrii co w macOS, więc rozpoznanie obecności czujnika działa spójnie na obu platformach
- import z Bambu Studio obsługuje formaty JSON (z końcową sumą kontrolną) i starszy INI, także gdy Bambu Studio pozostaje otwarte, oraz wyszukuje konfigurację w kilku lokalizacjach

## 0.1.18 — 2026-07-30

- dodano pierwszą wersję beta BambuBar dla 64-bitowego Windows 10 i 11, działającą jako aplikacja w zasobniku systemowym
- wersja Windows jest publikowana jako samodzielny `BambuBar.exe` w archiwum ZIP i nie wymaga osobnej instalacji środowiska .NET
- dodano instalator `BambuBar-Setup-Windows-x64.exe`, który nie wymaga uprawnień administratora, uruchamia aplikację po instalacji, dodaje skrót w menu Start oraz automatyczny start przy logowaniu do Windows
- przeniesiono na Windows najważniejsze funkcje wersji macOS: wykrywanie drukarek, lokalne połączenie MQTT przez TLS, statusy druku, AMS/HMS, powiadomienia oraz import z Bambu Studio
- kody dostępu w wersji Windows są szyfrowane dla bieżącego użytkownika za pomocą Windows DPAPI
- poprawiono import konfiguracji Bambu Studio na Windows — obsługiwane są formaty JSON z końcową sumą kontrolną i starszy INI, również gdy Bambu Studio pozostaje otwarte
- wersja Windows pozostaje betą i nie jest jeszcze podpisana certyfikatem; wymaga dalszych testów interfejsu, zasobnika, zapory oraz wykrywania drukarek na fizycznych komputerach z Windows
- dodano usuwanie drukarki z menu „⋯" na karcie (z potwierdzeniem)
- skanowanie sieci kończy się w kilka sekund zamiast ~30 s (nie poddaje się już po 8 s)
- import z Bambu Studio działa na czystej instalacji — czyta adres IP z konfiguracji i tworzy drukarki bez potrzeby skanu, a przycisk importu nie czeka już na skanowanie
- wykrywanie SSDP działa również przy uruchomionym Bambu Studio (rezerwowy port, gdy 2021 jest zajęty)
- okno dodawania i edycji drukarki jest w pełni tłumaczone przy każdym otwarciu
- dodano testy jednostkowe (kodek MQTT, parser SSDP, parser statusu) oraz skrypt `scripts/run-tests.sh`
- ustabilizowano podpis aplikacji, dzięki czemu zgoda macOS na dostęp do sieci lokalnej przetrwa kolejne przebudowy
- README dostępne w wersji polskiej i angielskiej

## 0.1.14 — 2026-07-30

- opublikowano kompletny kod źródłowy projektu na licencji MIT
- import z Bambu Studio odbywa się wyłącznie po świadomym kliknięciu przycisku przez użytkownika
- zaimportowane kody dostępu są zapisywane w pęku kluczy macOS i nie wymagają ponownego odczytu konfiguracji Bambu Studio przy starcie
- dodano dokumentację bezpieczeństwa, zasady współtworzenia i automatyczny build dla macOS 26
- dodano informacje o autorze oraz odnośniki do profili GitHub, X i strony wsparcia
- wyeliminowano wielokrotne pytania pęku kluczy podczas automatycznego ponownego łączenia
- ujednolicono lokalną tożsamość podpisu dla aplikacji i uruchamiania przez plik `.command`

## 0.1.13 — 2026-07-29

- wydano pierwszą kompletną wersję natywnego monitora drukarek Bambu Lab dla paska menu macOS
- dodano wykrywanie drukarek w sieci lokalnej, ręczne dodawanie urządzeń oraz automatyczne ponowne łączenie
- dodano status wydruku, procent postępu, pozostały czas, warstwy oraz temperatury dyszy, stołu i komory
- dodano szczegółowe etapy pracy, m.in. bazowanie, nagrzewanie, poziomowanie, ładowanie i zmianę filamentu
- dodano komunikaty HMS, powiadomienia o błędach i zakończeniu druku oraz subtelne wyróżnienie kafelków błędu i zakończonego zadania
- dodano obsługę AMS na cztery szpule i pojedynczego AMS wraz z kolorami, aktywnym slotem, wilgotnością, temperaturą i ostrzeżeniami o niskim poziomie filamentu
- dodano obsługę polskich znaków w nazwach plików oraz czytelne skrócone informacje AMS
- dodano przeciąganie kafelków, zapisywanie kolejności drukarek i znacznik miejsca upuszczenia
- widok rozwinięty korzysta z dwóch kolumn, a od dziewięciu drukarek automatycznie przechodzi na trzy kolumny
- od czterech drukarek dostępny jest tryb zwarty, mieszczący do piętnastu statusów w wąskim panelu
- wybrany układ, język polski lub angielski oraz jasny lub ciemny wygląd są zapamiętywane
- ustawienia otwierają się w osobnym oknie z menu kontekstowego ikony `BL` i zawierają opcję uruchamiania przy logowaniu oraz odnośnik do wsparcia
- ograniczono odświeżanie ETA do pięciu minut, ukryto licznik świeżych danych i dodano ostrzeżenie o nieaktualnej telemetrii
- kody dostępu są bezpiecznie przechowywane w pęku kluczy macOS, a komunikacja z drukarkami odbywa się lokalnie bez konta Bambu Cloud
