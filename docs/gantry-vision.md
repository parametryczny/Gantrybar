# Gantry Vision: pilnowanie wydruków

Gantry patrzy na obraz z kamery w trakcie druku i odzywa się, gdy widzi, że coś poszło nie tak.
Nie zatrzymuje drukarki sam — pokazuje, co zobaczył, i pyta.

Ten dokument mówi, jak to działa, czego można się spodziewać na początku i dlaczego z czasem
działa lepiej. Pochodzenie klatek wzorcowych opisuje osobno
[defect-starter-attribution.md](defect-starter-attribution.md).

---

## 1. Czego Gantry nie robi

Zacznijmy od tego, żeby nie było nieporozumienia.

- **Nie przerywa wydruku.** Daje ostrzeżenie i czeka na Twoją odpowiedź. Decyzja jest Twoja.
- **Nie wysyła obrazu nigdzie.** Wszystko liczy się na Twoim komputerze. Klatki nie opuszczają go
  ani przy pilnowaniu, ani przy uczeniu.
- **„Nie widzę awarii" to nie to samo co „wydruk jest dobry".** To znaczy tyle, że nic na obrazie nie
  wygląda na awarię — nie, że wszystko jest w porządku.

---

## 2. Jak to działa

### 2.1. Jedno spojrzenie to pięć klatek, nie jedna

Każde spojrzenie to **pięć klatek w odstępie około sekundy, złożonych medianą w jeden obraz**.
Głowica, która akurat przejeżdża przez kadr, jest na jednej albo dwóch klatkach z pięciu, więc
mediana ją usuwa — zostaje stół z wydrukiem.

To nie jest drobiazg: ruchoma głowica była główną przyczyną fałszywych alarmów.

### 2.2. Pytane są dwie strony naraz

**Silnik** (model Core ML, domyślnie Gantry Vision) ocenia złożony obraz i podaje, jak bardzo to
wygląda na awarię.

**Bank porównawczy** robi coś innego: zamienia obraz na listę liczb opisujących, jak obraz wygląda,
i sprawdza, do czego mu bliżej — do znanych zdjęć awarii czy do tego, jak u Ciebie wygląda normalny
druk. To nie jest sieć ucząca się w locie, tylko porównanie z tym, co już zebrane.

Odpowiada mocniejszy powód. Silnik zna kamery, na których był uczony; Twoje klatki znają kamerę,
która stoi przed Tobą. Gdy silnik mówi „coś podobnego do awarii, ale za słabo", a klatka z tej samej
kamery, którą sam oznaczyłeś, mówi wprost — rację ma Twoja klatka.

### 2.3. Ostrzeżenie wymaga powtórzenia

Jedno spojrzenie niczego nie uruchamia. Ostrzeżenie idzie dopiero po **trzech zgodnych spojrzeniach
z rzędu**. Przy fałszywce rzędu jednej na czterdzieści spojrzeń szansa, że trafią się trzy pod rząd,
spada do około 0,002%.

### 2.4. Osobno: zachowanie wydruku

Oderwanie obiektu od stołu nie jest widoczne na jednej klatce — to różnica między klatkami. Tego
pilnuje osobna obserwacja, na żywo, niezależnie od silnika.

---

## 3. Czego spodziewać się na początku

**Na początku Gantry Vision może się mylić.** Może oznaczyć dobry wydruk jako awarię, może przeoczyć
awarię, która dla Ciebie jest oczywista. To nie jest usterka — tak wygląda punkt wyjścia.

Powód jest prosty: na starcie Gantry zna tylko to, jak wygląda awaria *w ogóle*. Nie wie jeszcze, jak
wygląda **normalny druk na Twojej kamerze**: jakie masz oświetlenie, pod jakim kątem patrzy obiektyw,
jakiego koloru jest Twój stół, co zwykle leży w kadrze. Dwie kamery w dwóch komorach potrafią dawać
obrazy bardziej różne od siebie niż udany wydruk od nieudanego.

**I to się naprawia samo w miarę używania.**

