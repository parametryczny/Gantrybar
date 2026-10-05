# Gantry: logika filamentu — wszystkie warianty

Co Gantry robi z filamentem: co czyta z drukarki, kiedy sięga do magazynu, kiedy sam przypina rolkę,
a kiedy pyta. Opisane są wszystkie przypadki, łącznie z tymi, w których nie robi nic — bo „nie robi
nic" też jest decyzją.

Przewodnik dla użytkownika jest w [spoolbase.md](spoolbase.md); tu jest sama mechanika, identyczna na
macOS, Windows i GNU/Linuksie.

---

## 1. Co w ogóle jest czytane z gniazda

Z każdej ramki telemetrii Bambu Gantry bierze:

| Pole drukarki | Co znaczy | Co z nim robi Gantry |
| --- | --- | --- |
| `tray_uuid` | numer tagu RFID rolki | tożsamość rolki; same zera to brak tagu |
| `tray_type` | materiał (PLA, PETG…) | materiał na karcie |
| `tray_color` | kolor w RGBA | próbka koloru; nazwę daje dopiero katalog |
| `tray_sub_brands` | nazwa produktu („PLA Basic") | podpowiedź przy zakładaniu rolki, dymek |
| `tray_weight` | waga pełnej szpuli | pojemność zakładanej rolki |
| `remain` | ile procent zostało | poziom i gramy |

Dwa odczyty są odrzucane, bo nie są pomiarem:

1. **`remain` ujemne** (AMS wysyła `-1`, gdy nie mierzy) znaczy „nie wiem", a nie „pusta" ani „pełna".
2. **`tray_weight` poniżej 150 g** nie jest wagą szpuli — najmniejsza, jaką się kupuje, to ćwierć
   kilograma. Jeden taki odczyt potrafił wcześniej zapisać rolce pojemność 100 g na stałe.

Szpula zewnętrzna (`vt_tray`) jest wystawiana jako gniazdo grupy EXT i czytana tak samo, tyle że
Bambu jej nie mierzy: `remain: 0` z EXT znaczy „nie wiem".

---

## 2. Wkładasz oznaczoną szpulę (z tagiem)

Warunek wstępny dla całej tej sekcji: **Spoolbase włączone** i **parowanie po tagach włączone**.
Z wyłączonym parowaniem Gantry nie rusza przypisań — czyta tag tylko po to, żeby pokazać dane.

1. **Gniazdo puste, tag znany** (jakaś rolka w magazynie ma ten numer) → ta rolka wraca do gniazda.
   Rozpoznanie jest po numerze, więc działa w dowolnej drukarce i dowolnym gnieździe.
2. **Gniazdo puste, tag nieznany, produkt jest w magazynie** (ten sam materiał, kolor w promieniu
   „to jeszcze ten sam kolor", marka Bambu pierwsza, nazwa produktu z tagu w pierwszej kolejności) →
   Gantry bierze z magazynu **rolkę już rozpieczętowaną**, a gdy takiej nie ma, **najstarszą czekającą**,
   zapisuje na niej tag i wkłada do gniazda. Rolka schodzi ze stanu.
3. **Gniazdo puste, tag nieznany, nie ma pasującego produktu** → nic się nie dzieje samo z siebie.
   Gantry **pyta** — jedną rolką naraz, nigdy dwunastoma — i proponuje wpis wypełniony danymi z tagu:
   marka Bambu Lab, produkt, kolor i jego nazwa z katalogu. Odpowiedź „nie, nie pytaj więcej" zapisuje
   ten tag na liście odrzuconych i więcej o niego nie zapyta.
4. **Gniazdo puste, nie ma rolki w magazynie pod ten produkt** → zakładana jest nowa, z wagą z tagu
   (albo kilogram, gdy tag jej nie podaje) i ceną produktu.
5. **W gnieździe wisi rolka z innym tagiem albo bez tagu** → to przypisanie jest nieaktualne, bo tej
   szpuli fizycznie tam nie ma. Rolka wraca do magazynu, a zaraz po niej wjeżdża właściwa, według
   punktów 1–4. **Rozstrzyga niezgodność numerów, nie moment włożenia** — więc działa to także wtedy,
   gdy szpulę zmieniłeś przy zamkniętej aplikacji, przy uśpionym komputerze albo w czasie wznawiania
   połączenia.
6. **W gnieździe wisi rolka z tym samym tagiem** → nie dzieje się nic poza uzgodnieniem liczb
   (punkt 6 w sekcji 5): to jest dokładnie ta rolka.

Każda oznaczona szpula to osobna rolka. **Trzy drukarki z tym samym PETG to trzy rolki zdjęte ze
stanu**, każda ze swoim tagiem.

---

## 3. Wkładasz szpulę bez chipa

1. **W magazynie jest dokładnie jedna rolka pasująca materiałem i kolorem** → zostaje przypisana sama.
   „Dokładnie jedna" jest tu istotne: przy dwóch kandydatkach Gantry nie zgaduje.
2. **Pasuje więcej niż jedna albo żadna** → gniazdo zostaje nieprzypisane, a Ty wskazujesz rolkę
   ręcznie (klik w gniazdo). Do czasu przypisania wydruk z tego gniazda nie ma czego obciążyć i
   kończy się ostrzeżeniem rozliczeniowym.
3. **Ręczne przypisanie w gnieździe, które nie czyta żadnego tagu, nigdy nie jest ruszane.** Sama waga
   z tagu bez numeru też niczego nie rozstrzyga: mówi, że coś tam leży, ale nie mówi co.

---

## 4. Wyjmujesz szpulę

1. **Gniazdo zgłasza pustkę przez dwie minuty** → rolka wraca do magazynu jako otwarta i czeka.
   Dwie minuty zapasu, bo AMS mignie pustym gniazdem przy każdej zmianie filamentu w trakcie druku.
2. **Rolka wróciła pusta (0 g)** → idzie do historii zamiast na półkę, żeby lista wolnych rolek nie
   zapełniała się pustymi szpulami.
3. **Tag zostaje na rolce.** Następne włożenie — do tej samej albo innej drukarki — rozpoznaje ją od
   razu i bez pytania.

---

## 5. Co widać na karcie

1. **Gniazdo z tagiem**: procent i gramy **z tagu**, bo to pomiar drukarki, która wie też o filamencie
   zużytym poza Gantry.
2. **Gniazdo bez tagu z przypisaną rolką**: procent i gramy **z magazynu**, bo gniazdo nic nie mierzy.
3. **Gniazdo bez tagu i bez rolki**: materiał i kolor z AMS, poziom tylko wtedy, gdy jest wiarygodny.
4. **Kolor** bierze się z definicji przypisanej rolki, gdy jakaś jest — bo to Ty powiedziałeś, co tam
   stoi — a w przeciwnym razie z odczytu gniazda.
5. **Nazwa koloru** nie mieści się w kafelku szerokim na 56 punktów, więc jest w dymku, razem z
   gniazdem, materiałem, produktem, poziomem i gramami. Tag niesie tylko RGBA, więc nazwę daje katalog
   Bambu: najpierw dokładny kod koloru, potem najbliższy w promieniu, w którym to jeszcze ten sam
   kolor. Dalej — bez nazwy, zamiast podstawiać sąsiedni odcień.
6. **Gramy pod gniazdem**: z tagu pokazują się zawsze, a te doliczone ze Spoolbase — gdy włączysz
   „Gramy na rolce" w Ustawieniach → Wygląd → Karty drukarek.
7. **Czerwona kropka „mało filamentu"** zapala się przy 15% i tylko przy wiarygodnym poziomie, czyli
   z tagu albo z przypisanej rolki. Szpula zewnętrzna nie dostaje jej nigdy, bo jej poziomu nikt nie mierzy.
8. **Rolka w magazynie schodzi za odczytem tagu w dół**: gdy tag mówi mniej niż magazyn, rację ma tag.
   W górę nic się nie dzieje — filamentu nie przybywa samo z siebie, a ręcznie wpisany stan nie rośnie.
   Pojemność rolki rośnie, gdy tag podaje większą (naprawa po błędnym odczycie), ale nigdy nie maleje.

---

## 6. Co schodzi z rolki po wydruku

1. **Bambu**: gramy bierze się z `used_g` zapisanych przez krajalnicę w pliku wydruku. Plik jest
   czytany **w trakcie druku**, bo drukarka kasuje go z karty wkrótce po zakończeniu; odczyt leży na
   dysku i przeżywa restart aplikacji.
2. **Klipper**: gramy liczone z `filament_used_mm` i gęstości materiału, obciążana jest rolka z
   gniazda, z którego szedł druk.
3. **Każde obciążenie jest jednorazowe** dla pary (drukarka, identyfikator zadania), więc ponowne
   połączenie ani restart niczego nie dubluje.
4. **Gniazdo bez przypisanej rolki** → zapis „zużycie bez rolki": gramy i materiał są zapamiętane do
   wyceny, ale nie ma czego odjąć.
5. **Wydruk, którego końca Gantry nie widziało** (aplikacja była zamknięta) → rozliczany po fakcie z
   odczytu zrobionego na starcie, jako **szacunek** i **bez odejmowania z rolki**, bo nikt nie
   potwierdził, że doszedł do końca. Do kosztów trafia.
6. **Plik nowszy niż początek wydruku** to już następna płyta tego samego projektu — jego gramy nie
   należą do tego wydruku i nie są brane. Dziesięć minut zapasu na zegar drukarki i wysyłkę pliku.
7. **Wydruk przerwany** obciąża proporcjonalnie do postępu sprzed przerwania, jako szacunek.

---

## 7. Przełączniki, które to wyłączają

| Ustawienie | Co wyłącza |
| --- | --- |
| **Spoolbase, magazyn filamentów** | wszystko powyższe: żadnych przypisań, odejmowania ani pytań |
| **Paruj rolki z AMS ze Spoolbase** | automatyczne przypinanie i odpinanie; odczyt z tagu dalej widać |
| **Pytaj o rolki spoza Spoolbase** | okno z propozycją dodania rolki do magazynu |
| **Lista odrzuconych tagów** | pojedyncze tagi, przy których odpowiedziałeś „nie pytaj więcej" |
| **Gramy na rolce** | wiersz z gramami doliczonymi ze Spoolbase (te z tagu zostają) |

---

## Ściąga

- **Tag rządzi tożsamością**: ta sama rolka w dowolnej drukarce jest rozpoznawana po numerze.
- **Tag rządzi poziomem**: jego pomiar bije stan z magazynu, ale tylko w dół.
- **Magazyn rządzi tam, gdzie nie ma tagu**: filament bez chipa przypisujesz ręcznie i to przypisanie
  jest nienaruszalne.
- **Gantry nie zgaduje**: przy dwóch pasujących rolkach, nieznanym kolorze albo braku pomiaru woli nie
  powiedzieć nic, niż podstawić liczbę, której nikt nie zmierzył.
