# Gantry Design System — kontrakt layoutu

Ten dokument zbiera aktualny kierunek interfejsu Gantry oraz opisuje, jak przejść od demonstracyjnych plików HTML do jednego, przewidywalnego layoutu na macOS, Windows i Linux.

## Najważniejsza zasada

Layout zależy od dostępnej szerokości i możliwości drukarki, a nie od systemu operacyjnego ani liczby drukarek.

Każda platforma może używać natywnych komponentów, ale musi interpretować ten sam kontrakt:

- te same breakpointy;
- te same spany kolumn;
- te same reguły rozszerzania kafli;
- tę samą kolejność sekcji;
- te same warianty gęstości;
- te same tokeny wizualne.

## Pliki

### Prototypy HTML

#### [gantry-single-tile.html](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-single-tile.html>)

Referencyjny dashboard z pięcioma drukarkami.

Pokazuje:

- układ dwóch zwykłych kafli obok siebie;
- szeroki kafel X2D;
- warianty AMS, AMS HT i EXT;
- podwójną dyszę P/L;
- temperatury w stylu `thermalZones`;
- segmentowy pasek postępu;
- eksperymentalną narożną poświatę statusu na kaflu X1;
- trzy gęstości: małą, średnią i dużą;
- regułę szerokiego kafla dla drukarek wymagających większej przestrzeni.

#### [gantry-details-demo.html](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-details-demo.html>)

Referencyjny widok szczegółów drukarki przy szerokości 640 px.

Pokazuje:

- pełnoszeroki status wydruku;
- pełnoszeroką kamerę;
- układ 2×2 dla pozostałych sekcji;
- dynamiczne pakowanie masonry bez pustych przestrzeni;
- Filamenty / AMS bezpośrednio pod kamerą;
- wykres temperatur i te same strefy temperatur co na dashboardzie;
- wentylatory, prędkość, sterowanie oraz automatyzacje;
- przycisk `Dostosuj` na dole widoku.

Szczegółowy kontrakt tego ekranu i mapowanie na kod znajduje się w [GANTRY-PRINTER-DETAILS.md](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/GANTRY-PRINTER-DETAILS.md>).

#### [gantry-bento-demo.html](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-bento-demo.html>)

Wcześniejszy prototyp całej siatki. Może służyć jako materiał porównawczy, ale nie jest już wzorcem implementacyjnym.

#### [gantry-styleboard.html](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-styleboard.html>)

Wcześniejszy styleboard eksperymentalny. Nie należy traktować go jako źródła wartości produkcyjnych.

### Kontrakt i konfiguracja

#### [gantry-design-tokens.json](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-design-tokens.json>)

Tokeny wizualne:

- kolory;
- typografia;
- odstępy;
- promienie;
- przezroczystości;
- podstawowe wartości powierzchni.

Docelowo ten plik powinien zawierać wyłącznie wygląd. Reguły rozmieszczenia elementów znajdują się w osobnym pliku layoutu.

> Status: plik jest wcześniejszym draftem i przed wdrożeniem produkcyjnym należy zsynchronizować jego wartości kolorów, typografii i promieni z finalnymi prototypami HTML.

#### [gantry-layout.defaults.json](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.defaults.json>)

Wersjonowany, domyślny kontrakt layoutu dla wszystkich platform.

Zawiera:

- breakpointy;
- warianty gęstości;
- szerokości referencyjne;
- spany kafli;
- kolejność sekcji;
- reguły szerokiego kafla;
- reguły układu AMS;
- reguły wyrównania wysokości oraz narożnej poświaty statusu;
- konfigurację dashboardu i szczegółów;
- informację, które sekcje można przenosić;
- strategię zapisu ustawień użytkownika.

#### [gantry-layout.user.example.json](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.user.example.json>)

Przykład ustawień użytkownika. Zapisuje wyłącznie różnice względem domyślnego kontraktu.

Nie powiela całego layoutu, dzięki czemu nowa wersja aplikacji może dodać nową sekcję bez kasowania wcześniejszych preferencji użytkownika.

#### [gantry-layout.schema.json](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.schema.json>)

JSON Schema dla domyślnego layoutu. Pozwala automatycznie wykrywać:

- brakujące pola;
- niepoprawne spany;
- nieobsługiwane wartości;
- błędny numer wersji kontraktu.

#### [gantry-layout.user.schema.json](</Users/kamilgrzegorczyk/Documents/bambu lab monitor/design/gantry-layout.user.schema.json>)

JSON Schema dla ustawień użytkownika.

## Architektura źródła prawdy

