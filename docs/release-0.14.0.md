# Gantry 0.14.0

**[Polski](#polski)** · **[English](#english)**

## Paczki / Downloads

| System | Pliki / Files |
| --- | --- |
| macOS Universal (Apple Silicon + Intel) | DMG, Local ZIP, Keychain ZIP |
| Windows 10/11 x64 | instalator / installer PL/EN, portable ZIP — r3 |
| Linux x86_64 | DEB, RPM, AppImage |
| Dokumentacja / Documentation | PL/EN Wiki + instrukcje instalacji / installation guides |

Szczegóły instalacji / Installation details: [PL](https://github.com/parametryczny/Gantrybar/wiki/Installation-PL) · [EN](https://github.com/parametryczny/Gantrybar/wiki/Installation-EN). Sumy dołączonych plików / Attached asset checksums: `SHA256SUMS.txt`.

## Polski

Gantry 0.14.0 łączy zwarty interfejs Modern, przebudowaną Farmę, czytelniejszą obsługę AMS i Spoolbase, rozbudowany serwis floty oraz energię i koszty każdego wydruku. Nowe narzędzia drukarek obejmują kamerę zewnętrzną, zdjęcia w powiadomieniach, skrót do panelu WWW, własny przycisk HTTP i zapasowy adres API.

Aplikacja nie wymaga konta ani chmury producenta Gantry. Drukarki obsługuje lokalnie; opcjonalny panel internetowy działa na Twoim hostingu.

### Najważniejsze zmiany

- **Gantry Basic i Gantry Modern.** Dwa szablony kart, zwarte odczyty i spójne nagłówki całej aplikacji.
- **Nowa Konserwacja i serwis.** Status „W serwisie”, własne zadania i checklisty, szablony, terminy godzinowe i kalendarzowe, problemy ze zdjęciami, historia kosztów i magazyn części.
- **Osobny widok AMS / Filamenty.** Wybór drukarki, kolorowe sloty, aktywny podajnik, procent i gramy oraz przypisania rolek Spoolbase.
- **Farma: plik → drukarki → materiały.** Katalogi według typu drukarki, lista plików, dobór AMS, kontrola przed startem, kolejka i historia.
- **Energia całego cyklu.** Pomiar z obsługiwanych gniazdek w tle, wykres, kWh i koszty w historii.
- **Zwarte statystyki i eksport.** Raport przy nazwie wydruku oraz CSV całej historii.
- **Spoolbase: zamówienia, palety i etykiety.** Edytowalny import, lokalny OCR, kolory producentów i etykiety QR.
- **Wygodniejsza obsługa floty.** Światło we wszystkich obsługiwanych drukarkach, poprawione kliknięcia nagłówka i opcjonalne otwieranie paska bocznego dopiero po kliknięciu.
- **WWW na komputerze i telefonie.** Układ zgodny z aplikacją, generator paczki hostingowej, respektowanie ukrytego EXT i zapamiętanie logowania na 30 dni.
- **Narzędzia drukarek.** Zewnętrzna kamera, zdjęcia w powiadomieniach, panel WWW, własny GET/POST, zapasowy adres API i interwały odświeżania.
- **LITE w pełnej aplikacji.** Szybki powrót do samego podglądu stanu w pasku lub zasobniku, z zachowaniem danych pełnej wersji.

### Dopracowanie wydania — 20 października

- **Ustawienia, które od razu zmieniają widok.** Zaznaczenie „Pokaż AMS”, postępu i pozostałych odczytów odpowiada ich rzeczywistej widoczności. Poprawiono zapis opcji, odświeżanie kart i znaczniki checkboxów.
- **Czytelniejszy interfejs.** Mocniejszy kontrast pól i opisów, spójne menu, listy wyboru i przewijanie, wektorowe ikony oraz zachowanie stylów po otwarciu ustawień wewnątrz głównego okna.
- **Zaokrąglony pasek krawędziowy.** Zachowana przezroczystość poza obrysem; zamknięty panel nie próbuje ponownie otwierać się po zmianach drukarki.
- **Spoolbase w zwartym i rozwiniętym widoku.** Gramy, lokalizacja rozpoczętych rolek, dopasowanie kolumn i eksport magazynu TXT/CSV.
- **Kolor z drukarki ma pierwszeństwo.** Prawidłowy kolor załadowanego slotu AMS/EXT jest ważniejszy od zastępczego koloru Spoolbase. Różnica wskazuje na potrzebę sprawdzenia przypisanej rolki; nie zmienia automatycznie jej definicji i ceny.
- **Farma jest opcjonalna i domyślnie wyłączona.** Włączysz ją w Ustawieniach → Ogólne. Ukrycie modułu zachowuje pliki, kolejkę i zamówienia; nie ukrywa statystyk ani Spoolbase.
- **Wykres floty.** Wypełnienie zamyka się do poziomej podstawy, nie po skosie między pierwszym i ostatnim punktem. Wykres nie zwiększa wysokości kafla i nie zasłania przycisku „Więcej”.
- **Historia i eksport.** Poprawione otwieranie okien z osadzonych paneli, lista od początku i właściwe okno nadrzędne dla zapisu raportu.
- **Kamera per drukarka.** Obrót 0/90/180/270° oraz odbicia poziome/pionowe, dodatkowo do orientacji zapisanej w Moonrakerze.
- **Instalacja PL/EN i licencja MIT.** Instalator Windows ma wybór języka, opis instalacji i pełny tekst licencji. Oznaczenie wydawcy: `/parametryczny`. Licencja Gantry pozostaje MIT.

Poprawki Windows sprawdzono w 473 kontrolach interfejsu dla Basic/Modern, jasnego/ciemnego motywu i PL/EN, a także w teście instalacji, autostartu i odinstalowania z zachowaniem danych. Testy wykonano w Wine; nie są certyfikacją działania na każdym fizycznym komputerze ani gwarancją zgodności wszystkich urządzeń.

### Wygląd i codzienna obsługa

Nad ikoną Ustawień dodano **Ustawienia drukarek**. Wybierz urządzenie u góry, aby skonfigurować połączenie, widoczność EXT i pasków, kamerę, własne komendy światła, gniazdko, moc oraz amortyzację. Formularz zachowuje osobne robocze zmiany dla każdej drukarki. W trybie samego paska lub zasobnika ten widok otworzysz bezpośrednio z menu aplikacji. Pinezka pełnego okna zachowuje jego położenie na bieżącym monitorze.

- Ustawienia paska: kompaktowe kafelki wyboru drukarek i kamer zamiast pionowych list; nowy podgląd położenia z sześcioma punktami, podpisem i obsługą klawiatury.

Ustawienia mają wspólną skalę tekstu: nagłówki 14, etykiety i opcje 13, opisy 12. Dłuższe nazwy opcji zawijają się do pełnych wierszy. Ujednolicono odstępy i szerokości opisów, a zatłoczone wiersze limitu kamer i wyboru modelu Vision rozdzielono.

W **Ustawieniach → Wygląd** wybierzesz Gantry Basic lub Gantry Modern. Modern pokazuje nazwę drukarki i typ połączenia, stan, plik, postęp, pozostały czas, godzinę zakończenia, warstwy, temperatury i filament w zwartym układzie. Odczyty i ich widoczność zależą od drukarki oraz ustawień karty.

Nagłówki Farmy, Monitoringu, Diagnostyki, Spoolbase, Statystyk i pozostałych widoków korzystają ze wspólnego stylu Gantry. W trybie okna usunięto zbędny efekt „okna w oknie”. Sterowanie otrzymało spójniejsze nagłówki, przyciski i odstępy. Statystyki przenoszą listę plików obok podsumowania, gdy jest na to miejsce; węższe okna układają treść pionowo.

Z głównych kart Modern usunięto osobne skróty pauzy i lampki, zwalniając miejsce na stan drukarki. Sterowanie pozostaje dostępne w przeznaczonym do tego panelu.

Dopracowano odstępy górnych ikon i obsługę pierwszego kliknięcia: przyciski reagują również wtedy, gdy okno nie było aktywne. W **Ustawieniach → Okna i pasek** można włączyć **„Rozwijaj pasek dopiero po kliknięciu”**. Domyślnie pasek rozwija się po najechaniu; przypięty pozostaje rozwinięty.

Przycisk żarówki w nagłówku aplikacji pozwala wysłać **włącz lub wyłącz światło** do wszystkich połączonych drukarek, dla których Gantry obsługuje takie polecenie lub skonfigurowano własne polecenie LED. Zbiorcze sterowanie światłem jest też dostępne na hostingu, gdy włączono zdalne sterowanie; lokalny panel tylko do podglądu nie wysyła poleceń.

Poprawiono otwieranie historii od początku listy, uzupełnianie formularza „Edytuj drukarkę”, widoczność ostatniego rzędu kart — również MINI i statystyk — oraz rozmiar i wypełnienie wykresu floty. Drukarka bez aktywnego zadania pokazuje **„Czeka na wydruk”**.

### Narzędzia drukarek i powiadomienia

- Zewnętrzna kamera HTTP/HTTPS JPEG lub MJPEG przypisana do dowolnej drukarki; wspólny podgląd w szczegółach, monitoringu, pasku i istniejącym dostępie WWW.
- Zdjęcia w powiadomieniach; alert Vision pokazuje klatkę zgłoszenia. Przełącznik zdjęć per drukarka; wygląd powiadomienia zależy od ustawień środowiska.
- Skrót do panelu WWW i własny ręczny przycisk GET/POST z opcjonalnym JSON-em oraz tokenem Bearer w magazynie kluczy. Zapis nie wykonuje żądania.
- Zapasowy adres API oraz osobne interwały odświeżania podczas druku i w spoczynku dla PrusaLink, Moonrakera i OctoPrint. Sterowanie oraz transfery korzystają z wybranego adresu; brak automatycznego ponawiania poleceń pod drugim adresem.
- Instrukcja konfiguracji: [Ustawienia i narzędzia drukarki](https://github.com/parametryczny/Gantrybar/wiki/Printer-tools-PL).

### AMS / Filamenty i ukrywanie EXT

Dostępny jest osobny widok **AMS / Filamenty** z menu Gantry i bocznej nawigacji. Wybierz drukarkę, aby zobaczyć jej moduły i kolorowe pola slotów. Każdy slot pokazuje materiał, pozostały procent i gramy, gdy są dostępne; strzałka wyróżnia slot drukujący. Przy module są odczyty temperatury i wilgotności, jeśli drukarka je podaje.

Kliknięcie slotu otwiera szczegóły koloru, ilości i przypisanej rolki. Przy włączonym Spoolbase można przypisać rolkę lub zmienić jej przypisanie bez szukania slotu w karcie drukarki. Widok dopasowuje liczbę kolumn do szerokości i obsługuje raportowane moduły AMS/HT oraz źródła zewnętrzne.

**EXT można ukryć osobno dla każdej drukarki**: w „Edytuj drukarkę”, w szczegółach → „Filamenty / AMS” oraz przełącznikiem EXT w nowym widoku. Preferencja dotyczy wszystkich zewnętrznych źródeł tej drukarki i jest respektowana także w panelu WWW — lokalnym oraz na hostingu. Ukrycie zmienia prezentację; zachowuje fizyczne indeksy slotów, przypisania i zużycie filamentu.

### Farma: plik → drukarki → materiały

Folder farmy otrzymuje podkatalogi **X2D, X1, P1, P2, MINI i A1**. Biblioteka pokazuje pliki jako listę z odświeżaniem. Usunięcie z biblioteki może również przenieść zapisany oryginał do systemowego kosza; plik w aktywnym zadaniu lub kolejce nie zostanie usunięty tą operacją.

Po wybraniu pliku Gantry pokazuje jego podgląd, płytę, czas i materiały oraz zgodność drukarek. **Dobierz AMS** proponuje pasujące sloty; źródła można wybrać ręcznie. **Sprawdź wybór** pokazuje brak materiału, za małą ilość filamentu, niezgodną dyszę i przygotowanie stołu przed startem.

Materiały i wybór płyty są skupione w obszarze roboczym zamiast rozwijać formularz w każdej karcie. Do sześciu drukarek służy zwarta siatka 2 × 3; w małym oknie zawartość nadal może wymagać przewijania. Odświeżenie AMS zachowuje zaznaczenia i nadal dostępne przypisania.

Farma obsługuje pocięte 3MF dla Bambu Lab oraz G-code dla obsługiwanych drukarek Klipper, PrusaLink i OctoPrint. Zmiana kolejności narzędzi odbywa się w roboczej kopii tekstowego G-code. Oryginał pozostaje bez zmian; BG-code i pliki z sumami kontrolnymi wymagające takiej zmiany trzeba ponownie wyeksportować.

**Samo wysłanie pliku nie uruchamia druku.** Osobny start wymaga potwierdzeń. Kolejka może uruchomić kopię po jawnym dopuszczeniu przygotowanej drukarki.

#### Farma: przygotowanie, produkcja i jakość

- Nowy układ: lista plików, drukarki pośrodku i osobny inspektor materiałów. Sześć drukarek bez przewijania w standardowym szerokim oknie.
- Wyszukiwanie plików w aplikacji i panelu WWW; obsługa wielu słów, wielkości liter i polskich znaków wraz z filtrem katalogu.
- Osobne zakładki przygotowania, kolejki, odbioru i jakości, zamówień oraz historii.
- Plany partii uwzględniają wcześniejsze zadania i rezerwacje filamentu. Dodanie partii nie uruchamia druku; zgoda na pusty stół dotyczy jednego startu.
- Odbiór i kontrola jakości jako osobne kroki; odrzucona kopia tworzy wstrzymany ponowny druk z zapisanym powodem.
- Ręczne zamówienia z SKU, plikiem, płytą, liczbą kopii i terminem. Zliczanie zaakceptowanych kopii oraz ochrona przed podwójnym planowaniem. WooCommerce i Etsy pozostają planowanymi integracjami.
- Kompaktowa historia z eksportem CSV; respektowanie ukrytego EXT w inspektorach materiałów.

### Energia, koszty i historia

Tasmota i obsługiwane gniazdka Shelly z pomiarem mocy są odpytywane co około **5 sekund**. Cykl obejmuje przygotowanie zgłoszone jako aktywny wydruk, druk i pauzy, aż do zakończenia lub przerwania.

Raport rozróżnia:

| Źródło energii | Co oznacza |
| --- | --- |
| Pomiar | energia policzona z odczytów gniazdka |
| Pomiar częściowy | odczytany fragment oraz szacunek brakującego czasu |
| Szacunek | wynik ze skonfigurowanej średniej mocy drukarki |

Uśpienie komputera, zamknięcie aplikacji lub brak odczytów pozostawiają lukę, zamiast dopisywać fikcyjny pomiar. Brak informacji o zużyciu filamentu jest pokazywany jako brak danych — nie jako 0 g.

Raport TXT pojedynczego wydruku i CSV historii zawierają czas, filament, energię, źródło pomiaru i rozbicie kosztów. To raport danych zadania, **nie pobieranie oryginalnego pliku 3MF/G-code**. Lista „Pliki i wydruki” używa wierszy zamiast osobnych kart. Ikona pobierania przy nazwie zapisuje raport konkretnego zadania, a okno historii ma także eksport zbiorczy. W szerokim oknie podsumowanie kosztów i czasu pozostaje po lewej, lista wydruków po prawej.

### Spoolbase

Import zamówienia rozpoznaje materiał, produkt, kolor, ilość, wagę i cenę. Przed dodaniem sprawdzasz pozycje oraz **cenę jednej rolki**. Obraz jest odczytywany lokalnie przez OCR; rozpoznane pozycje można poprawić przed zapisem.

Paleta w edytorze podpowiada kolory z katalogu marki. Profile slicera można odczytać na własne żądanie, aby uzupełnić nazwy serii; nie zastępują one katalogu kolorów.

Etykiety **62 × 37 mm** zawierają kod QR identyfikujący rodzaj filamentu w magazynie. Etykietę można wydrukować lub zapisać jako PDF. Kod etykiety nie jest kodem dostępu do drukarki.

Poprawiono obsługę rolek przypisanych ręcznie do slotu, dla którego drukarka nie raportuje materiału: sam brak odczytu nie odsyła już rolki do magazynu. Rozpoznanie wyjęcia wymaga wcześniejszego zobaczenia filamentu w tym przypisaniu oraz utrzymującego się pustego slotu. Ukryty EXT nie przesuwa przypisań AMS/HT.

Naprawiono rozliczanie szpul: odczyt pozostałości z AMS i gramy slicera nie zmniejszają już stanu dwukrotnie. Dla rozpoznanej szpuli z poprawnym odczytem AMS zapisuje się źródło stanu, również na czas restartu; zużycie slicera nadal trafia do historii i kosztów. Bez takiego odczytu działa zwykłe odejmowanie. Odczyt 0 g poprawnie oznacza pustą rolkę. Dodano automatyczne przypisanie dokładnie jednej pasującej rolki bez RFID; przy kilku kandydatkach potrzebny jest wybór ręczny. Podczas przerwy w odczytach AMS prezentowany jest ostatni znany stan.

### WWW na telefonie i własnym serwerze

Gotowy ZIP strony nie jest dołączany do wydania. Wygeneruj własną paczkę WWW w Gantry — z adresem i konfiguracją swojego hostingu.

Na komputerze panel ma boczną nawigację; na telefonie — nawigację na dole i drukarki jedna pod drugą. Podgląd obejmuje również monitoring oraz, po włączeniu udostępniania, farmę, historię, koszty, Spoolbase i konserwację.

**Generuj paczkę WWW…** przygotowuje ZIP z aktualną stroną, adresem hostingu, kluczem mostu i hashem hasła. Klucz nie trafia do JavaScript. Generowanie paczki nie włącza synchronizacji ani nie publikuje strony.

Po wgraniu plików na hosting z PHP i HTTPS włączasz most w Gantry. To aplikacja inicjuje połączenie z hostingiem, więc ten tryb nie wymaga przekierowania portów na routerze. Panel lokalny i własny hosting to dwa różne sposoby dostępu.

Poprawiono logowanie formularzem i przekierowanie ze starszego adresu `api.php?action=login`, które mogło kończyć się widokiem JSON „Zaloguj się.”. Sesja jest zapisywana przed przejściem do panelu.

Opcja **„Zapamiętaj mnie na 30 dni”** zachowuje zalogowanie w danej przeglądarce. Bez niej sesja ma limit 12 godzin. Wylogowanie lub zmiana hasła unieważniają dostęp. Strona dodana do ekranu początkowego telefonu może korzystać z osobnego magazynu cookies i przy pierwszym uruchomieniu wymagać własnego logowania; później działa ten sam mechanizm zapamiętania.

Przeglądarka nadal pokazuje domenę w pasku adresu. Nazwa „Gantry” dotyczy tytułu strony i nazwy skrótu, nie zastępuje adresu w Safari. Zmiany strony wymagają aktualizacji plików na hostingu; aktualizacja samej aplikacji nie podmienia zdalnej instalacji.

### Gantry Vision i monitoring

Informacja o zbyt ciemnej kamerze dotyczy wyłącznie trwającego druku po rozpoczęciu warstw. Znika po pauzie, zakończeniu, przerwaniu, zmianie zadania lub odzyskaniu czytelnego obrazu, bez kasowania pozostałych ostrzeżeń.

Monitoring otrzymuje adaptacyjną siatkę kamer. Szczegóły, monitoring i pasek współdzielą obraz tej samej drukarki, aby otwarcie kolejnego widoku nie odbierało podglądu pozostałym. Zamknięcie widoku zwalnia jego własne odbiorniki.

Opcjonalne ograniczenie liczby klatek w większej flocie zmniejsza koszt podglądu kamer. Limit dotyczy ściany Monitoringu; szczegóły i pasek zachowują swój normalny podgląd. Strumienie H.264 wymagają szczególnego traktowania klatek kluczowych.

**Gantry Vision Fast** jest wbudowanym modelem domyślnym z klasami `ok`, `spaghetti` i `detached`. Można wybrać inny zgodny plik modelu. Nazwa i zalecany próg czułości pochodzą z metadanych. Klasa oderwania korzysta również z przykładów syntetycznych; skuteczność na rzeczywistych awariach wymaga dalszej weryfikacji.

Vision obsługuje ręczne oznaczanie klatek, archiwum obserwacji, odpowiedzi na alarmy i eksport ZIP. Potwierdzenie defektu przez użytkownika może utworzyć problem ze zdjęciem w module serwisowym; sam alarm modelu nie tworzy zgłoszenia.

Archiwum może zapisywać zdjęcia pierwszej warstwy, 25%, 50%, 75% i końca wydruku. Zdjęcie końcowe wykorzystuje ostatnią dostępną klatkę. Ręczna etykieta pozostaje oddzielona od przewidywania modelu; zapis lub eksport danych nie trenuje automatycznie wag sieci.

Lokalne próby nowych wag, w tym wariantu Infill ograniczającego alarmy na regularnym wypełnieniu, są osobnymi eksperymentami. Nie stanowią ogólnego wyniku dokładności i nie zastępują automatycznie modeli w instalatorze. Wybrany model, czułość i opcja automatycznej pauzy pozostają ustawieniami użytkownika.

Poprawiono rozpoznawanie odpowiedzi tunelu plikowego Bambu na porcie próbowanym jako kamera: taka odpowiedź nie jest już traktowana jak prawidłowy strumień obrazu. Ten przypadek otrzymuje właściwą diagnostykę zamiast długiego oczekiwania na klatkę.

Gantry respektuje teraz obrót 0°/90°/180°/270° oraz odbicia poziome i pionowe zapisane w konfiguracji kamery Moonrakera. Orientacja jest stosowana przed udostępnieniem klatki pozostałym podglądom i zdjęciom, w tym dla WWW oraz narzędzi korzystających z kamery. Poprawka rozwiązuje pomijanie konfiguracji, które mogło pokazywać np. Artillery do góry nogami; bez zapisanych ustawień aplikacja nie zgaduje obrotu według marki.

Poprawiono podwójną normalizację wejścia modelu Vision. Metadane `input.normalization: embedded` oznaczają wejście RGB / 255; starsze własne modele zachowują normalizację ImageNet, jeśli nie określono inaczej. Aktualizacja nie zmienia samoczynnie modelu wybranego przez użytkownika.

### Konserwacja i serwis — nowy moduł desktopowy

Z menu **Gantry → Konserwacja i serwis…**, bocznej nawigacji lub ikony konserwacji na karcie otworzysz wspólny widok floty. Podsumowanie pokazuje zadania do wykonania, drukarki w serwisie, otwarte problemy i części do uzupełnienia. Wybór drukarki, wyszukiwanie i filtr wymagających uwagi pomagają przejść do konkretnego urządzenia.

- **Status „W serwisie”.** Drukarka jest pomijana przy doborze Farmy. Gantry blokuje nowe wysyłki, przypisania kopii i starty. Włączenie serwisu wyłącza wcześniejszą zgodę kolejki na start; wyjście z serwisu nie przywraca jej automatycznie. Trwający wydruk pozostaje bez zmian.
- **Własne zadania i checklisty.** Nazwa, kroki, postęp oraz zadanie jednorazowe lub cykliczne. Zapis wykonania wymaga zaznaczenia wszystkich kroków. Zadania można edytować, archiwizować i przywracać.
- **Szablony.** Zapis checklisty i terminów jako szablonu do ponownego użycia; nowe zadanie można od razu przypisać wszystkim drukarkom.
- **Harmonogram godzinowy i kalendarzowy.** Podaj godziny druku, liczbę dni lub oba parametry — obowiązuje wcześniejszy termin. Wykonanie rozpoczyna następny cykl. Dotychczasowe zadania zachowują też odłożenie przypomnienia o siedem dni.
- **Rejestr problemów.** Tytuł, notatka, priorytet, zdjęcie oraz status otwarty / w trakcie / rozwiązany. Potwierdzony przez użytkownika defekt Vision może utworzyć zgłoszenie ze zdjęciem; samo przewidywanie modelu nie tworzy problemu.
- **Szczegółowa historia.** Data, godziny pracy, notatka, wykonana checklista, zużyta część i koszt. Stare i nowe wpisy są wspólnie uporządkowane chronologicznie.
- **Magazyn części.** Ilość, minimum i cena jednostkowa. Przy wykonaniu wybierzesz jedną pozycję części z ilością oraz dopiszesz inne koszty. Zapis historii i zmniejszenie stanu następują razem; niewystarczający zapas blokuje zapis. Późniejsza zmiana ceny części nie przelicza historycznego kosztu.

Widok dopasowuje się do okna: przy większej szerokości zadania i historia są obok siebie, przy mniejszej — pionowo. Dane i zdjęcia serwisu są przechowywane lokalnie, a wcześniejsze liczniki i historia pozostają zachowane.

Moduł serwisowy działa w pełnej wersji Gantry. Panel WWW uwzględnia stan serwisowy przy ocenie zgodności drukarek w Farmie; nowe formularze zadań, problemów i części otwiera się w aplikacji.

### Tryb LITE

W **Ustawieniach → Zaawansowane** przełącznik LITE uruchamia uproszczony tryb z podglądem stanu drukarek w pasku menu lub zasobniku. Szczegóły, sterowanie, statystyki, wycena, Farma, AMS jako osobny moduł, Spoolbase, serwis, kamery i integracje pełnej edycji są ukrywane. W ustawieniach pozostają podstawowe opcje i powrót do pełnego trybu. Zmiana wymaga ponownego uruchomienia aplikacji.

Zapisane drukarki, historia i magazyn nie są kasowane. Przełącznik w pełnej aplikacji nie zmniejsza rozmiaru jej pliku; osobny instalator LITE jest okrojonym wariantem i wymaga instalacji pełnej aplikacji, aby odzyskać jej narzędzia.

### Aktualizacja aplikacji i strony

Przy aktualizacji własnego hostingu zachowaj istniejący `config.php` i `data/`, a pliki strony aktualizuj razem. Nowy klucz lub hasło z nowo wygenerowanej paczki zmieniają konfigurację strony. Zachowanie istniejących danych nie włącza nowych zakresów udostępniania.

📚 [Wiki / instrukcje](https://github.com/parametryczny/Gantrybar/wiki) · ☕ [Wesprzyj Gantry](https://buycoffee.to/parametryczny)

### Eksperymentalny monitoring SLA i Fiberpunk

Lokalny monitoring przez LAN/Wi-Fi dla Elegoo Saturn 4 Ultra 12K/16K, Mars 5 Ultra, Anycubic Photon Mono X 6K oraz Prusa SL1/SL1S SPEED. Osobny monitor Fiberpunk Node/Node Pro odczytuje dane dostępne w lokalnym API adaptera. Stan, postęp, plik, warstwy i czas są pokazywane w zakresie raportowanym przez urządzenie. Bez sterowania, Farmy, wysyłania plików ani detekcji spaghetti SLA. Implementacja przeszła testy parserów i symulowanych połączeń; zgodność wymaga jeszcze potwierdzenia na fizycznych drukarkach. Szczegóły: [monitoring SLA](wiki/SLA-monitoring-PL.md).

Rozszerzenie: Saturn 3 Ultra / Mars 4 Ultra przez UDP, Photon P1 / P1 Max przez lokalny MQTT i Formlabs przez PreForm Server. Phrozen można monitorować przez zgodny mostek OctoPrint/Chituboard; bezpośrednie Mighty 8K nadal nie jest potwierdzone. Formlabs pokazuje rzeczywisty status i dostępny czas, bez udawanego procentu.

Widok listy drukarek dopasowany do Obsidiana: pojedynczy nagłówek rozwiniętej drukarki, czytelne strzałki rozwijania i zwijania, spójne powierzchnie oraz wyrównanie kart.

Dodawanie drukarki: typ wybierany kafelkowymi przyciskami, z zawijaniem do szerokości okna. Edycja i opcje zaawansowane otwierają pełne ustawienia wybranej drukarki również z topbara; dane połączenia mają osobny formularz. Obrót kamery 0/90/180/270° i odbicia w poziomie/pionie są zapisywane per drukarka, dodatkowo do orientacji z Moonrakera. Korekta obejmuje podglądy i zdjęcia; obszar Vision podąża za obrotem.

#### Spójne formularze Obsidian

- Wspólne przyciski, pola tekstowe, wysokości kontrolek i hierarchia tekstów w ustawieniach, automatyzacjach, konfiguracji gniazdek, edycji filamentów oraz pomocniczych oknach Vision.
- Ustawienia korzystają z palety wybranego szablonu; motyw obejmuje także mniejsze okna i formularze.
- Czytelniejsze długie opisy i etykiety. Katalog filamentów ma osobne wiersze danych szpuli i działań, bez ściskania wszystkiego w jednej linii.
- Zachowane natywne pola haseł, edycja, formatowanie liczb, skróty klawiaturowe i wygląd Basic. Systemowe okna wyboru plików oraz potwierdzeń pozostają natywne.

---

## English

Gantry 0.14.0 brings together the compact Modern interface, a redesigned Farm, clearer AMS and Spoolbase handling, fleet maintenance, and energy and costs for every print. New printer tools include an external camera, notification photos, a web-panel shortcut, a custom HTTP button and an alternate API address.

The app requires no account or Gantry-operated cloud. It connects to printers locally; the optional internet dashboard runs on your own hosting.

### Highlights

- **Gantry Basic and Gantry Modern.** Two card templates, compact readings and consistent application headers.
- **New Maintenance & service.** In-service status, custom tasks and checklists, templates, hour-based and calendar schedules, problems with photos, cost history and spare-parts inventory.
- **Dedicated AMS / Filaments view.** Printer selection, colour slots, active feeder, percentage and grams, and Spoolbase roll assignments.
- **Farm: file → printers → materials.** Printer-family folders, a file list, AMS matching, preflight checks, queue and history.
- **Energy across the whole cycle.** Background readings from supported metering sockets, a power trace, kWh and costs in history.
- **Compact statistics and exports.** A report beside each print name and CSV export of the full history.
- **Spoolbase: orders, palettes and labels.** Editable imports, local OCR, manufacturer colours and QR labels.
- **Easier fleet operation.** Lighting across supported printers, improved header clicks and an option to expand the edge dock only after clicking.
- **Web access on desktop and phone.** App-style layouts, a hosting package generator, hidden-EXT preferences and a 30-day remembered login.
- **Printer tools.** External camera, notification photos, web panel, custom GET/POST, alternate API address and polling intervals.
- **LITE inside the full app.** Switch back to status-only monitoring in the menu bar or tray while preserving full-edition data.

### Release refinements — October 20

- **Settings update the view immediately.** The checked state of Show AMS, progress and other readings matches their visibility. Preference persistence, live card refresh and checkbox marks have been corrected.
- **More readable controls.** Stronger field/hint contrast, shared menus, selectors and scrolling, vector icons, and retained styles when settings open inside the main window.
- **Rounded edge dock.** Transparency is preserved outside its silhouette; a closed dock no longer tries to reopen after printer settings change.
- **Compact and expanded Spoolbase.** Remaining grams, locations of opened rolls, responsive columns and TXT/CSV stock export.
- **Printer colour takes priority.** A valid loaded AMS/EXT colour takes precedence over Spoolbase's fallback colour. A mismatch calls for checking the assigned physical roll; it does not automatically rewrite its definition or price.
- **Farm is optional and off by default.** Enable it in Settings → General. Hiding the module retains files, queue and orders; statistics and Spoolbase remain separate.
- **Fleet chart.** The fill closes to a horizontal baseline rather than diagonally between its first and last points. It does not increase tile height or obscure More.
- **History and exports.** Correct dialog ownership when opened from embedded panels, initial scroll at the start of history and the visible owner for report saving.
- **Per-printer camera correction.** Rotation by 0/90/180/270° and horizontal/vertical flips, in addition to orientation from Moonraker.
- **PL/EN installer and MIT.** The Windows installer offers language selection, installation notes and complete licence terms. Publisher: `/parametryczny`. Gantry remains MIT-licensed.

Windows fixes passed 473 UI checks across Basic/Modern, light/dark and PL/EN, plus installation, autostart and uninstall-with-data-retention tests. These ran under Wine; they do not certify every physical computer or guarantee device compatibility.

### Appearance and everyday use

**Printer settings** appears above application Settings. Select a printer at the top to configure connection details, EXT and strip visibility, camera, custom lighting commands, socket, power and machine wear. The form keeps separate drafts for each printer. In menu-bar or tray mode, open it directly from the application menu. Pinning the full window preserves its position on the current display.

- Edge dock settings: compact printer and camera selection chips replace vertical lists; a new screen preview provides six position anchors, a readable caption and keyboard access.

Settings use a shared type scale: headings 14, labels and options 13, descriptions 12. Longer option names wrap to complete lines. Spacing and description widths are consistent; crowded camera-limit and Vision model rows have been separated.

Choose Gantry Basic or Gantry Modern in **Settings → Appearance**. Modern presents the printer name and connection type, state, file, progress, remaining time, finish time, layers, temperatures and filament in a compact layout. Available readings and their visibility depend on the printer and card settings.

Farm, Monitoring, Diagnostics, Spoolbase, Statistics and other views share Gantry's header style. Window mode removes unnecessary nested window frames. Control receives more consistent headings, buttons and spacing. Statistics places the file list beside the summary when space permits; narrower windows stack the content.

Separate pause and light shortcuts have been removed from the main Modern cards to leave more room for printer status. Controls remain available in their dedicated panel.

Header icon spacing and first-click handling have been refined: buttons respond even when the window was inactive. **Settings → Windows & strip** adds **“Expand the strip only after clicking.”** Hover expansion remains the default; a pinned strip stays expanded.

The application header's light button can send **lights on or off** to all connected printers with a supported lighting command or configured custom LED command. Fleet lighting is also available on the hosted dashboard when remote control is enabled; the read-only LAN dashboard does not send commands.

Fixes include opening history at the start, populating the Edit printer form, keeping the last card row visible—including MINI and fleet statistics—and correcting the fleet chart's size and fill. An idle printer now shows **“Waiting for print.”**

### Printer tools and photo notifications

- Per-printer external HTTP/HTTPS JPEG or MJPEG camera for any brand, shared by details, monitoring, edge strip and existing web access.
- Notification photos with a per-printer switch; Vision attaches the alarm frame. Presentation follows desktop notification settings.
- Web-panel shortcut and a manual GET/POST button with optional JSON and Bearer token in access-key storage. Saving does not execute it.
- Alternate API origin and separate printing/idle polling intervals for PrusaLink, Moonraker and OctoPrint. Controls and file transfers share the selected endpoint; commands are not automatically replayed at another address.
- Configuration guide: [Printer settings and tools](https://github.com/parametryczny/Gantrybar/wiki/Printer-tools-EN).

### AMS / Filaments and hiding EXT

Gantry gains a dedicated **AMS / Filaments** view in the Gantry menu and sidebar. Select a printer to see its modules and colour tiles. Slots show material, remaining percentage and grams when available; an arrow marks the printing slot. Module temperature and humidity appear when reported by the printer.

Clicking a slot opens colour, remaining-quantity and roll-assignment details. With Spoolbase enabled, assign or change a roll directly from this view. The layout adapts its columns to the available width and displays reported AMS/HT modules and external sources.

**EXT can be hidden per printer** in Edit printer, Details → Filaments / AMS, or the EXT switch in the new view. The preference applies to all external sources on that printer and is also respected by both the LAN and hosted web dashboards. Hiding changes presentation while preserving physical slot indices, assignments and filament consumption.

### Farm: file → printers → materials

The farm folder gets **X2D, X1, P1, P2, MINI and A1** subfolders. The library displays files as a refreshable list. Removing a library entry can also move its recorded original to the system trash; this operation refuses files used by active jobs or the queue.

Selecting a file shows its preview, plate, time, materials and printer compatibility. **Match AMS** proposes compatible slots; sources can also be selected manually. **Check selection** reports missing material, insufficient filament, nozzle mismatches and bed preparation before starting.

Material mapping and plate selection are concentrated in the workspace rather than expanded inside each printer card. Up to six printers use a compact 2 × 3 grid; a small window may still require scrolling. Refreshing AMS preserves selections and assignments that are still available.

The Farm supports sliced 3MF for Bambu Lab and G-code for supported Klipper, PrusaLink and OctoPrint printers. Tool-order changes are applied to a working copy of text G-code. The original is preserved; BG-code and checksummed files requiring such changes must be exported again.

**Uploading alone does not start a print.** A separate start requires confirmation. The queue may start a copy after you explicitly allow a prepared printer to take it.

#### Farm: preparation, production and quality

- New layout with a compact file list, printers in the middle and a separate materials inspector. Six printers fit without scrolling at the standard wide window size.
- File search in the app and web panel, combining multiple words, case and Polish diacritic handling with the folder filter.
- Separate preparation, queue, pickup/quality, orders and history views.
- Batch plans account for queued workload and filament reservations. Adding a batch does not start printing; empty-bed approval permits one start.
- Separate pickup and quality confirmations; a rejected copy creates a held reprint with its recorded reason.
- Manual orders with SKU, sliced file, plate, quantity and deadline; fulfilment counts accepted copies and avoids duplicate planning. WooCommerce and Etsy remain planned integrations.
- Compact production history with CSV export; materials inspectors respect hidden EXT spools.

### Energy, costs and history

Tasmota and supported Shelly sockets with power metering are polled approximately every **5 seconds**. A cycle includes preparation reported as an active job, printing and pauses, through completion or interruption.

Reports distinguish:

| Energy source | Meaning |
| --- | --- |
| Measured | energy calculated from socket readings |
| Partial measurement | measured intervals plus an estimate for missing time |
| Estimated | a result based on the printer's configured average wattage |

Computer sleep, closing the app or missing readings leave a gap instead of inventing a measurement. Missing filament usage is shown as unknown, not as 0 g.

Individual TXT reports and CSV history include duration, filament, energy, measurement source and cost breakdowns. These are job-data reports, **not downloads of the original 3MF/G-code**. The Files and prints list uses rows instead of separate cards. A download icon beside the name saves that job’s report, and the history window also offers a full export. Wide windows keep cost and time summaries on the left and the print list on the right.

### Spoolbase

Order import recognises material, product, colour, quantity, weight and price. Review the items and the **price per roll** before adding them. Image recognition runs locally through OCR; recognised items can be edited before saving.

The editor's palette suggests colours from the brand catalogue. Slicer profiles can be read on request to suggest product-series names; they do not replace the colour catalogue.

**62 × 37 mm** labels contain a QR code identifying a filament definition in your inventory. Labels can be printed or saved as PDF. The label code is not a printer access code.

Manually assigned rolls are no longer returned to stock merely because the printer reports no material for that slot. Removal detection first needs to have seen filament under that assignment, followed by a sustained empty-slot reading. Hidden EXT sources do not shift AMS/HT assignments.

Spool accounting no longer deducts both the AMS remaining-quantity update and slicer grams from the same balance. A recognised roll with a valid AMS quantity retains its balance source across restarts; slicer usage still enters history and cost reports. Rolls without such readings use normal subtraction. An AMS reading of 0 g now marks the roll empty. Gantry automatically assigns exactly one matching untagged roll; multiple candidates require manual selection. If AMS readings stop, the last known quantity is retained.

### Web access on a phone and your own server

A generic web ZIP is not attached to the release. Generate your own website package in Gantry, with your hosting address and configuration.

Desktop uses side navigation; phones use bottom navigation with vertically stacked printer cards. Viewing also includes monitoring and, when sharing is enabled, the Farm, history, costs, Spoolbase and maintenance.

**Generate website package…** prepares a ZIP with the current dashboard, hosting address, bridge key and password hash. The key is not included in JavaScript. Generating the ZIP neither enables synchronisation nor publishes the site.

After uploading the files to PHP hosting with HTTPS, enable the bridge in Gantry. The app initiates the connection to hosting, so this mode needs no router port forwarding. The local dashboard and own-hosting bridge are distinct access methods.

Form login and redirection from the older `api.php?action=login` address have been fixed; that flow could previously end on the “Please log in” JSON response. The session is saved before redirecting to the dashboard.

**“Remember me for 30 days”** retains login in that browser. Without it, the session has a 12-hour limit. Logging out or changing the password invalidates access. A phone home-screen shortcut may have its own cookie storage and need a separate first login; the same remembered-session mechanism then applies.

The browser still shows the domain in its address bar. “Gantry” is the page or shortcut name and does not replace Safari’s address display. Website changes require updating the hosted files; updating the desktop app alone does not replace a remote installation.

### Gantry Vision and monitoring

Dark-camera notices apply only during active printing after layers begin. They clear on pause, completion, interruption, job change or visibility recovery without removing unrelated warnings.

Monitoring gains an adaptive camera grid. Details, monitoring and the edge strip share the same printer feed, so opening another view does not take the picture away from existing viewers. Closing a view releases its own camera viewers.

Optional frame-rate limiting for larger fleets reduces camera-wall overhead. The limit applies to Monitoring; Details and the strip keep their normal preview. H.264 feeds receive special handling for keyframes.

**Gantry Vision Fast** is the bundled default model, with `ok`, `spaghetti` and `detached` classes. A different compatible model file can be selected. Its displayed name and recommended sensitivity threshold come from metadata. The detached class also uses synthetic examples; performance on real failures needs further validation.

Vision supports manual frame labelling, observation archives, responses to alarms and ZIP export. A user-confirmed defect can create a service problem with its photo; a model alarm alone does not create a report.

The archive can keep first-layer, 25%, 50%, 75% and closing images. The closing image uses the latest available frame. A manual label remains separate from a prediction; saving or exporting data does not automatically retrain network weights.

Local weight trials, including the Infill variant intended to reduce warnings on regular infill, are separate experiments. They are not a universal accuracy result and do not automatically replace installer models. Model choice, sensitivity and automatic pausing remain user settings.

Bambu file-tunnel replies on a port being tried as a camera are now recognised instead of treated as a valid image stream. This case receives an appropriate diagnostic rather than waiting for a frame that will never arrive.

Gantry now respects 0°/90°/180°/270° rotation and horizontal/vertical flips from Moonraker webcam configuration. Orientation is applied before the frame is shared with other previews and still-image consumers, including web viewing and camera-based tools. This fixes ignored configuration that could show printers such as Artillery upside down; without configured metadata, the app does not guess rotation by brand.

Fixed double normalization of Vision model input. Metadata `input.normalization: embedded` selects RGB / 255; older custom models retain ImageNet normalization unless specified otherwise. Updating does not silently replace a user-selected model.

### Maintenance & service — new desktop workspace

Open the fleet workspace from **Gantry → Maintenance & service…**, the sidebar or a printer card’s maintenance indicator. Its summary shows due tasks, printers in service, open problems and low-stock parts. Printer selection, search and a needs-attention filter help locate the relevant machine.

- **In-service status.** Farm excludes the printer and blocks new uploads, copy assignments and starts. Entering service disarms previously allowed queue starts; leaving service does not re-arm them. An existing print continues unchanged.
- **Custom tasks and checklists.** A title, steps, progress, and one-off or recurring work. Completing a task requires all steps to be checked. Tasks can be edited, archived and restored.
- **Templates.** Save a checklist and intervals for reuse; assign a new task to all printers at once if needed.
- **Hour-based and calendar schedules.** Set print hours, days or both—the earlier deadline applies. Completion starts the next cycle. Existing tasks retain seven-day reminder snoozing.
- **Problem register.** A title, note, priority, photo and open / in-progress / resolved status. A user-confirmed Vision defect can create a problem with its photo; a model prediction alone does not create a report.
- **Detailed history.** Date, operating hours, notes, completed checklist, consumed part and cost. Old and new entries share one chronological history.
- **Spare-parts inventory.** Quantity, minimum stock and unit price. Completion supports one selected inventory item with a quantity, plus additional costs. History and stock consumption are saved together; insufficient stock blocks completion. Later price changes do not recalculate historical costs.

The workspace adapts to its window: tasks and history sit side by side at wider sizes and stack at narrower sizes. Service data and photos stay local; existing counters and history are preserved.

The service workspace is part of full Gantry. The web dashboard considers service status when displaying Farm compatibility; task, problem and parts forms are opened in the app.

### LITE mode

The LITE switch in **Settings → Advanced** enables a simplified mode with printer status in the menu bar or system tray. Details, control, statistics, pricing, Farm, the standalone AMS module, Spoolbase, service, cameras and full-edition integrations are hidden. Settings retain basic options and the way back to full mode. Changing mode restarts the app.

Saved printers, history and inventory are preserved. The switch in the full app does not reduce its file size; a separate LITE installer is a reduced build and requires installing the full app to regain its tools.

### Updating the app and website

When updating your hosting, preserve the existing `config.php` and `data/`, and update website files together. A new key or password from a newly generated package changes the website configuration. Preserving existing data does not enable new sharing scopes.

📚 [Wiki / guides](https://github.com/parametryczny/Gantrybar/wiki) · ☕ [Support Gantry](https://buycoffee.to/parametryczny)

### Experimental SLA and Fiberpunk monitoring

Local LAN/Wi-Fi monitoring for Elegoo Saturn 4 Ultra 12K/16K, Mars 5 Ultra, Anycubic Photon Mono X 6K and Prusa SL1/SL1S SPEED. A separate Fiberpunk Node/Node Pro monitor reads the adapter’s local API. State, progress, job, layers and remaining time are displayed when reported by the device. No controls, Farm, uploads or SLA spaghetti detection. Parsers and simulated connections have been tested; physical printer compatibility still needs validation. See [SLA monitoring](wiki/SLA-monitoring-EN.md).

Extended monitoring: Saturn 3 Ultra / Mars 4 Ultra via UDP, Photon P1 / P1 Max via local MQTT, and Formlabs via PreForm Server. Phrozen can be monitored through a compatible OctoPrint/Chituboard bridge; direct Mighty 8K support remains unverified. Formlabs shows its actual status and available remaining time without an invented percentage.

The compact printer list now follows Obsidian: one header per expanded printer, clear expand/collapse arrows, consistent surfaces and aligned cards.

Add printer: wrapping tile buttons select the printer type. Edit and advanced actions open the selected printer’s full settings from the top bar as well; connection credentials keep a separate form. Per-printer camera correction supports 0/90/180/270° rotation and horizontal/vertical flips after Moonraker orientation. Previews and snapshots share the correction; the Vision detection area follows rotation.

#### Consistent Obsidian forms

- Shared buttons, text fields, control heights and typography across settings, automations, smart socket configuration, filament editing and supporting Vision dialogs.
- Settings follow the selected template palette, including auxiliary windows and forms.
- More readable long descriptions and labels. The filament catalogue separates spool values and actions into rows instead of squeezing every control into one line.
- Native secure fields, editing, number formatters, keyboard shortcuts and Basic appearance are preserved. OS file pickers and confirmation dialogs remain native.
