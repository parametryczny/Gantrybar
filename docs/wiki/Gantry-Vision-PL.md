# Gantry Vision: obserwacja i dane do oceny

[English](https://github.com/parametryczny/Gantrybar/wiki/Gantry-Vision-EN) · [Spis treści](https://github.com/parametryczny/Gantrybar/wiki/Home)

Vision obserwuje obraz podczas drukowania i zgłasza podejrzenie problemu. Wynik jest wskazówką do sprawdzenia wydruku, nie potwierdzeniem jego jakości.

## Włącz obserwację

1. Otwórz szczegóły drukarki i sprawdź kamerę oraz oświetlenie.
2. W **Ustawieniach → Zaawansowane** włącz pilnowanie wydruków.
3. Ustaw odstęp obserwacji i czułość, jeśli te opcje są dostępne.
4. Sprawdź pierwsze zgłoszenia na rzeczywistych wydrukach. Zbyt ciemny lub zasłonięty obraz nie daje wiarygodnej oceny.

Ostrzeżenia wymagają powtórzenia obserwacji. Na wiarygodność wyniku wpływają jakość obrazu, oświetlenie, ustawiona czułość i odstęp między obserwacjami.

## Wybór modelu

Domyślny **Gantry Vision Fast** jest dostarczany z aplikacją. **Inny plik…** pozwala wskazać własny model w formacie obsługiwanym przez daną instalację. Nazwa i zalecana czułość pochodzą z metadanych. Gantry zgłasza brak zależności lub niepoprawny model.

Własny model ONNX wymaga zgodnych metadanych `model.json`: wejścia RGB NCHW 224 × 224 oraz listy etykiet. Nie każdy plik ONNX jest zgodny z adapterem. Bank porównań z oznaczonymi klatkami i wagi modelu to osobne źródła informacji.

Eksperymentalne wagi nie są automatycznie pobierane lub dodawane do instalatora. Nie ma potwierdzonej uniwersalnej dokładności procentowej dla Twojej kamery.

## Oznaczaj to, co widać

W szczegółach użyj **Zaznacz defekt… / Mark defect…** i wybierz rzeczywistą etykietę. Poprawny wydruk jest równie przydatny jak awaria. Gdy głowica zasłania model, lepiej oznaczyć jednoznaczną klatkę niż zgadywać.

Ręczna etykieta pozostaje odróżniona od przewidywania modelu. Zapis lub eksport danych nie zmienia automatycznie wag sieci. Porównywanie z lokalnymi klatkami jest osobnym mechanizmem i nie oznacza treningu wag.

## Archiwum i ocena

**Eksportuj dane Vision…** zapisuje ZIP z obserwacjami i oznaczonymi zdjęciami. Limit lokalnego archiwum ustawisz w Zaawansowanych. Najstarsze dane mogą zostać usunięte po przekroczeniu limitu.

Przy aktywnej obserwacji mogą powstać zdjęcia pierwszej warstwy, 25%, 50%, 75% i końca. Dołączenie do wydruku w połowie nie odtwarza brakujących wcześniejszych etapów. Zdjęcie końcowe to ostatnia dostępna klatka, także przy przerwaniu.

Porównuj liczbę fałszywych alarmów na godzinę druku i trafienia na potwierdzonych awariach, a nie sam wynik pewności modelu. Nie opisuj `finished` jako ręcznie potwierdzonego „wydruku bez wad”.

Analiza i archiwum działają lokalnie. Osobno włączony podgląd kamer na własnym hostingu może przesyłać obraz do tego hostingu; jest to funkcja WWW, nie trening Vision.

## Wbudowane modele i potwierdzone problemy

Domyślny **Gantry Vision Fast** ma klasy `ok`, `spaghetti` i `detached`. Poprzedni Gantry Vision pozostaje na liście modeli. **Inny plik…** wskazuje własny zgodny model, a zalecany próg czułości pochodzi z metadanych modelu. Rzeczywiste oderwania nie mają jeszcze niezależnej walidacji; klasa korzysta z przykładów syntetycznych.

Lokalne warianty próbne, w tym Infill, wymagają osobnego wyboru pliku. Wynik z własnego zestawu klatek nie stanowi uniwersalnej dokładności modelu i nie zmienia automatycznie modeli w instalatorze.

Potwierdzenie defektu przez użytkownika może utworzyć problem ze zdjęciem w **Konserwacji i serwisie**. Sam alarm modelu nie tworzy zgłoszenia. Odróżnia to decyzję człowieka od przewidywania.

## Orientacja kamery Moonrakera

Gantry respektuje teraz obrót 0°/90°/180°/270° oraz odbicia poziome i pionowe zapisane w konfiguracji kamery Moonrakera. Orientacja jest stosowana przed udostępnieniem klatki pozostałym podglądom i zdjęciom, w tym dla WWW oraz narzędzi korzystających z kamery. Poprawka rozwiązuje pomijanie konfiguracji, które mogło pokazywać np. Artillery do góry nogami; bez zapisanych ustawień aplikacja nie zgaduje obrotu według marki.

Wbudowany Fast ONNX ma normalizację ImageNet w grafie. Adapter podaje RGB / 255 bez drugiej normalizacji (`input.normalization: embedded`). Własny model musi mieć prawidłowe metadane normalizacji. Zgodność techniczna formatu nie jest pomiarem skuteczności rozpoznawania awarii.


## Ciemna komora i zdjęcia w alarmach

Informacja o zbyt ciemnej kamerze dotyczy aktywnego druku po rozpoczęciu warstw. Znika po pauzie, zakończeniu, przerwaniu, zmianie zadania lub odzyskaniu czytelnego obrazu. Nie kasuje innych ostrzeżeń.

Powiadomienie Vision może zawierać dokładnie tę klatkę, która wywołała alarm. Zdjęcia w powiadomieniach włączysz osobno dla drukarki. Kamerę zewnętrzną skonfigurujesz w [Ustawieniach i narzędziach drukarki](https://github.com/parametryczny/Gantrybar/wiki/Printer-tools-PL).