```text
gantry-design-tokens.json
          │
          ├── kolory
          ├── typografia
          ├── spacing
          └── radius

gantry-layout.defaults.json
          │
          ├── breakpointy
          ├── spany
          ├── kolejność
          ├── reguły możliwości drukarki
          └── domyślna widoczność

gantry-layout.user.json / UserDefaults
          │
          ├── wybrana gęstość
          ├── zmieniona kolejność
          ├── ukryte sekcje
          └── własne spany

          ▼

EffectiveLayout = DefaultLayout + UserOverrides
          │
          ├── Swift / SwiftUI
          ├── C# / WPF
          └── Python / GTK
```

## Dashboard

### Breakpointy

| Tryb | Szerokość | Kolumny | Zwykły kafel drukarki |
|---|---:|---:|---:|
| Expanded | `≥ 720 px` | 6 | `2/6` — trzy drukarki w rzędzie |
| Wide | `480–719 px` | 6 | `3/6` — dwie drukarki w rzędzie |
| Medium | `320–479 px` | 4 | `4/4` — jedna drukarka w rzędzie |
| Narrow | `< 320 px` | 2 | `2/2` — jedna drukarka w rzędzie |

System operacyjny nie uczestniczy w wyborze breakpointu.

### Zmiana rozmiaru okna

Główne okno jest skalowalne natywnie za narożnik. Zmiana szerokości powoduje reflow, a nie powiększenie lub pomniejszenie całego interfejsu:

```text
≥ 720 px      → 3 kolumny → układ 3×2
480–719 px    → 2 kolumny → układ 2×3
< 480 px      → 1 kolumna → układ 1×N
```

Liczba kolumn jest obliczana z szerokości kontenera aplikacji. Nie należy używać szerokości całego ekranu ani nazwy systemu operacyjnego.

Okno udostępnia trzy natywne kierunki zmiany rozmiaru:

- prawa krawędź zmienia szerokość i liczbę kolumn;
- dolna krawędź zmienia wysokość obszaru roboczego;
- narożnik zmienia oba wymiary jednocześnie.

Gdy dostępna wysokość jest mniejsza niż wysokość siatki, dashboard przewija zawartość pionowo. Nie skaluje kafli ani typografii.

W obrębie jednego rzędu wszystkie kafle mają wspólną dolną krawędź. Wysokość rzędu wyznacza najwyższy kafel (`rowSizing: maxContent`), a pozostałe rozciągają powierzchnię karty (`cardAlignment: stretch`). Nadmiar wysokości przejmuje wyłącznie górne bento zadania (`printerCard.rowHeightAbsorber: jobBento`). Bento temperatury i materiałów zachowują swoją wysokość oraz wspólne położenie w rzędzie — między temperaturami i AMS/EXT nie wolno wstawiać elastycznej luki.

Przejście może być animowane przez około `180 ms`, ale geometria końcowa zawsze wynika z kontraktu. Szerokość okna jest zapamiętywana lokalnie dla danej platformy i nie jest synchronizowana jako część wspólnego layoutu użytkownika.

### Zakotwiczenie i kierunek rozwijania

Kierunek rozwijania okna wynika z położenia ikony tray/menu bar i wolnego obszaru monitora, a nie z nazwy systemu operacyjnego. Krawędź przylegająca do ikony pozostaje nieruchoma, więc dashboard otwiera się i zmienia rozmiar w stronę, w której jest więcej miejsca.

Typowe przypadki:

| Położenie ikony | Rozwijanie poziome | Rozwijanie pionowe |
|---|---|---|
| macOS, prawy górny róg | w lewo | w dół |
| Windows, prawy dolny róg | w lewo | w górę |
| Linux, dowolna krawędź panelu | automatycznie | automatycznie |

Algorytm:

1. Pobiera prostokąt zakotwiczenia ikony.
2. Wybiera monitor zawierający środek zakotwiczenia.
3. Używa systemowego `workArea`, czyli obszaru pomniejszonego o taskbar, Dock i panele.
4. Porównuje wolne miejsce po lewej/prawej oraz nad/pod ikoną.
5. Rozwija okno w kierunku większej przestrzeni, zachowując `8 px` marginesu od `workArea`.
6. Utrzymuje wybrany kierunek, dopóki przewaga przeciwnej strony nie przekroczy `32 px`; zapobiega to przeskakiwaniu okna przy drobnych zmianach geometrii.
7. Przelicza pozycję po przesunięciu ikony, zmianie monitora albo zmianie `workArea`.

Dla paneli linuksowych, które nie udostępniają geometrii ikony, obowiązuje kolejność awaryjna: ostatnie znane zakotwiczenie, znana krawędź panelu, a na końcu pozycja wskaźnika w chwili otwierania. Okno zawsze jest ograniczane do `workArea` monitora zakotwiczenia.

