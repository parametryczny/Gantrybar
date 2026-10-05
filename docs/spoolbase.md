# Gantry: Spoolbase i filament (jak dodać i oznaczyć rolkę)

Przewodnik po **magazynie filamentów (Spoolbase)** i **fizycznych rolkach**: jak działa aplikacja,
jak dodać filament do magazynu i jak przypisać (oznaczyć) konkretną rolkę do slotu AMS/EXT, żeby
Gantry pokazywał jej kolor, procent i gramy, a po wydruku sam odejmował zużycie.

Wszystko działa **lokalnie, bez chmury i bez logowania**, tak samo na **macOS, Windows i Linux**.
Różni się tylko sposób otwierania okien (opisany niżej).

Sama mechanika — co Gantry robi w każdym możliwym układzie tagu, rolki i gniazda — jest rozpisana w
[filament-logika.md](filament-logika.md).

---

## 1. Jak działa aplikacja (w skrócie)

Gantry siedzi w pasku/zasobniku systemowym i pokazuje **flotę drukarek** jako karty:

- **karta drukarki** ma nazwę, stan (drukuje / pauza / zakończono / błąd / offline), nazwę pliku,
  postęp, warstwy, ETA, temperatury (dysza / stół / komora) oraz **sloty filamentu** (AMS / AMS HT /
  CFS / MMU / EXT),
- **Szczegóły** (ikona wykresu na karcie albo menu `⋯`) otwierają widok z wykresem temperatur,
  wentylatorami, prędkością, średnicą dyszy, modułami filamentu i postępem,
- dane drukarek pobierane są po sieci lokalnej (Bambu przez MQTT, Klipper/Moonraker i Prusa/Snapmaker
  przez HTTP). Kody dostępu trzymane są w bezpiecznym magazynie systemu i **nigdy nie są wysyłane** na
  zewnątrz.

**Spoolbase** to wbudowany magazyn filamentów. Ma dwie warstwy:

| Warstwa | Co to jest | Przykład |
| --- | --- | --- |
| **Katalog / rodzaje** | definicje filamentu (marka, nazwa, typ, kolor), Twój „słownik" filamentów | „Bambu PLA Matte, Różowy" |
| **Fizyczne rolki** | konkretne szpule z wagą i ID, przypisane do slotu albo leżące w magazynie | `SP-00001`, 850 g, w slocie AMS A2 |

Kluczowa zasada: **stan (gramy) należy do rolki, nie do slotu.** Gdy przełożysz rolkę do innej
drukarki, jej gramy jadą razem z nią.

---

## 2. Jak dodać filament do magazynu (Spoolbase)

Otwórz okno **Spoolbase**:

- **macOS / Windows:** z menu aplikacji / paska.
- **Linux:** menu w zasobniku, pozycja **„Spoolbase, magazyn filamentów"**.

