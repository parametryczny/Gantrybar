# Spoolbase: magazyn, rolki i etykiety

[English](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Spoolbase-EN.md) · [Spis treści](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Dwie rzeczy, które warto rozróżnić

| Element | Co zapisuje |
| --- | --- |
| rodzaj filamentu | marka, seria, materiał, kolor, kod produktu |
| fizyczna rolka | tożsamość konkretnej szpuli, waga, pozostały filament, cena i położenie |

Gramy należą do rolki. Po przełożeniu jej do innej drukarki przypisz tę samą rolkę do nowego slotu, zamiast tworzyć kolejną.

## Dodawanie i przypisywanie

1. Otwórz Spoolbase z menu Gantry i wybierz **＋**.
2. Wybierz produkt z katalogu lub wpisz własny.
3. Podaj liczbę rolek, wagę i cenę, jeśli ją znasz.
4. Na karcie drukarki kliknij slot i przypisz fizyczną rolkę.

Dane z tagu RFID i przypisanej rolki nie zawsze są tym samym odczytem. Brak procentu lub gramów może oznaczać brak pomiaru. Gantry nie powinien zamieniać nieznanej ilości w 0 g.

## Import zamówienia

Kliknij **Importuj zamówienie…**, wklej tekst lub odczytaj obraz, a następnie rozpoznaj pozycje. Sprawdź materiał, kolor, ilość, wagę oraz **cenę za jedną rolkę** przed dodaniem. Rozpoznanie pozycji samo nie zapisuje magazynu.

OCR działa lokalnie i wymaga zainstalowanych zależności rozpoznawania tekstu. Tekst zamówienia można też wkleić ręcznie. Nie traktuj automatycznie rozpoznanej ceny całej pozycji jako ceny jednej szpuli.

## Palety i profile

Paleta w edytorze wykorzystuje katalog producenta, z zestawem podstawowym dla nieznanej marki. Kliknięcie koloru uzupełnia nazwę i HEX.

Jawny odczyt folderu `profiles` slicera podpowiada nazwy serii. Nie odczytuje kolorów, których w tych profilach nie ma, i nie zastępuje katalogu Gantry.

## Etykieta QR

Z menu filamentu wybierz **Drukuj etykietę…**. Etykieta 62 × 37 mm identyfikuje **rodzaj filamentu**, nie konkretną fizyczną rolkę. Nie zapisuje kodu dostępu do drukarki.

Etykietę można wydrukować lub zapisać jako PDF. Zeskanowany kod Gantry otwiera zapisany rodzaj filamentu, jeśli znajduje się w Twoim magazynie.

Jeśli Spoolbase znika z menu, sprawdź **LITE** i przełącznik Spoolbase w **Ustawieniach → Ogólne**. Nie usuwaj magazynu.

## Osobny widok AMS / Filamenty

W menu Gantry lub bocznej nawigacji otwórz **AMS / Filamenty**, wybierz drukarkę i kliknij slot. Kolorowe pola pokazują materiał, procent i gramy, jeśli są dostępne, oraz strzałkę aktywnego slotu. Moduły mogą pokazywać temperaturę i wilgotność.

Szczegóły slotu pozwalają sprawdzić powiązaną rolkę i przy włączonym Spoolbase wybrać **Przypisz rolkę…** lub **Zmień przypisanie…**. Przełącznik EXT ukrywa zewnętrzne źródła tej drukarki także w WWW.

Ręcznie przypisana rolka bez raportowanego materiału nie wraca do magazynu tylko z powodu braku odczytu. Automatyczne rozpoznanie wyjęcia wymaga wcześniejszego zobaczenia filamentu w tym przypisaniu oraz utrzymującego się pustego slotu.

## Stan AMS i rozliczenie wydruku

Naprawiono rozliczanie szpul: odczyt pozostałości z AMS i gramy slicera nie zmniejszają już stanu dwukrotnie. Dla rozpoznanej szpuli z poprawnym odczytem AMS zapisuje się źródło stanu, również na czas restartu; zużycie slicera nadal trafia do historii i kosztów. Bez takiego odczytu działa zwykłe odejmowanie. Odczyt 0 g poprawnie oznacza pustą rolkę. Dodano automatyczne przypisanie dokładnie jednej pasującej rolki bez RFID; przy kilku kandydatkach potrzebny jest wybór ręczny. Podczas przerwy w odczytach AMS prezentowany jest ostatni znany stan.
