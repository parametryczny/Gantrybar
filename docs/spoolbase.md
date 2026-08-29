# Gantry: Spoolbase i filament (jak dodać i oznaczyć rolkę)

Przewodnik po **magazynie filamentów (Spoolbase)** i **fizycznych rolkach**: jak działa aplikacja,
jak dodać filament do magazynu i jak przypisać (oznaczyć) konkretną rolkę do slotu AMS/EXT, żeby
Gantry pokazywał jej kolor, procent i gramy, a po wydruku sam odejmował zużycie.

Wszystko działa **lokalnie, bez chmury i bez logowania**, tak samo na **macOS, Windows i Linux**.
Różni się tylko sposób otwierania okien (opisany niżej).

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
  zewnątrz ani w synchronizacji.

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

Ten katalog **synchronizuje się** między Twoimi komputerami (macOS/Windows/Linux) razem z rolkami i
ustawieniami, jeśli włączysz synchronizację w LAN.

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

## 4. Gramy i procent na karcie

Domyślnie karta pokazuje kolory i procent slotów. Żeby widzieć **gramy**:

- w **Ustawieniach** włącz **„Gramy na rolce (AMS NFC / Spoolbase)"**.

Skąd biorą się gramy:

- **rolka Bambu z tagiem RFID/NFC:** liczone z odczytu tagu, `tray_weight × remain%` (np. 1000 g ×
  85% = 850 g),
- **rolka przypisana w Spoolbase:** z jej zapisanej wagi (działa też dla filamentu bez tagu),
- **rolka bez tagu i bez przypisania:** brak źródła wagi (przypisz rolkę ze Spoolbase, żeby ją mieć).

---

## 5. Tag NFC/RFID kontra ręczne przypisanie

Jeśli do slotu z **ręcznie przypisaną** rolką **włożysz rolkę z tagiem NFC/RFID**, Gantry rozpozna, że
tamta rolka została wyjęta, i **automatycznie ją odpina** (wraca do magazynu). Na karcie pojawia się
wtedy krótka informacja z przyciskiem **OK**, np.:

> „SP-00003 wróciła do magazynu (wykryto tag NFC w AMS A2)".

Dzięki temu slot zawsze pokazuje dane rolki, która faktycznie w nim siedzi.

---

## 6. Automatyczne odejmowanie po wydruku

Po zakończonym wydruku Gantry odejmuje realnie zużyty filament od przypisanej rolki, lokalnie:

- **Klipper / Moonraker:** realne `filament_used` (mm) przeliczone na gramy (Ø1,75, gęstość wg typu),
- **Bambu:** `used_g` z wydrukowanego pliku `.gcode.3mf` pobranego po **lokalnym FTPS** (bez chmury).

Odejmowanie jest **idempotentne per zadanie**: reconnect, restart albo dwa komputery patrzące na tę
samą drukarkę nie policzą zużycia dwa razy. Gdy rolka zejdzie do zera, dostaje status „pusta".

---

## 7. Synchronizacja i wiele komputerów

Rolki, magazyn (katalog) i zużycie **synchronizują się w sieci lokalnej** między Twoimi komputerami
(macOS, Windows, Linux). Scalanie działa metodą „ostatni wygrywa" po czasie zmiany, a zużycie jest
idempotentne, więc wspólny wydruk nie odejmie się podwójnie. **Kody dostępu do drukarek nie są
przesyłane.**

---

## Ściąga

| Chcę... | Zrób |
| --- | --- |
| dodać rodzaj filamentu | Spoolbase → **＋** → z katalogu lub własny |
| oznaczyć rolkę w slocie | karta → **klik w slot** → Nowa / z katalogu / istniejąca |
| poprawić wagę rolki | klik w slot → **Ustaw pozostałe gramy** |
| zdjąć rolkę ze slotu | klik w slot → **Odepnij** |
| przenieść rolkę do innej drukarki | klik w slot drugiej drukarki → wybierz `SP-000xx` |
| widzieć gramy na karcie | Ustawienia → **Gramy na rolce (AMS NFC / Spoolbase)** |

Zobacz też: [automations.md](automations.md) (reguły i sterowanie w Szczegółach).
