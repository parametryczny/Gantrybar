# Gantry 0.14.0

Wydanie rozszerza Gantry z monitora floty o nadzór nad trwającymi wydrukami, automatyczne prowadzenie
magazynu filamentu, sterowanie zasilaniem, wycenę produkcji oraz zdalny podgląd floty na własnym
serwerze.

Windows i GNU/Linux otrzymują w tym wydaniu pełny zestaw funkcji dostępnych dotąd wyłącznie na macOS.

Gantry nadal działa wyłącznie lokalnie. Nie wymaga konta, chmury ani serwera pośredniczącego.

> **Bambu Lab.** Sterowanie z Gantry (temperatury, wentylatory, prędkość, pomijanie obiektów, pauza
> i zatrzymanie) wymaga włączonego na drukarce **trybu Tylko LAN** oraz **Trybu deweloperskiego**.
> Drukarka połączona z chmurą Bambu odrzuca polecenia spoza Bambu Connect. Podgląd stanu działa zawsze.

---

## Najważniejsze zmiany

- **Gantry Vision**: wbudowany silnik rozpoznawania błędów wydruku, bez pobierania dodatkowych plików.
- **Nadzór nad wydrukiem z kamery**: ostrzeżenie po kilku zgodnych obserwacjach, przekazywane jako
  powiadomienie systemowe, wiadomość na Telegramie oraz komunikat na karcie drukarki.
- **Weryfikacja na własnych wydrukach**: test na żywo z wybranej kamery, test na wskazanym zdjęciu
  oraz ocena wszystkich nagranych wydruków przy bieżących ustawieniach.
- **Sterowanie zasilaniem**: gniazdka Tasmota, Shelly, Home Assistant lub własne adresy URL,
  z awaryjnym wyłączeniem wszystkich naraz.
- **Własna strona w internecie**: podgląd floty na serwerze użytkownika, bez otwierania portu na routerze.
- **Automatyczne parowanie rolek**: szpula Bambu z chipem RFID zostaje powiązana ze swoją rolką
  w Spoolbase, niezależnie od gniazda i drukarki.
- **Wycena wydruku**: forma działalności, VAT, prowizja platformy, praca i rezerwa na nieudane wydruki,
  z ceną zapewniającą założony zysk.
- **Statystyki produkcji**: wykorzystanie drukarek, wydruki tygodniowo, zużycie według materiału,
  najczęściej drukowane pliki.
- **Kolejka druku w oknie Farma** z automatycznym doborem slotów AMS i potwierdzeniem pustego stołu.
- **Wykrywanie przesunięcia warstw wycofane** ze względu na wysoki odsetek fałszywych alarmów.

---

## Gantry Vision: nadzór nad wydrukiem

Gantry analizuje obraz z kamery każdej drukującej maszyny i zgłasza wykrytą awarię. Nie zatrzymuje
drukarki samodzielnie: przedstawia obserwację i oczekuje decyzji użytkownika.

Silnik jest częścią aplikacji. Nie wymaga pobierania, wskazywania pliku ani konfiguracji. Zajmuje 3 MB
i działa wyłącznie lokalnie; klatki nie opuszczają komputera.

### Analiza serii klatek

Pojedyncza obserwacja obejmuje pięć klatek w odstępie około sekundy, łączonych medianą w jeden obraz.
Głowica przejeżdżająca przez kadr występuje na jednej lub dwóch klatkach z pięciu, więc mediana ją
usuwa, pozostawiając stół z wydrukiem. Ruch głowicy był dotąd główną przyczyną fałszywych alarmów.

Ostrzeżenie zapada po trzech zgodnych obserwacjach z rzędu.

### Skuteczność w początkowym okresie

Na starcie Gantry dysponuje ogólną charakterystyką awarii. Nie zna natomiast obrazu poprawnego druku
na konkretnej kamerze: oświetlenia, kąta widzenia obiektywu ani koloru stołu. Różnice między dwiema
kamerami bywają większe niż różnica między wydrukiem udanym a nieudanym. W pierwszych dniach możliwe
są zatem fałszywe alarmy oraz przeoczenia.

Skuteczność rośnie wraz z użytkowaniem:

