# Farma: od pliku do wydruku

[English](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Farm-EN.md) · [Spis treści](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Przygotuj bibliotekę

1. W Farmie wybierz **Wybierz katalog…**, np. `Downloads/farma`.
2. Gantry tworzy podfoldery `X2D`, `X1`, `P1`, `P2`, `MINI` i `A1`.
3. Umieść pliki w odpowiednim folderze i kliknij **Odśwież** listę plików. Pliki z głównego katalogu mogą pozostać bez przypisania do rodziny.
4. Kliknij plik na liście. W środku zobaczysz płytę, podgląd i dane ze slicera.

Folder nie zmienia profilu pociętego pliku. Przeniesienie 3MF do folderu X2D nie przygotowuje go automatycznie dla X2D.

## Wybierz drukarki i materiał

1. Zaznacz zgodne drukarki.
2. Wybierz płytę i otwórz materiały wybranej drukarki.
3. Użyj **Dobierz AMS** albo wskaż źródło dla każdego materiału ręcznie.
4. Sprawdź materiał, kolor i ilość filamentu. Brak pomiaru wagi nie potwierdza, że rolka wystarczy.
5. Użyj **Sprawdź wybór** i popraw zgłoszone braki.

Jawny dobór AMS nie wybiera szpuli zewnętrznej po cichu. Wybór źródła jednej drukarki nie ustawia automatycznie źródeł wszystkich pozostałych.

## Wysyłanie, start i kolejka

**Wyślij plik** przesyła plik. Sam transfer nie rozpoczyna druku. Start wykonujesz osobno po potwierdzeniu przygotowania stołu i profilu.

Kolejka działa inaczej: dopuszczasz przygotowaną drukarkę do jednej kopii, a Gantry wysyła zgodne zadanie i może je uruchomić. Po zdjęciu wydruku potwierdź pusty stół ponownie.

| Plik | Cel |
| --- | --- |
| pocięty 3MF | obsługiwane drukarki Bambu Lab |
| tekstowy G-code | obsługiwane Klipper, PrusaLink, OctoPrint |
| BG-code | obsługiwany PrusaLink; bez tekstowej zmiany narzędzi |

Zmiana narzędzi G-code obejmuje obsługiwane polecenia `T<n>`, `M104` i `M109` w roboczej kopii. Nie jest konwerterem profili drukarek. Plik z sumami kontrolnymi wymagający zmiany trzeba ponownie wyeksportować.

## Usuń plik i oryginał

Opcja usuwania może przenieść zapisany oryginał do kosza i usunąć wpis biblioteki. Jeśli plik jest w aktywnym zadaniu/kolejce albo oryginał zmienił się od importu, operacja zostanie odrzucona. Starszy import bez zapisanej ścieżki trzeba najpierw ponownie zaimportować.

## Nowy układ produkcji

Farma ma pięć widoków: **Przygotowanie**, **Kolejka**, **Odbiór i jakość**, **Zamówienia** i **Historia**. W przygotowaniu po lewej znajduje się lista plików z wyszukiwarką i filtrem katalogu, pośrodku drukarki, a po prawej materiały wybranej drukarki. Sześć drukarek mieści się w dwóch kolumnach bez przewijania listy przy standardowym szerokim oknie. Przy węższym oknie sekcje przechodzą do kolejnych wierszy.

Wyszukiwanie działa od razu, łączy kilka słów i nie wymaga wpisywania polskich znaków. Filtr katalogu nadal obowiązuje. Wyszukiwarka jest również dostępna w panelu WWW.

**Dodaj do kolejki** tworzy plan partii i rezerwacje materiałów; samo dodanie nie wysyła pliku ani nie uruchamia druku. Plan rozdziela kopie między wybrane zgodne drukarki, uwzględnia ich obecne obciążenie i wcześniejsze rezerwacje. Nieznana masa szpuli pozostaje nieznana — trzeba sprawdzić ją przed startem. Rezerwacja nie odejmuje filamentu ze Spoolbase. Nie ma automatycznego cięcia ani zgadywania zgodności plików z innym modelem drukarki.

W **Kolejce** można zmieniać kolejność, wstrzymywać, wznawiać lub usuwać oczekujące partie. Potwierdzenie pustego, przygotowanego stołu zezwala na **jeden** start; po restarcie programu zgoda nie jest zachowywana. Osobna wysyłka pliku nadal nie oznacza rozpoczęcia druku. Wstrzymane partie rezerwują materiał, ale ich termin zakończenia jest nieznany.

Po ukończeniu wydruku:

1. Potwierdź zdjęcie wydruku i pusty stół.
2. Oceń jakość: zaakceptuj kopię lub podaj powód ponownego druku.
3. Odrzucona kopia nie realizuje zamówienia; jej zamiennik trafia do kolejki jako wstrzymany. Odbiór ani ocena nie zezwalają samoczynnie na kolejny start.

Zamówienie ręczne wiąże numer, SKU, pocięty plik, płytę, liczbę kopii i opcjonalny termin. **Ilość oznacza kopie płyty, nie liczbę modeli na niej.** Zrealizowaną ilość zwiększają wyłącznie zaakceptowane kopie. Przygotowanie brakującej ilości uwzględnia już zaplanowane, drukowane i oczekujące na ocenę kopie. WooCommerce i Etsy są planowanymi integracjami; nie ma jeszcze połączenia ze sklepami.

Historia produkcji jest kompaktową listą i pozwala eksportować CSV z danymi zadania oraz oceną jakości. Filament opisany jako „wg slicera” jest przewidywanym zużyciem, nie pomiarem. Pełne raporty kosztów i energii pozostają w statystykach floty.