Kontrakt znajduje się w `dashboard.placement`. Nie jest to preferencja użytkownika i nie zapisujemy go w pliku nadpisań:

```json
{
  "mode": "anchorAware",
  "anchor": "trayIcon",
  "monitorSelection": "anchorCenter",
  "workArea": "systemWorkArea",
  "horizontalGrowth": "auto",
  "verticalGrowth": "auto",
  "autoStrategy": "mostAvailableSpace",
  "keepAnchorFixed": true,
  "screenMargin": 8,
  "directionHysteresis": 32
}
```

### Sterowanie układem

Na produkcyjnym dashboardzie nie pokazujemy przycisków `1 kol.`, `2×3`, `3×2` ani pływającego uchwytu wewnątrz treści. Użytkownik korzysta ze standardowych krawędzi i narożnika okna systemowego, a układ reaguje automatycznie.

W ekranie `Dostosuj` może pojawić się opcjonalne ustawienie:

```text
Liczba kolumn: Automatyczna / maks. 1 / maks. 2 / maks. 3
```

Domyślna wartość to `Automatyczna`. Ustawienie jest limitem, a nie wymuszeniem: przykładowo przy wybranym `maks. 3` wąskie okno nadal przejdzie do jednej kolumny. W pliku użytkownika zapisujemy je jako `dashboard.columnLimit` z wartością `"auto"`, `1`, `2` albo `3`.

Przyciski wymuszające konkretne warianty mogą istnieć w narzędziach developerskich lub testach wizualnych, ale nie są częścią produkcyjnego interfejsu.

Referencyjny plik `gantry-single-tile.html` nie zawiera selektora liczby kolumn. Ma natomiast subtelne linie testowe na prawej i dolnej krawędzi oraz wspólny narożnik, ponieważ dokument HTML nie jest natywnym oknem aplikacji. Linie symulują zmianę rozmiaru okna; podwójne kliknięcie przywraca rozmiar automatyczny. Nie są elementem właściwego interfejsu Gantry.

### Dociąganie do siatki

Po zakończeniu zmiany rozmiaru geometria dociąga się do najbliższej pełnej granicy bento:

- szerokość — do pełnych `1`, `2` albo `3` kolumn drukarek;
- wysokość — do dolnej krawędzi najbliższego kompletnego rzędu;
- narożnik — jednocześnie do pełnej kolumny i pełnego rzędu.

Ramka nie może kończyć się w połowie kafla ani wychodzić poniżej ostatniego rzędu o więcej niż standardowy padding zewnętrzny. Jeśli użytkownik wybierze wysokość obejmującą mniej rzędów niż cała siatka, pozostałe kompletne rzędy są dostępne przez pionowe przewijanie.

### Gęstość kafli

| Wariant | Dashboard | Zwykły kafel |
|---|---:|---:|
| Małe | 480 px | 222 px |
| Średnie | 512 px | 238 px |
| Duże | 563 px | 264 px |

Gęstość jest preferencją użytkownika. Breakpoint nadal wynika z rzeczywistej szerokości kontenera.

### Zwykły i szeroki kafel

Zwykła drukarka zajmuje `3/6` kolumn w trybie Wide i `2/6` w trybie Expanded.

Nagłówek drukarki nie jest osobnym blokiem nad zadaniem. Należy do wspólnego bento `Printer / Job`:

```text
🖨 MINI  MQTT                              wykres  uchwyt  •••
● Drukowanie · ADAPTER-PVC110-SPIRO120.3mf       19 / 226
28%   ETA 17:16 · 2h 2m
■■■■■■■■□□□□□□□□
```

Pierwszy wiersz przechowuje tożsamość drukarki i akcje, drugi status, nazwę pliku oraz warstwy. Dzięki wspólnemu paddingowi i usunięciu odstępu między nagłówkiem a zadaniem kafel jest niższy, ale hierarchia informacji pozostaje czytelna. Długa nazwa pliku jest skracana i może uruchomić wolne przewijanie po najechaniu.

Kafel specjalny przechodzi na `6/6` w trybie Wide albo `4/6` w trybie Expanded, gdy:

- drukarka ma dwie dysze;
- drukarka ma co najmniej dwa moduły AMS;
- użytkownik wymusi szeroki wariant w ustawieniach.

Ostatni nieparzysty kafel, który zaczyna pusty rząd, automatycznie zajmuje pełną szerokość — tak jak w referencyjnym układzie macOS.

### Narożne światło statusu