| Działanie użytkownika | Efekt |
| --- | --- |
| odpowiedź „fałszywy alarm" | klatka trafia do zbioru jako wzorzec poprawnego druku |
| odpowiedź „to awaria" | Gantry zapamiętuje obraz awarii na tej konkretnej kamerze |
| ręczne oznaczenie w Szczegółach | to samo, w dowolnym momencie |
| brak działania przy poprawnym wydruku | Gantry samodzielnie odkłada klatki udanego druku jako wzorzec |

Ostatnia pozycja jest istotna: zbiór wzorców rośnie bez udziału użytkownika. Odpowiadanie na pytania
przyspiesza ten proces bardziej niż jakakolwiek zmiana ustawień.

### Weryfikacja skuteczności

| Miejsce | Funkcja |
| --- | --- |
| Szczegóły → **Testuj** | pobiera klatkę z danej kamery i zwraca ocenę natychmiast |
| Ustawienia → Zaawansowane → **Sprawdź na zdjęciu…** | ocena wskazanego zdjęcia wydruku |
| Ustawienia → Zaawansowane → **Oceń nagrane wydruki…** | odtworzenie wszystkich nagranych wydruków przy bieżących ustawieniach: fałszywe alarmy na 100 godzin druku, liczba wykrytych awarii, wyprzedzenie w minutach |

Suwak czułości jest wspólny dla wszystkich silników, lecz skala wyników nie. Wartość „90%" oznacza
u różnych modeli różną siłę dowodu, a ustawienie zbyt wysokie może wyciszyć wykrywanie bez
widocznego sygnału. Jeżeli suwak przekracza próg, przy którym silnik był mierzony, Ustawienia
informują o tym obok suwaka.

Szczegóły techniczne: [gantry-vision.md](gantry-vision.md).

### Wykrywanie przesunięcia warstw: wycofane

Mechanizm analizował przesunięcie całego kadru i na rzeczywistej flocie mylił się w większości
zgłoszeń: dziesięć fałszywych alarmów w ciągu pół godziny na pięciu poprawnie pracujących drukarkach.
Porównanie krawędzi całego kadru nie odróżnia przesunięcia obiektu od przejazdu głowicy przed
obiektywem. Wiarygodne wykrycie wymaga śledzenia samego obiektu, nie całej klatki. Do czasu wdrożenia
tej metody funkcja pozostaje wyłączona. Ręczne oznaczanie przesunięcia warstw działa bez zmian.

---

## Sterowanie zasilaniem

Do każdej drukarki można przypisać gniazdko Wi-Fi lub gniazdo listwy zasilającej: **Tasmota, Shelly
Gen1, Shelly Plus/Pro/Gen3, dowolną encję Home Assistant** (a za jej pośrednictwem Tapo, Kasa, Zigbee
i pozostałe) albo dwa własne adresy URL.

Konfiguracja znajduje się w menu `⋯` karty, w pozycji **Zasilanie → Ustaw gniazdko…**. Przyciski
testowe przełączają gniazdko rzeczywiście, dzięki czemu błędny adres lub numer gniazda ujawnia się
od razu. Hasła i tokeny trafiają do pęku kluczy, DPAPI lub Secret Service, nie do pliku ustawień.

- Z karty drukarki: **Włącz / Wyłącz gniazdko**. Wyłączenie w trakcie druku wymaga potwierdzenia.
- W automatyzacjach: akcje **Gniazdko wł./wył.**, na przykład przy stanie *Błąd*.
- Opcjonalne samoczynne wyłączenie po zadanej liczbie minut od zakończenia wydruku, pomijane, gdy
  w międzyczasie rozpoczął się kolejny.
- Na Telegramie: przyciski przy każdej drukarce.

**Awaryjne wyłączenie zasilania** wyłącza wszystkie gniazdka równolegle i raportuje te, których nie
udało się wyłączyć. Okno ma wyróżniającą się oprawę graficzną, aby nie dało się go pomylić z innym;
Enter wykonuje operację, Esc anuluje. Gniazdko zasilające również inne urządzenia można z tej operacji
wyłączyć.

---

## Własna strona w internecie

Podgląd floty na stronie utrzymywanej przez użytkownika: własny hosting, własny adres, bez konta
w zewnętrznej usłudze.

Połączenie inicjuje aplikacja, nie strona. Gantry co kilka sekund łączy się z serwerem, przekazuje
stan floty i odbiera zakolejkowane polecenia. Wynikają z tego trzy właściwości:

