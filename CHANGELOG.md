# Historia zmian Gantry

Wszystkie istotne zmiany w aplikacji Gantry (dawniej BambuBar / PrismBar) są opisane w tym pliku.

## 0.6.0 — 2026-08-09

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