> Jeśli nie widzisz Spoolbase, włącz go w **Ustawieniach** (przełącznik „Spoolbase, magazyn
> filamentów").

W oknie Spoolbase filamenty są pogrupowane typem (PLA, PETG, ...), każdy z kolorową plakietką stanu.
Żeby dodać nowy:

1. Kliknij **＋** (Dodaj / Nowa).
2. Wybierz filament **z wbudowanego katalogu** (wyszukiwarka po marce, nazwie, kolorze) albo wpisz
   własny (marka, nazwa, typ, kolor HEX).
3. Podaj **liczbę szpul** na stanie.
4. Gotowe. Filament trafia do Twojego magazynu i jest widoczny przy przypisywaniu rolek.

---

## 3. Jak oznaczyć (przypisać) filament ze Spoolbase do slotu

Oznaczenie to powiązanie **konkretnej fizycznej rolki** z **konkretnym slotem** AMS/EXT na karcie.
Dzięki temu slot pokazuje kolor i gramy rolki (nawet gdy filament nie ma tagu RFID), a po wydruku
Gantry odejmie zużycie od tej właśnie rolki.

### Krok po kroku

1. Na karcie drukarki **kliknij pastylkę slotu** (fasolkę AMS albo pole EXT), np. „AMS A2".
   Otworzy się **panel przypisania** dla tego slotu.
2. Panel pokazuje: materiał widziany przez drukarkę, aktualnie przypisaną rolkę (albo „Brak") oraz
   listę wyboru.
3. Wybierz jedną z opcji:
   - **Nowa rolka:** utwórz rolkę i od razu włóż ją do slotu. Podaj wagę nominalną (np. 1000 g);
     rolka dostaje własne ID, np. `SP-00001`.
   - **Filament z katalogu:** utwórz rolkę powiązaną z rodzajem z Twojego magazynu (dzięki temu
     odejmowanie zna materiał i gęstość).
   - **Istniejąca rolka:** przenieś do tego slotu rolkę, która leży w magazynie albo w innej
     drukarce. Poprzedni slot zostaje zwolniony (jedna rolka może być tylko w jednym miejscu naraz).
4. Zatwierdź. Slot pokazuje teraz **kolor** rolki i (po włączeniu, patrz niżej) **gramy / procent**.

### Zmiana, korekta, zdjęcie

- **Ustawienie pozostałych gramów:** otwórz slot i wpisz aktualną wagę (przydatne po ważeniu rolki).
- **Odepnij:** rolka wraca do magazynu, slot znów pokazuje to, co widzi sama drukarka.
- **Przeniesienie między drukarkami:** wyjmij rolkę fizycznie, w drugiej drukarce kliknij slot i
  wybierz tę samą rolkę (`SP-000xx`). Gramy zostają bez zmian.

---

## 4. Przekładanie rolek: co robi Gantry, a co Ty

To jest sedno i najczęstsze źródło nieporozumień, więc po kolei. **Wszystko zależy od jednej rzeczy:
czy rolka ma tag RFID.**

### 4.1. Rolka z tagiem (Bambu z chipem) — Gantry robi to sam

Tag to numer, który drukarka odczytuje z rolki. Gantry traktuje go jako **tożsamość rolki**: ta sama
rolka jest rozpoznawana w dowolnym gnieździe dowolnej drukarki, choćbyś przekładał ją codziennie.

Gdy wkładasz oznaczoną rolkę:

| Sytuacja | Co się dzieje |
| --- | --- |
| tag znany (jakaś rolka w magazynie go ma) | ta rolka wraca do gniazda, bez pytania |
| tag nieznany, ale masz w magazynie taki produkt | Gantry bierze rolkę **rozpieczętowaną**, a gdy takiej nie ma — **najstarszą czekającą**, zapisuje na niej tag i wkłada do gniazda. Rolka schodzi ze stanu |
| tag nieznany i nie ma pasującego produktu | Gantry **pyta**, jedną rolką naraz, z gotowym wpisem wypełnionym danymi z tagu. „Nie, nie pytaj więcej" zapisuje ten tag na liście odrzuconych |
| w gnieździe wisiała inna rolka | ta wraca do magazynu, a na jej miejsce wjeżdża właściwa |

**Rozstrzyga niezgodność numerów, nie moment włożenia.** Dlatego działa też wtedy, gdy przełożyłeś
szpulę przy zamkniętej aplikacji, przy uśpionym komputerze albo w trakcie wznawiania połączenia —
Gantry zobaczy to przy pierwszym spojrzeniu i poprawi.

> **Każda oznaczona szpula to osobna rolka.** Trzy drukarki z tym samym PETG to trzy rolki zdjęte ze
> stanu, każda ze swoim tagiem.

Gdy wyjmiesz rolkę, gniazdo musi zgłaszać pustkę **przez dwie minuty**, zanim rolka wróci do magazynu
jako otwarta. Dwie minuty zapasu, bo AMS mignie pustym gniazdem przy każdej zmianie filamentu
w trakcie druku. Tag zostaje na rolce, więc następne włożenie rozpozna ją od razu.

### 4.2. Rolka bez chipa — przypisujesz Ty

Filament innych marek nie ma czego odczytać, więc:

- gdy w magazynie jest **dokładnie jedna** rolka pasująca materiałem i kolorem, zostaje przypisana sama,
- przy dwóch kandydatkach albo przy żadnej gniazdo zostaje puste, a rolkę wskazujesz klikiem w gniazdo,
- **ręczne przypisanie w gnieździe, które nie czyta żadnego tagu, nigdy nie jest ruszane.** Gantry nie
  ma prawa zdjąć czegoś, co ustawiłeś ręcznie, na podstawie zgadywania.

### 4.3. Przeniesienie do innej drukarki

- **z tagiem:** po prostu przełóż. Nic nie klikasz.
- **bez chipa:** wyjmij fizycznie, w drugiej drukarce kliknij gniazdo i wybierz tę samą rolkę
  (`SP-000xx`). Gramy jadą razem z nią, poprzednie gniazdo zostaje zwolnione.

### 4.4. Co Gantry mówi, kiedy coś przepina

Na karcie pojawia się krótka informacja z przyciskiem **OK**, na przykład:

> „SP-00003 wróciła do magazynu (wykryto tag NFC w AMS A2)".

Nic nie dzieje się po cichu.

### 4.5. Kiedy to wyłączyć

| Ustawienie | Co wyłącza |
| --- | --- |
| **Spoolbase, magazyn filamentów** (Ustawienia → Ogólne) | wszystko: żadnych przypisań, odejmowania ani pytań |
| **Paruj rolki z AMS ze Spoolbase** (Ustawienia → Ogólne) | automatyczne przypinanie i odpinanie. Odczyt z tagu dalej widać na karcie |
| **Pytaj o rolki spoza Spoolbase** (Ustawienia → Ogólne) | okno z propozycją dodania rolki do magazynu |

Pełna mechanika, wariant po wariancie, włącznie z tymi, w których Gantry celowo nie robi nic:
[filament-logika.md](filament-logika.md).

---

## 5. Gramy i procent na karcie

Domyślnie karta pokazuje kolory i procent slotów. Gramy z tagu pokazują się zawsze; te doliczone ze
Spoolbase — po włączeniu **„Gramy na rolce"** w Ustawieniach → Wygląd → Karty drukarek.

Skąd biorą się liczby, w tej kolejności:

1. **Gniazdo czyta tag:** procent i gramy **z tagu**, bo to pomiar drukarki — która wie też
   o filamencie zużytym poza Gantry, na przykład gdy drukowałeś bez włączonej aplikacji.
2. **Gniazdo bez tagu z przypisaną rolką:** procent i gramy **z magazynu**, bo gniazdo nic nie mierzy.
3. **Gniazdo bez tagu i bez rolki:** materiał i kolor z AMS, poziom tylko wtedy, gdy jest wiarygodny.

Dwa odczyty drukarki są odrzucane, bo pomiarem nie są:

- **`remain` ujemne** (AMS wysyła `-1`, gdy nie mierzy) znaczy „nie wiem", a nie „pusta" ani „pełna",
- **waga pełnej szpuli poniżej 150 g** nie jest wagą szpuli — najmniejsza, jaką się kupuje, to ćwierć
  kilograma. Jeden taki odczyt potrafił wcześniej zapisać rolce pojemność 100 g na stałe.

**Stan rolki w magazynie schodzi za tagiem w dół, nigdy w górę.** Gdy tag mówi mniej niż magazyn,
rację ma tag. Filamentu nie przybywa samo z siebie, a ręcznie wpisany stan nie rośnie.

**Nazwa koloru** nie mieści się w kafelku szerokim na 56 punktów, więc jest w dymku, razem z gniazdem,
materiałem, produktem, poziomem i gramami. Tag niesie samo RGBA, więc nazwę daje katalog Bambu:
najpierw dokładny kod koloru, potem najbliższy w promieniu, w którym to jeszcze ten sam kolor. Dalej —
bez nazwy, zamiast podstawiać sąsiedni odcień.

---

## 6. Automatyczne odejmowanie po wydruku

Po zakończonym wydruku Gantry odejmuje realnie zużyty filament od przypisanej rolki, lokalnie:

- **Klipper / Moonraker:** realne `filament_used` (mm) przeliczone na gramy (Ø1,75, gęstość wg typu),
- **Bambu:** `used_g` z wydrukowanego pliku `.gcode.3mf` pobranego po **lokalnym FTPS** (bez chmury).

Każde obciążenie jest **jednorazowe dla pary (drukarka, zadanie)**: ponowne połączenie, restart albo
dwa komputery patrzące na tę samą drukarkę nie policzą zużycia dwa razy. Gdy rolka zejdzie do zera,
idzie do historii zamiast na półkę, żeby lista wolnych rolek nie zapełniała się pustymi szpulami.

Trzy przypadki, w których Gantry celowo **nie** odejmuje:

- **gniazdo bez przypisanej rolki** → zapis „zużycie bez rolki": gramy i materiał są zapamiętane do
  wyceny, ale nie ma czego odjąć,
- **wydruk, którego końca Gantry nie widziało** (aplikacja była zamknięta) → rozliczany po fakcie jako
  **szacunek**, bez odejmowania, bo nikt nie potwierdził, że doszedł do końca. Do kosztów trafia,
- **wydruk przerwany** → obciąża proporcjonalnie do postępu sprzed przerwania, jako szacunek.

---

## Ściąga

| Chcę... | Zrób |
| --- | --- |
| dodać rodzaj filamentu | Spoolbase → **＋** → z katalogu lub własny |
| oznaczyć rolkę w slocie | karta → **klik w slot** → Nowa / z katalogu / istniejąca |
| poprawić wagę rolki | klik w slot → **Ustaw pozostałe gramy** |
| zdjąć rolkę ze slotu | klik w slot → **Odepnij** |
| przełożyć rolkę **z tagiem** | nic. Po prostu przełóż ją fizycznie |
| przełożyć rolkę **bez chipa** | klik w slot drugiej drukarki → wybierz `SP-000xx` |
| widzieć gramy doliczone ze Spoolbase | Ustawienia → Wygląd → **Gramy na rolce** |
| wyłączyć samo przypinanie | Ustawienia → Ogólne → **Paruj rolki z AMS ze Spoolbase** |

Zobacz też: [filament-logika.md](filament-logika.md) (pełna mechanika, wariant po wariancie),
[automations.md](automations.md) (reguły i sterowanie w Szczegółach).
