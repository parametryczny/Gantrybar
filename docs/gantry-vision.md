# Gantry Vision print-failure

Silnik, którym Gantry domyślnie ocenia, co widać na klatce z kamery. Leży
w `Resources/GantryVisionPrintFailure.mlpackage` (3 MB) i nie trzeba go niczym
wskazywać: jest w aplikacji.

## Co to jest

MobileNetV3 Small, wejście 224x224 RGB, dwa wyjścia: `no_failure_annotated`
i `failure`. Wagi własne, trenowane lokalnie przez autora Gantry. Do Core ML
przeniesione z oryginalnego ONNX razem z normalizacją wpisaną w graf, żeby nie
trzeba było jej powtarzać po stronie aplikacji i żeby nie dało się jej pomylić.

Zgodność po konwersji sprawdzona na 62 klatkach: maksymalna różnica wyniku
między ONNX a Core ML to 0,049, a punkt pracy wychodzi ten sam.

## Ile to daje

Zmierzone na 62 klatkach z kamer w komorze Bambu, czyli na tym rodzaju obrazu,
jaki Gantry naprawdę dostaje. Przy domyślnej czułości 70%:

| Silnik | Złapane awarie | Fałszywe alarmy |
| --- | --- | --- |
| Gantry Vision | **22 / 22** | 1 / 40 |
| YOLO11n z sieci, uczony na zbliżeniach | 1 / 22 | brak danych |

Najniższy wynik na klatce z awarią to 0,772, najwyższy na klatce bez awarii
0,763, więc na tym zbiorze klasy rozchodzą się bez zachodzenia na siebie. Próg
0,70 łapie wszystko przy jednym fałszywym alarmie na czterdzieści klatek, a że
ostrzeżenie wymaga trzech zgodnych spojrzeń z rzędu, szansa na fałszywkę
w całym oknie spada do około 0,002%.

Ta różnica wobec modelu z sieci nie bierze się z architektury. Bierze się z
tego, na jakich zdjęciach model był uczony: tamten widział zbliżenia, a kamera
w komorze daje szeroki kadr rybim okiem z całym stołem.

## Czego nie obiecuje

Rozpoznaje „jest awaria" i „nie ma adnotacji awarii". Ta druga odpowiedź nie
jest zaświadczeniem, że wydruk jest dobry, tylko że model nie widzi awarii. Nie
ma osobnych klas nitkowania, blobu ani oderwania obiektu; tego ostatniego pilnuje
obserwacja zachowania wydruku, osobno i na żywo.

Zbiór uczący pochodzi z publicznego repozytorium AAI3001 Final Project, które
nie deklaruje licencji. Same wagi są własne.

## Wymiana silnika

Ustawienia, Zaawansowane, Wykrywanie wpadek, Plik modelu. Wskazany plik Core ML
zastępuje Gantry Vision, w pilnowaniu w tle i w przycisku „Testuj" jednocześnie.
Nazwa pokazywana na ekranie bierze się z metadanych modelu, więc nie zmienia się
po przemianowaniu pliku.