| Co robisz | Co z tego wynika |
| --- | --- |
| odpowiadasz na ostrzeżenie „to fałszywy alarm" | ta klatka wchodzi do banku jako „tak wygląda u mnie poprawny druk" |
| odpowiadasz „tak, to awaria" | Gantry zapamiętuje, jak awaria wygląda na **Twojej** kamerze |
| oznaczasz klatkę z ręki w Szczegółach („Zaznacz defekt…") | to samo, tylko kiedy Ty chcesz, a nie kiedy Gantry zapyta |
| **nic nie robisz, a wydruk idzie dobrze** | Gantry sam odkłada klatki udanego druku jako wzorzec „normalnie" |

Ostatni wiersz jest tu najważniejszy: **samo drukowanie uczy**. Im dłużej Gantry patrzy na Twoje
drukarki, tym lepiej odróżnia Twój normalny druk od awarii — bez żadnej pracy z Twojej strony.

Pierwsze dni warto więc odpowiadać na pytania zamiast je zamykać. Każda odpowiedź jest warta więcej
niż ustawienie suwaka.

---

## 4. Suwak czułości

Jeden suwak, wspólny dla wszystkich silników. **Skala wyników wspólna nie jest** — „90%" u jednego
modelu znaczy co innego niż u drugiego.

Ustawienie go za wysoko potrafi wyciszyć wykrywanie tak, że nigdy się o tym nie dowiesz: Gantry
Vision przy 70% łapie w swoim pomiarze wszystkie awarie, a przy 90% dwie na dwadzieścia dwie.
Dlatego gdy suwak stoi powyżej progu, przy którym silnik był mierzony, **Ustawienia piszą to wprost
obok suwaka**.

Domyślne 70% zostaw, dopóki nie masz powodu, żeby je ruszyć.

---

## 5. Ile to daje (zmierzone)

Pomiar na 62 klatkach z kamer w komorze Bambu, czyli na tym rodzaju obrazu, jaki Gantry naprawdę
dostaje. Przy domyślnej czułości 70%:

| | Gantry Vision |
| --- | --- |
| Złapane awarie | **22 / 22** |
| Fałszywe alarmy | 1 / 40 klatek |

Najniższy wynik na klatce z awarią to 0,772, najwyższy na klatce bez awarii 0,763 — na tym zbiorze
klasy rozchodzą się, nie zachodząc na siebie.

To pomiar na konkretnych kamerach i konkretnych wydrukach, nie obietnica. U Ciebie będzie inaczej,
w którąś stronę — i właśnie po to jest punkt 3.

---

## 6. Sprawdź to na własnych wydrukach

Nie musisz wierzyć liczbom powyżej. Gantry nagrywa każdy pilnowany wydruk: złożone klatki, co o nich
powiedział silnik i obserwacja zachowania, ostrzeżenia, Twoje odpowiedzi i to, jak wydruk się
skończył.

**Ustawienia → Zaawansowane → „Oceń nagrane wydruki…"** odtwarza wszystkie nagrania z obecnymi
ustawieniami i liczy na całe wydruki, nie na klatki:

- fałszywe alarmy na 100 godzin druku,
- ile potwierdzonych awarii zostało złapanych,
- o ile minut wcześniej.

To opisuje się samo: wydruk zakończony bez potwierdzonej awarii był dobry, więc każde ostrzeżenie na
nim to fałszywy alarm. Możesz tak porównać ustawienia albo dwa różne silniki na **swoich** wydrukach.

Nagrania mają ten sam limit miejsca co zbiór klatek; najstarsze znikają pierwsze.

---

## 7. Dla ciekawych: co to za model

MobileNetV3 Small, wejście 224×224 RGB, dwa wyjścia: `failure` i `no_failure_annotated`. Wagi własne,
trenowane lokalnie przez autora Gantry; dane uczące pochodzą z publicznie dostępnego zbioru klatek
awarii druku 3D, który nie deklaruje licencji. Plik `Resources/GantryVisionPrintFailure.mlpackage`
waży 3 MB i jest w aplikacji — niczego nie trzeba wskazywać ani pobierać.

Do Core ML przeniesiony z ONNX razem z normalizacją wpisaną w graf, żeby nie dało się jej pomylić po
stronie aplikacji. Zgodność po konwersji sprawdzona na 62 klatkach: największa różnica wyniku między
ONNX a Core ML to 0,049, punkt pracy ten sam.

### Własny silnik

**Ustawienia → Zaawansowane → Wykrywanie błędów wydruku → Plik modelu.** Wskazany plik Core ML
zastępuje Gantry Vision naraz w pilnowaniu w tle i w przycisku „Testuj". Nazwa na ekranie bierze się
z metadanych modelu, więc nie zmienia się po przemianowaniu pliku.

Twoje oznaczone klatki działają dalej, także z cudzym silnikiem.

---

Zobacz też: [defect-starter-attribution.md](defect-starter-attribution.md) (klatki wzorcowe: co w nich
jest, czego w nich nie ma i dlaczego klasa „poprawnie" nie da się przywieźć z zewnątrz).