Status może nadawać kaflowi delikatne światło wychodzące z górnego początkowego narożnika (`topLeading`). Nie barwimy całej karty: podstawowa powierzchnia pozostaje neutralna, a gradient wygasa przed przeciwległą częścią kafla.

Aktualny wariant referencyjny dla `printing`:

- token koloru: `status.printing` = `#FF6857`;
- obszar gradientu: `125% × 92%` powierzchni karty;
- początek poza kartą: `x: -10%`, `y: -12%`;
- krycie kolejnych punktów: `24% → 10.5% → 3.5% → 0%`;
- pełne wygaśnięcie przy `82%` zasięgu;
- obramowanie w kolorze statusu z kryciem `20%`.

Ten sam token może kolorować wyłącznie elementy funkcjonalne statusu:

- kropkę i nazwę statusu;
- wartość procentową;
- aktywne segmenty postępu;
- delikatną krawędź karty.

Temperatury, powierzchnie AMS/EXT i kolory filamentów nie przyjmują koloru statusu. Kolor jest sygnałem pomocniczym — tekst statusu pozostaje wymagany, więc znaczenie nie zależy wyłącznie od barwy.

W prototypie efekt jest celowo włączony tylko na X1, aby można było porównać go z neutralnymi kaflami. Kontrakt opisuje zachowanie docelowe przez `dashboard.printerCard.statusAppearance`; po zatwierdzeniu renderer stosuje je do każdej karty według wartości statusu. Nie jest to ustawienie użytkownika.

Pozostałe statusy korzystają obecnie z `status.default`. Osobne tokeny dla pauzy, zakończenia, ostrzeżenia i błędu należy dodać dopiero po zatwierdzeniu ich kolorów.

### AMS i EXT

- Jeden lub dwa moduły materiałowe pozostają w jednej linii.
- Trzy lub więcej modułów przechodzi do siatki 2×2 i zwiększa kafel w dół.
- Pojedynczy AMS HT ma taką samą wizualną szerokość wkładu jak EXT.
- EXT pokazuje temperaturę i wilgotność, jeśli urządzenie udostępnia te dane.
- Pusty slot zachowuje miejsce i otrzymuje kreskowane wypełnienie.
- Kolor próbki zawsze pochodzi z danych filamentu.
- Nazwa slotu i typ materiału muszą mieć rozdzieloną hierarchię wizualną.

### Temperatury

Kolejność jest stała:

```text
Dysza → Stół → Komora
```

Wartość bieżąca i zadana występują w jednej linii:

```text
245° / 245°
```

Dla dwóch dysz pierwsza strefa zawiera dwa odczyty oznaczone `P` i `L`.

## Widok szczegółów

### Bazowa geometria

- rozmiar widoku: `480 × 700 px`;
- jedna przewijana kolumna;
- gap między kartami: `8 px`;
- każda karta zajmuje pełną szerokość.

### Domyślna kolejność

```text
1. Status
2. Kamera
3. Filamenty / AMS
4. Temperatury
5. Wentylatory i prędkość
6. Sterowanie
7. Dostosuj
```

Status pozostaje widoczny. Kamera, Filamenty, Temperatury, Wentylatory i Sterowanie mogą być ukrywane, a wszystkie dostępne karty mogą być przestawiane przez użytkownika.

### Dynamiczna wysokość

- wysokość każdej karty wynika z jej treści;
- nie zapisujemy wysokości w ustawieniach;
- kolejna karta podjeżdża bezpośrednio pod poprzednią;
- nadmiar treści przewija się wewnątrz panelu.

### Przycisk `Dostosuj`

Przycisk na dole powinien przełączać widok w tryb edycji. W tym trybie użytkownik może:

- zmieniać kolejność ruchomych sekcji;
- przełączać szerokość `3/6` lub `6/6`;
- ukrywać opcjonalne sekcje;
- przywrócić układ domyślny.

## Zapisywanie ustawień

Baza danych nie jest potrzebna. Wystarczy lokalny zapis preferencji.

### macOS

`UserDefaults`, na przykład pod kluczem:

```text
gantry.layout.overrides.v1
```

### Windows

Obecny `AppSettings.DetailCardOrder` zapisuje kolejność jako CSV. Należy go zastąpić lub rozszerzyć o dokument JSON zgodny z `gantry-layout.user.schema.json`.

### Linux

Plik konfiguracyjny użytkownika, na przykład:

```text
~/.config/gantry/layout.json
```

### Co zapisujemy

```json
{
  "schemaVersion": 1,
  "basedOnLayoutVersion": "1.2.0",
  "density": "medium",
  "detail": {
    "order": ["status", "recent", "maintenance", "stats", "camera", "materials", "temperature", "fans", "controls"],
    "hidden": [],
    "spanOverrides": {}
  }
}
```

