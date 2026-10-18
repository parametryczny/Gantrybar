# Konserwacja i serwis floty

[English](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Maintenance-EN.md) · [Spis treści](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

Moduł jest dostępny w pełnej aplikacji Gantry: menu Gantry → **Konserwacja i serwis…**, boczna nawigacja → Konserwacja lub ikona konserwacji na karcie drukarki. Nie jest dostępny w trybie LITE. Nowe formularze serwisu nie są dostępne w panelu WWW.

- **W serwisie** — ręczny status dla każdej drukarki. Farma pomija ją przy wyborze, odmawia nowych wysyłek, przypisania kopii i startu. Włączenie serwisu wyłącza zgodę kolejki na automatyczny start; wyłączenie serwisu nie przywraca jej automatycznie. Bieżący wydruk nie jest zatrzymywany.
- **Zadania i szablony** — własne nazwy i checklisty, zadania jednorazowe lub cykliczne, opcjonalne zastosowanie do wszystkich drukarek. Szablon zapiszesz podczas tworzenia zadania. Przed zapisaniem wykonania trzeba zaznaczyć wszystkie kroki. Zarchiwizowane zadania można przywrócić.
- **Harmonogramy** — godziny druku i/lub dni kalendarzowe; obowiązuje wcześniejszy termin. Przy wykonaniu oba liczniki zaczynają kolejny cykl. Dotychczasowe zadania godzinowe i historia pozostają zachowane. Istniejące zadania zachowują też opcję odłożenia przypomnienia o siedem dni.
- **Problemy** — opis, notatka, priorytet, zdjęcie i status: otwarty, w trakcie lub rozwiązany. Ostrzeżenie Vision tworzy problem dopiero po potwierdzeniu defektu przez użytkownika; samo przewidywanie modelu tego nie robi.
- **Historia** — wspólna chronologia starych i nowych wpisów. Nowe wykonanie może zawierać notatkę, licznik godzin, checklistę, koszt oraz zużytą część. Historyczne ceny i nazwy części nie zmieniają się przy późniejszej edycji magazynu.
- **Części** — nazwa, ilość, minimum i koszt jednostkowy. Przy zapisie wykonania można wybrać jedną pozycję części oraz ilość; stan maleje razem z zapisem historii. Brak wystarczającego zapasu blokuje zapis. Pozostałe koszty wpisuje się osobno.

Na szerokim widoku zadania i historia są obok siebie; na wąskim układają się pionowo. Lista drukarek, wyszukiwanie i filtr wymagających uwagi ułatwiają obsługę floty. Części i szablony otworzysz z sekcji zarządzania serwisem.

Dane serwisu zapisują się lokalnie, oddzielnie od wcześniejszych danych konserwacji i telemetrii. Zdjęcia są kopiowane do lokalnego katalogu danych Gantry. Nie następuje automatyczna zmiana etykiet Vision, ponowne uczenie modelu ani wysyłanie zdjęć.

## Liczniki i wcześniejsze dane

Godziny pracy pochodzą z danych obserwowanych przez Gantry. Aplikacja wyłączona lub odłączona od drukarki nie odtworzy pełnej historii jej życia. Odłożenie przypomnienia nie zapisuje wykonania konserwacji.

Poprzednia historia pozostaje zachowana; nowe wpisy obejmują checklisty, problemy i części. WWW uwzględnia stan serwisowy przy zgodności Farmy, ale nie daje nowych formularzy serwisowych.