1. na routerze nie trzeba otwierać portu ani dysponować stałym adresem IP,
2. serwer nie poznaje adresu drukarki ani jej kodu dostępu,
3. wyłączony komputer oznacza brak nowych danych, a nie lukę w zabezpieczeniach; strona sygnalizuje,
   że dane są nieaktualne.

Każda przesyłka w obu kierunkach jest podpisana wspólnym kluczem (HMAC SHA-256). Przełącznik **Strona
może** przyjmuje trzy wartości: `Nic`, `Tylko pokazywać flotę`, `Pokazywać i sterować`. Ograniczenie
jest egzekwowane w aplikacji: w trybie podglądu każde polecenie zostaje odrzucone wraz z podaniem
przyczyny, niezależnie od stanu strony.

Wygląd strony odpowiada karcie floty znanej z macOS, Windows i GNU/Linuksa. Kolory i wymiary pochodzą
z tego samego kontraktu wyglądu co aplikacje, co wyklucza rozbieżności.

Pliki do wgrania znajdują się w paczce **`Gantry-0.14.0-web.zip`**. Instrukcja wdrożenia wraz
z rozwiązywaniem problemów: [strona-wlasny-serwer.md](strona-wlasny-serwer.md).

---

## Magazyn filamentu

Szpula Bambu z chipem RFID umieszczona w AMS zostaje automatycznie powiązana ze swoją rolką
w Spoolbase. Identyfikator tagu pełni funkcję tożsamości rolki, dzięki czemu ta sama rolka jest
rozpoznawana w dowolnym gnieździe dowolnej drukarki.

| Sytuacja | Zachowanie |
| --- | --- |
| tag znany | rolka wraca do gniazda bez pytania |
| tag nieznany, produkt obecny w magazynie | zostaje użyta rolka rozpieczętowana, a w razie jej braku najstarsza oczekująca; tag zapisuje się na rolce, która schodzi ze stanu |
| tag nieznany, produkt nieznany | Gantry proponuje dodanie rolki, pojedynczo, z wpisem wypełnionym danymi z tagu |
| gniazdo zajęte przez inną rolkę | poprzednia wraca do magazynu, właściwa zajmuje jej miejsce |

Rozstrzygająca jest niezgodność identyfikatorów, nie moment włożenia szpuli. Mechanizm działa również
wtedy, gdy wymiana nastąpiła przy zamkniętej aplikacji, uśpionym komputerze lub w trakcie wznawiania
połączenia.

Przypisanie wykonane ręcznie w gnieździe nieodczytującym tagu nie podlega zmianie. Funkcję można
wyłączyć w Ustawieniach → Ogólne.

### Źródło danych o poziomie filamentu

Gniazdo odczytujące tag przedstawia procent i gramy pochodzące z tagu, ponieważ jest to pomiar
drukarki, uwzględniający także filament zużyty poza Gantry. Stan rolki w magazynie podąża za odczytem
tagu wyłącznie w dół.

Dwa odczyty są odrzucane jako niewiarygodne: ujemna wartość `remain` oznacza brak pomiaru, a waga
pełnej szpuli poniżej 150 g jest błędem odczytu, nie wagą szpuli.

Nazwa koloru znajduje się w dymku wraz z gniazdem, materiałem, produktem, poziomem i gramaturą. Tag
przenosi wyłącznie wartość RGBA, nazwę ustala katalog Bambu: najpierw dokładny kod koloru, następnie
najbliższy w zdefiniowanym promieniu. Poza tym promieniem nazwa nie jest podawana.

Pełny opis mechaniki: [filament-logika.md](filament-logika.md). Przewodnik użytkownika:
[spoolbase.md](spoolbase.md).

### Cena rolki i kod EAN

Okno „Dane filamentu" zawiera pola **Cena rolki** oraz **Kod EAN** ze sprawdzeniem cyfry kontrolnej.
Cena produktu trafia do każdej nowej rolki, a koszt wydruku jest liczony na podstawie ceny rzeczywiście
użytej rolki, nie cennika ani danych ze slicera. W katalogu, obok pozycji „Skanuj kod…", dostępna jest
pozycja **Wpisz kod…** dla etykiet nieczytelnych dla skanera oraz komputerów bez kamery.

---

## Wycena produkcji

Nowa karta **Wycena** w Ustawieniach obejmuje formę działalności (nierejestrowana, firma zwolniona
z VAT, czynny podatnik VAT), podatek od zysku lub przychodu, VAT, narzut, prowizję platformy, pracę,
pakowanie oraz rezerwę na nieudane wydruki.