### Czego nie zapisujemy

- obliczonych wysokości kart;
- pozycji w pikselach;
- wartości temperatur;
- postępu wydruku;
- liczby aktualnie podłączonych modułów;
- decyzji zależnych od systemu operacyjnego.

## Scalanie ustawień

Podczas uruchomienia:

1. Aplikacja ładuje `gantry-layout.defaults.json`.
2. Ładuje ustawienia użytkownika, jeśli istnieją.
3. Sprawdza `schemaVersion` i `basedOnLayoutVersion`.
4. Nakłada wyłącznie zapisane odstępstwa.
5. Nieznane lub usunięte identyfikatory ignoruje.
6. Nowe sekcje z nowszego layoutu dopisuje w ich domyślnej pozycji.
7. Na końcu oblicza breakpoint, spany oraz wysokości wynikające z treści.

Reset layoutu usuwa wyłącznie ustawienia użytkownika. Nie może usuwać drukarek, połączeń ani danych aplikacji.

## Wdrożenie na platformach

### Wspólny model

Każda implementacja potrzebuje odpowiedników:

```text
LayoutContract
DensityPreset
Breakpoint
DashboardRules
DetailItem
UserLayoutOverrides
EffectiveLayout
```

### Zalecany przepływ

```text
JSON defaults
   ↓ walidacja
Typed model platformy
   ↓ merge
User overrides
   ↓
Effective layout
   ↓
Natywne komponenty UI
```

Nie trzeba współdzielić kodu renderującego Swift, C# i Python. Współdzielony jest kontrakt oraz dane wejściowe dla layoutu.

## Stan wdrożenia 2026-08-31

### Dashboard

- macOS: wybierana siatka jednej lub dwóch kolumn, pełny span dla X2D/dual-nozzle/multi-AMS oraz zwykłej ostatniej karty rozpoczynającej pusty rząd, segmentowany postęp oraz neutralne płaskie sekcje;
- Windows: `WrapPanel` został zastąpiony deterministycznym `Grid`, z tymi samymi regułami spanów i akcentów co macOS;
- Linux: dashboard został napisany od nowa z aktualnych klas Swift; używa szerokości 380/563 px, reguł 1/2 kolumny, spanu zależnego od wyposażenia drukarki, listy kompaktowej z akordeonem i tych samych sekcji karty.

### Szczegóły

- macOS i Windows: status i kamera są pełnoszerokie, a pozostałe sekcje układają się w dwóch niezależnych kolumnach;
- kolejność domyślna zaczyna się od `status → recent → maintenance → stats → camera → materials → temperature`;
- Linux: `DetailPanel` działa wewnątrz głównego panelu, używa tej samej pojedynczej kolumny 480 px, kolejności/przestawiania/ukrywania kart oraz osadzonego strumienia RTSPS/MJPEG.

Implementacje nadal kodują część wartości natywnie. Następnym krokiem technicznym jest loader `gantry-layout.defaults.json` i `gantry-design-tokens.json`, aby usunąć duplikację wartości między Swift, C# i Pythonem.

## Kolejność dalszych prac

1. Zatwierdzić oba prototypy HTML jako wzorce referencyjne.
2. Zsynchronizować `gantry-design-tokens.json` z finalnymi wartościami prototypów.
3. Wprowadzić modele kontraktu w Swift, C# i Pythonie.
4. Zaimplementować loader domyślnego layoutu.
5. Zaimplementować scalanie ustawień użytkownika.
6. Dokończyć kontenerowe breakpointy podczas natywnej zmiany rozmiaru okna.
7. Utrzymywać widok szczegółów klienta GTK przy kolejnych zmianach źródłowych w Swift.
8. Podłączyć tryb `Dostosuj`.
9. Zastąpić platformowe zapisy kolejności jednym dokumentem override JSON.
10. Dodać testy snapshotów dla szerokości 440, 512, 640 i 840 px.

## Kryteria zgodności

Implementację platformy uznajemy za zgodną, gdy:

- przy tej samej szerokości elementy mają te same spany;
- kafel nie zmienia szerokości tylko dlatego, że jest ostatni;
- X2D i konfiguracje wielu AMS przechodzą na szeroki wariant według tych samych reguł;
- kolejność temperatur i sekcji szczegółów jest identyczna;
- gęstości Małe, Średnie i Duże mają te same wartości;
- ustawienia użytkownika przechowują wyłącznie odstępstwa;
- reset przywraca kontrakt domyślny;
- żadna platforma nie posiada własnych, ukrytych reguł layoutu.
