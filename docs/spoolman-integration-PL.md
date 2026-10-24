# Spoolman w Gantry

Lokalna integracja rozwojowa, dodana po wydaniu 0.14.0. Dokument opisuje nowy kod; nie oznacza aktualizacji instalatorów opublikowanego wydania.

## Włączenie

1. Otwórz **Ustawienia → Ogólne → Magazyn: Spoolbase / Spoolman…**.
2. Wybierz **Spoolman**, wpisz adres serwera, np. `http://spoolman.local:7912`. Końcówka `/api/v1` jest opcjonalna.
3. Jeśli Twój reverse proxy wymaga tokenu Bearer, wpisz go w polu tokenu. Sam standardowy Spoolman nie wymaga tego tokenu. Puste pole zachowuje poprzedni sekret dla tego adresu.
4. Kliknij **Sprawdź połączenie**, a następnie **Zapisz i uruchom ponownie**. Możesz też użyć **Zapisz** i uruchomić Gantry ponownie ręcznie. Zmiana źródła, adresu lub sposobu rozliczania wymaga restartu.

Spoolman zastępuje lokalny magazyn w widokach, przypisaniach AMS/EXT, kalkulacji z przypisanej szpuli i panelu WWW. Lokalne dane Spoolbase pozostają zachowane. Ich zawartość nie jest używana jako zastępstwo podczas awarii serwera.

Gantry odświeża magazyn co około 15 sekund. Przy awarii pokazuje ostatni zapisany stan z komunikatem o braku połączenia. Podstawowe dodawanie i edycja są dostępne bezpośrednio w Gantry; usuwanie i pozostałe funkcje pozostają pod **Edytuj w Spoolmanie**. Przypisanie do slotu w Gantry jest lokalnym powiązaniem, nie poleceniem zmiany lokalizacji na serwerze.

## Szpule, AMS i tagi

- Produkt/filament i fizyczna szpula mają różne identyfikatory. Dwie identyczne szpule nie zostaną połączone w jedną.
- Każdy serwer ma osobny magazyn podręczny. Zachowuj stały adres serwera; zmiana aliasu adresu tworzy osobne źródło.
- Automatyczne przypisanie wymaga jednego, dokładnie pasującego identyfikatora tagu zapisanego w Spoolmanie (`tags[].uid` lub dodatkowe pole `tag`). Gantry porównuje identyfikator przekazany przez drukarkę; nie odczytuje dowolnych naklejek NFC telefonem.
- Kolor i typ materiału nie wystarczają do rozpoznania konkretnej szpuli. Dla materiałów bez pasującego tagu wybierz szpulę ręcznie w slocie AMS/EXT.
- Możesz ręcznie przypisać inną szpulę lub odpiąć obecną także wtedy, gdy slot odczytuje RFID. Ręczny wybór pozostaje zapisany po odczytach drukarki, odświeżeniu magazynu i restarcie. Odpięcie nie usuwa szpuli ani jej wagi w Spoolmanie. Dopiero inny, niepusty tag ponownie włącza automatyczne dopasowanie dla tego slotu.
- Zmiana zaobserwowanego tagu usuwa powiązanie z poprzednim tagiem. Sam brak tagu nie jest wiarygodnym dowodem wyjęcia szpuli bez RFID; takie przypisanie trzeba skorygować ręcznie.
- Zakończenie wydruku nie usuwa szpuli. Brak wagi nie oznacza pustej szpuli: wyświetlany jest znak „—”. Puste i zarchiwizowane szpule są zachowywane.

## Dodawanie i edycja w Gantry

W aktywnym oknie **Spoolman** dostępne są:

- **Dodaj filament…** — definicja produktu: nazwa, materiał, producent z listy Spoolmana (lub bez producenta), kolor z palety albo HEX, gęstość, średnica, pełna waga netto i opcjonalna cena.
- **Dodaj szpulę…** — fizyczna rolka istniejącego filamentu, także takiego, który nie ma jeszcze szpul. Możesz podać początkową i pozostałą wagę netto, tarę, cenę i lokalizację. Kolejna rolka dostaje nowy identyfikator.
- **Edytuj filament…** przy szpuli — zmienia wspólną definicję jej filamentu. Nazwa, materiał i kolor dotyczą wszystkich jego szpul. Samo poprawienie nazwy nie usuwa ustawień wielokolorowych; jawna zmiana koloru zastępuje je jednym kolorem.
- **Koryguj wagę…** przy szpuli — ustawia pozostałe gramy tylko tej fizycznej rolki. Wpisuj **wagę samego filamentu, bez pustej szpuli**. Dla nieznanej wagi początkowej wpisz ją w formularzu; pozostała nie może jej przekraczać.

