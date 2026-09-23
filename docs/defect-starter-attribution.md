# Klatki wzorcowe wpadek: skąd są i na jakiej licencji

`Resources/defect-starter-v1.bank` i `Resources/defect-starter-v2.bank` to pliki, dzięki którym
Gantry rozpoznaje spaghetti od pierwszego wydruku, bez uczenia czegokolwiek przez użytkownika. Nie
ma w nich żadnych zdjęć. Są w nich liczby, które system macOS (Vision,
`VNGenerateImageFeaturePrintRequest`) wylicza ze zdjęcia: po 128 wektorów, dwie klasy. Ze zdjęcia
nie da się ich odtworzyć w drugą stronę.

Pliki są dwa, bo liczby Vision znaczą to samo tylko w obrębie jednej rewizji. Rewizja 1 działa
wszędzie, gdzie działa Gantry (2048 liczb na wektor, 1 MB). Rewizja 2 wymaga macOS 14, jest wyraźnie
lepsza i mniejsza (768 liczb, 384 kB). Każdy Mac dostaje to, co potrafi policzyć.

Policzone zostały z 676 zdjęć na wolnych licencjach. Poniżej to, z czego i na jakich warunkach,
bo licencja CC BY wymaga podania autorstwa.

## Spaghetti: 270 zdjęć, Creative Commons Uznanie autorstwa 4.0 (CC BY 4.0)

| Zbiór | Autor | Ile wzięto | Adres |
| --- | --- | --- | --- |
| 3D printing flaws | SpaghettiDetect | 90 | https://universe.roboflow.com/spaghettidetect/3d-printing-flaws |
| All_Anomalies | 3D Printer Failure | 90 | https://universe.roboflow.com/3d-printer-failure/all_anomalies-rfe61 |
| 3D printing failure | 3D Printing Failure | 90 | https://universe.roboflow.com/3d-printing-failure/3d-printing-failure |

Licencja: https://creativecommons.org/licenses/by/4.0/

## Poprawny druk: 406 zdjęć, CC BY 4.0 i CC0

Zdjęcia normalnie pracujących drukarek, zebrane przez Openverse z serwisów Flickr i Wikimedia
Commons, każde na licencji CC BY albo CC0. Pełna lista adresów, autorów i licencji każdego zdjęcia
jest w `scripts/defect-starter-sources.tsv`, plik po pliku.

Openverse: https://openverse.org

## Jak to odtworzyć

```
python3 scripts/build_defect_starter.py
```

Skrypt pobiera zdjęcia z adresów w `scripts/defect-starter-sources.tsv`, liczy wektory i zapisuje
`Resources/defect-starter.bank`. Zdjęć nie trzymamy w repozytorium: nie są potrzebne do działania
Gantry, a ich miejsce to serwisy, z których pochodzą.

## Co to daje i czego nie daje

Sprawdzone uczciwie, czyli na zdjęciach ze źródła, które nic do banku nie wniosło: uczymy na dwóch
zbiorach spaghetti i czterech piątych fotografów, sprawdzamy na trzecim zbiorze i pozostałych
fotografach. Żadne zdjęcie użyte do sprawdzenia nie jest w banku. Przy domyślnej czułości 70%:

Rewizja 2 (macOS 14 i nowszy):

| Zbiór odłożony | Złapane spaghetti | Fałszywe alarmy |
| --- | --- | --- |
| 3D printing flaws | 84 / 90 | 0 / 108 |
| All_Anomalies | 17 / 90 | 0 / 108 |
| 3D printing failure | 77 / 90 | 1 / 108 |

Rewizja 1 (macOS 13):

| Zbiór odłożony | Złapane spaghetti | Fałszywe alarmy |
| --- | --- | --- |
| 3D printing flaws | 47 / 90 | 4 / 108 |
| All_Anomalies | 19 / 90 | 4 / 108 |
| 3D printing failure | 42 / 90 | 5 / 108 |

Czyli: ile wpadek zostanie złapanych, zależy mocno od tego, jak bardzo kadr przypomina to, co bank
już widział, i waha się od jednej piątej do dziewięciu na dziesięć. To, co trzyma się stabilnie na
rewizji 2, to brak fałszywych alarmów: najwyżej jeden na sto poprawnych wydruków. Dla czegoś, co
może obudzić człowieka w nocy, jest to właściwa kolejność. Na macOS 13 obie liczby są gorsze i taka
jest cena starszego systemu.

Wzorce dobierane są tak, żeby leżały jak najdalej od siebie: bank pełen prawie identycznych zdjęć
opisuje jedną kamerę, a nie klasę. Sprawdzone: dobieranie najbardziej typowych kadrów podnosi
skuteczność na najtrudniejszym zbiorze, ale jednocześnie daje pięć razy więcej fałszywych alarmów,
więc nie jest tego warte.

## Czego ten plik nie robi

Rozpoznaje spaghetti i poprawny druk, i nic więcej. Oderwanie obiektu, przesunięcie warstw i blob
na dyszy zostają przy obserwacji zachowania wydruku i przy klatkach, które sam oznaczysz.

Oznaczenie własnych klatek w Szczegółach dokłada je do tego samego banku i w praktyce przeważa,
bo zdjęcie z Twojej kamery leży znacznie bliżej następnej klatki z tej samej kamery niż
jakiekolwiek cudze zdjęcie.
