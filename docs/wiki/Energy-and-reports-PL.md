# Energia, koszty i eksport wydruków

[English](https://github.com/parametryczny/Gantrybar/wiki/Energy-and-reports-EN) · [Spis treści](https://github.com/parametryczny/Gantrybar/wiki/Home)

## Uruchom pomiar w tle

1. Przypisz do drukarki gniazdko z odczytem mocy — obsługiwane Tasmota lub Shelly.
2. Sprawdź, czy Gantry odczytuje waty. Możliwość włączenia gniazdka nie oznacza możliwości pomiaru mocy.
3. Ustaw cenę energii za kWh i pozostałe koszty w **Ustawieniach → Wycena**.
4. Pozostaw Gantry uruchomione podczas cyklu drukowania. Szczegóły nie muszą być otwarte.

Odczyty następują co około 5 s. Energia jest liczona z próbek mocy i czasu między nimi, a nie z różnicy całkowitego licznika gniazdka. Cykl obejmuje także pauzy oraz przygotowanie zgłoszone jako aktywny wydruk.

## Odczytaj wynik

| Wynik | Interpretacja |
| --- | --- |
| pomiar | odczyty pokrywają cykl w wymaganym zakresie |
| pomiar częściowy | zmierzony fragment + szacunek brakującego czasu |
| szacunek | obliczenie ze średniej mocy w ustawieniach |

Przerwy ponad 30 s nie są łączone prostą linią pomiaru. Restart lub rozpoczęcie obserwacji w połowie wydruku powodują oznaczenie częściowego wyniku. Uśpiony komputer nie zapisuje odczytów; wcześniejsze luki nie są odzyskiwane.

W historii sprawdź kolumnę energii i opis źródła. Wpis z pomiarem może otworzyć zapisany wykres przez dwukrotne kliknięcie.

## Pobierz dane

- W statystykach przy wydruku użyj ikony pobierania raportu TXT.
- W historii użyj eksportu CSV dla listy wydruków.
- Raport obejmuje nazwę zadania, drukarkę, wynik, czas, filament, energię i koszty, gdy dane są dostępne.

Raport nie zawiera oryginalnej geometrii ani ścieżki G-code. Nieznane zużycie filamentu nie oznacza 0 g, a oszacowana cena sprzedaży zależy od wprowadzonych parametrów wyceny.

W CSV `kWh` opisuje cały wynik, `meter_kWh` zmierzony fragment, `energy_source` źródło, a `meter_coverage` pokrycie. To pozwala odróżnić pomiar od szacunku poza aplikacją.