Cena jest kwotą w walucie skonfigurowanej w Spoolmanie. Gantry jej nie przelicza. Puste opcjonalne pole ceny oznacza brak ceny, nie zero.

Przycisk **Zapisz w Spoolmanie** wykonuje zapis na serwerze i odświeża magazyn. Ręczne operacje działają także przy wyłączonym automatycznym raportowaniu zużycia. Nie zmieniają kodu ani koloru RFID w drukarce. Zapis dotyczy tylko edytowanych pól; dodatkowe metadane, tagi, historia i pozostałe ustawienia pozostają zachowane. Zmiana początkowej lub pozostałej wagi może przeliczyć sumaryczną wagę zużytą po stronie Spoolmana.

Serwer lub proxy musi dopuszczać zapis. Błąd połączenia lub odmowa zapisu nie tworzą lokalnego zamiennika. Jeśli potwierdzenie zapisu zaginie, Gantry nie ponawia żądania i blokuje ponowny zapis w tym formularzu: zamknij go, odśwież i sprawdź dane, zanim spróbujesz ponownie.

## Kto rozlicza zużycie?

**Gantry rozlicza zużycie w Spoolmanie** jest domyślnie wyłączone.

| Sytuacja | Ustawienie |
| --- | --- |
| Zużycie zgłasza Moonraker, Bambuddy, HaspelSync albo inne Gantry | Wyłączone — Gantry odczytuje magazyn i zachowuje własną historię |
| To Gantry ma zgłaszać zużycie przypisanych szpul | Włączone tylko w jednym egzemplarzu Gantry |

Gantry korzysta z dotychczasowego rozliczenia wydruku i przypisania konkretnej szpuli. Nie wymyśla zużycia, gdy brak wystarczających danych lub przypisania. Integracja nie wprowadza dokładności 0,1 g ani automatycznego ważenia.

Przed żądaniem zapisu Gantry zapisuje lokalnie zamiar rozliczenia. Powtórne zgłoszenie tego samego wydruku jest blokowane. Jeśli odpowiedź serwera zaginie, wynik jest oznaczony jako niepewny i **nie jest automatycznie ponawiany**. Sprawdź wtedy zużycie w Spoolmanie; ewentualną korektę wykonaj na serwerze. Nie włączaj równocześnie drugiego narzędzia odejmującego te same gramy.

Ceny są używane w walucie wybranej w Gantry, bez przeliczenia kursów. Ujednolić trzeba walutę i podstawę kosztów netto/brutto w obu systemach.

## Przeniesienie danych do Spoolbase

Można wykonać import także bez włączania Spoolmana jako aktywnego źródła:

1. Wpisz adres w konfiguracji magazynu i wybierz **Importuj do Spoolbase…**.
2. Sprawdź liczbę nowych szpul i potwierdź import.
3. Aby dalej korzystać wyłącznie z Gantry, wybierz **Spoolbase**, zapisz i uruchom aplikację ponownie.

Import jest jednostronny i dodaje nowe produkty oraz szpule. Zachowuje wagi, ceny, tagi, daty, tekst lokalizacji, archiwizację i metadane źródłowe. Nie przelicza walut i nie odtwarza historycznych wydruków. Przypisania AMS/EXT wybierzesz ponownie. Powtórny import z tego samego adresu nie dubluje danych i nie nadpisuje lokalnych korekt.

Przed importem powstaje kopia produktów, szpul i lokalnych zdarzeń zużycia w katalogu `Spoolman-import-backups` danych aplikacji. Serwer Spoolmana nie jest zmieniany.

## Zakres i testy

Wdrożenie obejmuje macOS, Windows, Linux i projekcję danych panelu WWW. Testy używają osobnej instalacji Spoolman 0.27.0 i fikcyjnych szpul. Nie potwierdzają jeszcze pracy na fizycznej farmie użytkownika ani automatycznej współpracy z zewnętrznymi narzędziami raportującymi zużycie.

HaspelSync oraz bambulab-spoolman posłużyły jako odniesienia do zachowania integracji, bez kopiowania ich kodu. Osobne połączenie z API Bambuddy nie jest częścią tej integracji.
