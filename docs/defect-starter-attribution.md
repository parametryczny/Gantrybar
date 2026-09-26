# Klatki wzorcowe wpadek: skąd są, na jakiej licencji i czego nie ma

`Resources/defect-starter-v1.bank` i `Resources/defect-starter-v2.bank` to pliki, z których Gantry
rozpoznaje spaghetti. Nie ma w nich żadnych zdjęć. Są w nich liczby, które system macOS (Vision,
`VNGenerateImageFeaturePrintRequest`) wylicza ze zdjęcia: po 64 wektory, jedna klasa. Ze zdjęcia nie
da się ich odtworzyć w drugą stronę.

Pliki są dwa, bo liczby Vision znaczą to samo tylko w obrębie jednej rewizji. Rewizja 1 działa
wszędzie, gdzie działa Gantry (2048 liczb na wektor, 512 kB). Rewizja 2 wymaga macOS 14, jest
wyraźnie lepsza i mniejsza (768 liczb, 192 kB). Każdy Mac dostaje to, co potrafi policzyć.

## Jedna klasa, i to jest sedno

W banku jest **tylko spaghetti**. Nie ma klasy „drukuje poprawnie" i nie będzie, bo nie da się jej
przywieźć z zewnątrz.

Próbowałem. Klasa „poprawnie" powstała z 430 zdjęć normalnie pracujących drukarek na wolnych
licencjach ze zbiorów Openverse. Pomiary wyglądały świetnie i były bezwartościowe, bo mierzyły nie
to, co trzeba: zdjęcia „poprawnie" były robione w dzień, z zewnątrz, i pokazywały całe drukarki na
biurku, a zdjęcia spaghetti były zbliżeniami z wnętrza komory. Te dwie klasy w rzeczywistości
znaczyły „na zewnątrz" i „wewnątrz drukarki". Każda klatka z prawdziwej kamery w komorze lądowała po
stronie spaghetti, niezależnie od tego, co było na stole. Poprawny wydruk wracał jako spaghetti.

Zmierzone potem uczciwie, z odłożoną całą jedną kamerą po każdej stronie, już na zbiorach z klasą
„bez wady" z tych samych kamer:

| Odłożone | Złapane spaghetti | Fałszywe alarmy |
| --- | --- | --- |
| kamera D i A | 18 / 90 | 0 / 110 |
| kamera E i B | 152 / 200 | 41 / 110 |
| kamera F i C | 44 / 90 | 0 / 110 |

Czyli na kamerze, której bank nigdy nie widział, potrafi wyjść 37 fałszywych alarmów na sto
poprawnych wydruków. To nie jest detektor, to moneta z przewagą.

Dlatego wożona jest tylko jedna klasa, a bank z jedną klasą **nie potrafi nikogo oskarżyć**: nie ma
z czym porównać, więc nie ma zdania. Druga klasa bierze się z jedynego miejsca, z którego może:
z Twojej kamery. Klatki oznaczone w Szczegółach, oraz klatki, które Gantry zachowuje samo, gdy
wydruk idzie dobrze (najwyżej trzy na wydruk, z jego środka, co najmniej osiem minut od siebie).
Dopiero wtedy porównanie ma sens: cudze spaghetti kontra to, co ta drukarka uważa za normalne.

Zanim to nastąpi, pilnowanie opiera się wyłącznie na obserwacji zachowania wydruku, która nie
potrzebuje żadnych danych i tego problemu nie ma.

## Spaghetti: 380 zdjęć, Creative Commons Uznanie autorstwa 4.0 (CC BY 4.0)

| Zbiór | Autor | Ile wzięto | Adres |
| --- | --- | --- | --- |
| 3D printing flaws | SpaghettiDetect | 90 | https://universe.roboflow.com/spaghettidetect/3d-printing-flaws |
| All_Anomalies | 3D Printer Failure | 90 | https://universe.roboflow.com/3d-printer-failure/all_anomalies-rfe61 |
| 3D printing failure | 3D Printing Failure | 90 | https://universe.roboflow.com/3d-printing-failure/3d-printing-failure |
| 3D Printing Defect Classification | project | 110 | https://universe.roboflow.com/project-jkfnh/3d-printing-defect-classification |

Licencja: https://creativecommons.org/licenses/by/4.0/

Pełna lista adresów, zdjęcie po zdjęciu, jest w `scripts/defect-starter-sources.tsv`.

## Jak to odtworzyć

```
python3 scripts/build_defect_starter.py
```

Skrypt pobiera zdjęcia z adresów w `scripts/defect-starter-sources.tsv`, liczy wektory i zapisuje
oba banki. Zdjęć nie trzymamy w repozytorium: nie są potrzebne do działania Gantry, a ich miejsce
to serwisy, z których pochodzą.

Wzorce dobierane są tak, żeby leżały jak najdalej od siebie: bank pełen prawie identycznych zdjęć
opisuje jedną kamerę, a nie klasę.

## Czego ten plik nie robi

Dotyczy wyłącznie spaghetti. Oderwanie obiektu, przesunięcie warstw i blob na dyszy zostają przy
obserwacji zachowania wydruku i przy klatkach, które sam oznaczysz.