Cena jest wyliczana tak, aby po prowizji i podatku pozostał założony zysk; VAT doliczany jest na końcu.
Kalkulator na dole karty przyjmuje wagę i czas druku, z ceną domyślną albo ceną wybranego filamentu
ze Spoolbase.

W historii wydruków (Statystyki floty oraz Szczegóły) przy każdej pozycji podany jest koszt, a przy
zakończonej powodzeniem również sugerowana cena sprzedaży. Gwiazdka przy kwocie oznacza, że nie
uwzględnia ona filamentu, dla którego nie zapisano zużycia.

**Statystyki produkcji** obejmują wykorzystanie drukarek, liczbę wydruków tygodniowo za ostatnie
8 tygodni, zużycie filamentu według materiału, najczęściej drukowane pliki oraz podział wydruków
nieudanych.

---

## Farma i kolejka druku

Płytę z pociętego pliku 3MF można dodać do kolejki w wybranej liczbie kopii, dla dowolnej drukarki
Bambu Lab albo wyłącznie dla wskazanych. Przy każdej drukarce dostępny jest przełącznik **Stół pusty,
kolejka może startować**.

Po jego zaznaczeniu, gdy drukarka jest wolna, Gantry wybiera pierwszą pasującą pozycję: zgodny materiał
w AMS w zbliżonym kolorze (oraz wystarczającą ilość filamentu, jeżeli rolka podaje wagę) i zgodną
średnicę dyszy. Płyta jednofilamentowa może zostać wydrukowana ze szpuli zewnętrznej. Plik jest
przesyłany po FTPS, a druk rozpoczyna się automatycznie po jego dotarciu, z zachowaniem tych samych
kontroli co start ręczny.

Jedno zaznaczenie uprawnia do jednego startu. Po zdjęciu wydruku wymagane jest ponowne potwierdzenie
pustego stołu. Znacznik nie przetrwa restartu aplikacji, a nieudany transfer zwraca kopię do kolejki.

---

## Zrównanie funkcji na Windows i GNU/Linuksie

Obie edycje otrzymują funkcje dostępne dotąd wyłącznie na macOS:

- Farma: biblioteka pociętych plików 3MF, przesyłanie po FTPS, start po potwierdzeniu, kolejka
  z automatycznym doborem slotów AMS,
- koszt wydruku wraz z konfiguracją cen i eksportem CSV,
- pełny zestaw statystyk produkcji,
- parowanie rolek z AMS ze Spoolbase, cena rolki oraz kod EAN,
- sterowanie gniazdkami i awaryjne wyłączenie zasilania,
- zużycie maszyny, pastylka filamentu, biblioteka pociętych płyt, usuwanie wielu drukarek jednocześnie,
  kafel domykający niepełny rząd kart.

Historia wydruków dla pojedynczej drukarki obejmuje 1000 pozycji na wszystkich trzech systemach.

---

## Karta drukarki

- **Nagłówek jako jeden element**: ikona drukarki, nazwa, oznaczenie protokołu i wejście w szczegóły
  w jednej ramce z zielonym obrysem, reagującej na kliknięcie w całości.
- **Niepełny rząd domykany kaflem podsumowania floty** z danymi za dzień bieżący, 7 dni albo bieżący
  miesiąc. Wcześniej ostatnia karta była rozciągana na pełną szerokość, co nadawało jej nieuzasadnioną
  wagę wizualną.
- **Wyraźniejsze rozdzielenie kart**: jaśniejsze, niemal nieprzezroczyste tło, mocniejsza obwódka
  oraz 12 pt odstępu w pionie i w poziomie.
- **Konfigurowalna zawartość karty**: nazwa pliku, postęp, temperatury, filamenty, gramatura rolki,
  wskaźnik konserwacji oraz kafel floty, każde z osobnym przełącznikiem w Ustawieniach → Wygląd.
- **Ostrzeżenie o kończącym się filamencie także dla rolek spoza Bambu**: wystarczy rolka przypisana
  w Spoolbase, chip RFID nie jest wymagany.
- **Powiadomienie o wyczerpaniu filamentu** z nazwą slotu i materiałem, gdy drukarka Bambu wstrzymuje
  wydruk.

---

## Pasek krawędziowy

- **Podpis na obrazie kamery**: obraz prezentowany w całości, bez przycinania i rozciągania; nazwa,
  procent, czas i pierścień postępu umieszczone na jego dolnej krawędzi.
