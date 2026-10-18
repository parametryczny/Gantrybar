# Rozwiązywanie problemów

[English](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Troubleshooting-EN.md) · [Spis treści](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

Zanim zmienisz konfigurację, zapisz wersję Gantry, system, nazwę widoku i sposób odtworzenia problemu. W zgłoszeniu pomiń hasła, kody dostępu, klucze mostu i zdjęcia, których nie chcesz udostępniać.

## Nie ma Spoolbase, statystyk lub szczegółów

Sprawdź **LITE** w Zaawansowanych. Dla samego Spoolbase sprawdź także jego przełącznik w Ogólnych. Osobny instalator LITE nie zawiera narzędzi pełnej edycji. Sama informacja „wersja 0.12” nie rozstrzyga, czy zniknęło menu, czy dane.

Nie usuwaj plików magazynu jako pierwszego kroku. Napisz, czy brakuje pozycji menu, czy otwiera się puste okno.

## Nie ma procentu lub gramów filamentu

Sprawdź, czy slot ma odczyt z drukarki lub przypisaną rolkę Spoolbase. Nie każdy filament i moduł raportuje pozostałą ilość. Nieznana wartość jest inną sytuacją niż pusta rolka.

Jeśli chodzi tylko o niewidoczne EXT, sprawdź przełącznik w **Edytuj drukarkę** lub **Szczegóły → Filamenty / AMS**.

## Wykres lub energia są puste

Sprawdź wybrany okres oraz dostępność zapisanych danych. Dla pomiaru prądu potrzebne jest gniazdko z odczytem watów i działające Gantry. Brak wykresu po świeżym uruchomieniu nie dowodzi awarii; potrzebne są odczyty. Wydruk rozpoczęty wcześniej może mieć tylko częściowy pomiar.

Przy brakującej karcie lub ostatnim rzędzie podaj rozmiar okna, szablon Basic/Modern i liczbę drukarek. Nie zmieniaj danych historii, aby naprawić układ.

## Farma odrzuca plik lub start

Sprawdź, czy plik jest pocięty, rodzaj drukarki, średnicę dyszy, wybraną płytę i każde źródło materiału. **Sprawdź wybór** pokaże brakujące warunki. Przypisanie koloru nie zamienia PLA w PETG ani profilu jednej drukarki w profil innej.

## WWW działa w Wi-Fi, ale nie poza nim

Adres lokalnego komputera działa tylko w osiągalnej sieci. Dostęp poza Wi-Fi wymaga własnego hostingu i włączonego mostu. Sprawdź [Panel WWW](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Web-dashboard-PL.md), stan synchronizacji i czy komputer nie śpi.

JSON „Zaloguj się.” po logowaniu pod `api.php?action=login` może wskazywać starsze pliki logowania. Podmień komplet aktualnych plików strony, zachowaj konfigurację i dane, po czym zaloguj się ponownie. Nie generuj nowego klucza w ramach przypadkowego „czyszczenia cache”.

## Kamera lub Vision nie działają

Sprawdź kamerę w szczegółach, oświetlenie, połączenie i komunikat o modelu. ONNX wymaga zgodnego `model.json` i runtime. Własny plik modelu musi mieć format obsługiwany przez wybraną instalację Gantry. Oznacz fałszywy alarm według tego, co rzeczywiście widać, bez przypisywania awarii zasłoniętej klatce.

## Dane do zgłoszenia

- system i wersja Gantry; pełna edycja czy osobna LITE;
- szablon oraz rozmiar okna;
- typ drukarki, widok i wybrany okres;
- dokładny komunikat i kroki odtworzenia;
- zrzut po usunięciu danych prywatnych.