- **Format „75% · 1h 16m · 15:42"** zamiast zapisu „75% · 1:16", podatnego na mylną interpretację.
- **Przycisk ustawień pod paskiem**: w spoczynku widoczny jako fragment łuku, po najechaniu jako pełna
  ikona.
- **Dostosowanie do małych ekranów**: najpierw zmniejszenie obrazów, następnie zastąpienie ich opisem.

---

## Poprawki

- **Automatyczne wznawianie połączenia działa niezawodnie.** Zaplanowane ponowienie pełniło zarazem
  funkcję blokady, więc każde wyjście pomijające jej zwolnienie wstrzymywało ponawianie dla danej
  drukarki do końca sesji. Blokada została usunięta, a uzupełnia ją cykliczne sprawdzanie drukarek
  bez zaplanowanego powrotu.
- **Podgląd kamery i nadzór nad wydrukiem nie konkurują o kamerę.** Kamera drukarki obsługuje jednego
  klienta naraz; wykrywanie oraz strona www korzystają teraz z klatki pobranej przez działający podgląd.
- **Migawka z P1S i A1 mini.** Modele te nie udostępniają RTSP, a migawka korzystała wyłącznie z tego
  protokołu.
- **Zachowanie okien zgodne z systemem**: okno floty nie wymusza pozycji nad pozostałymi oknami,
  a okna dialogowe nie otwierają się pod nim.
- **Stabilna pozycja zmaksymalizowanego okna na GNU/Linuksie** po przebudowie kart.
- **Przełącznik zakresu w kaflu floty nie zmienia rozmiaru okna.** Różna liczba wierszy dla zakresów
  „dziś" i „7 dni" przenosiła się na wysokość rzędu kart, a następnie na wysokość okna.
- **Stabilny nagłówek karty.** Oznaczenie protokołu było zapisywane przy każdej ramce telemetrii mimo
  braku zmian, co przy ciasnym układzie powodowało migotanie.
- **Skaner kodów w Spoolbase nie blokuje interfejsu na GNU/Linuksie.**
- **Tryb warsztatowy na GNU/Linuksie uruchamia się poprawnie przy pierwszej drukarce.**
- **Komunikaty w wybranym języku**: błędy połączeń, kamer i aktualizacji oraz odpowiedzi bota Telegram
  respektują ustawienie języka interfejsu.

Pełna lista zmian: [CHANGELOG.md](../CHANGELOG.md).

---

## Wymagania po stronie drukarki

| Drukarka | Wymagania |
| --- | --- |
| **Bambu Lab** | podgląd: brak wymagań. Sterowanie, pomijanie obiektów i Farma: **tryb Tylko LAN oraz Tryb deweloperski** |
| **Klipper / Moonraker** | dostęp do Moonrakera w sieci lokalnej |
| **Prusa, Snapmaker, OctoPrint** | klucz API lub hasło z panelu drukarki |
| **Anycubic Kobra S1** | tryb LAN; dane sesji MQTT Gantry pobiera samodzielnie |
| **Elegoo Centauri Carbon** | CC1 bez kodu dostępu, CC2 w trybie LAN-only z kodem wyświetlanym przez drukarkę |

---

## Pliki do pobrania

| Plik | Przeznaczenie |
| --- | --- |
| `Gantry-0.14.0-macOS-Local.zip` | macOS, kody dostępu w pliku chronionym przez system |
| `Gantry-0.14.0-macOS-Keychain.zip` | macOS, kody dostępu w pęku kluczy |
| `Gantry-Setup-Windows-x64.exe` | Windows 10/11, instalator (zalecany) |
| `Gantry-Windows-x64.zip` | Windows 10/11, wersja przenośna |
| `Gantry-0.14.0-Linux-all.deb` | Debian, Ubuntu i pochodne |
| `Gantry-0.14.0-Linux-noarch.rpm` | Fedora, openSUSE i pochodne |
| `Gantry-0.14.0-Linux-x86_64.AppImage` | wersja przenośna, bez instalacji |
| `Gantry-0.14.0-web.zip` | strona na własny serwer, opcjonalna |

Żaden wariant dla Windows nie wymaga oddzielnej instalacji .NET. Aplikacja dla macOS jest podpisana
lokalnie, dlatego przy pierwszym uruchomieniu należy otworzyć ją przez menu kontekstowe, pozycją
**Otwórz**.
