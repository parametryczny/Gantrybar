# Gantry 0.12.0: sterowanie drukarką, pomijanie obiektów, kamery w pasku bocznym i przegląd niezawodności

Gantry 0.12.0 po raz pierwszy pozwala wpłynąć na trwający wydruk. Z widoku szczegółów zmienisz temperaturę dyszy i stołu, wentylatory i prędkość, a z panelu pomijania obiektów wyrzucisz z płyty obiekt, który się nie udał, bez przerywania reszty. Pasek krawędziowy nosi obraz z kamer i daje się przypiąć, panele pomocnicze dostały własne okna, a ustawienia wyglądają jak systemowe. Wszystko to działa na macOS, Windows i GNU/Linuksie.

Druga połowa wydania to przegląd niezawodności: 24 poprawki z audytu, głównie w rozliczaniu rolek, zapisie danych i zgodności wersji Linux z macOS.

Gantry nadal działa wyłącznie lokalnie. Nie ma konta, chmury ani serwera pośredniczącego.

**Ważne dla właścicieli Bambu Lab:** sterowanie z Gantry działa tylko wtedy, gdy drukarka pracuje lokalnie, czyli ma włączony **tryb Tylko LAN** i **Tryb deweloperski**. Drukarka połączona z chmurą Bambu odrzuca polecenia wysłane spoza Bambu Connect. Podgląd stanu działa jak dotąd, a szczegóły są w sekcji [Wymagania po stronie drukarki](#wymagania-po-stronie-drukarki).

## Najważniejsze zmiany

- **Sterowanie z widoku szczegółów**: nastawy dyszy i stołu, wentylatory i prędkość druku. Domyślnie wyłączone.
- **Pomijanie obiektów** w trakcie druku na Bambu Lab i Klipperze, bez zatrzymywania pozostałych obiektów.
- **Czytelna blokada sterowania na Bambu**: sterowanie działa tylko w trybie Tylko LAN z włączonym Trybem deweloperskim. Gdy drukarka jest połączona z chmurą i przyjmuje tylko polecenia podpisane przez Bambu Connect, Gantry to wykrywa i mówi, co włączyć.
- **Kamery w pasku krawędziowym** i pinezka, która nie pozwala mu się zwinąć (zgłoszenie #34).
- **Skala interfejsu**: karta drukarki od 75 do 150 procent, pasek krawędziowy od 100 do 150.
- **Panele w osobnych oknach**: diagnostyka, statystyki floty, konserwacja, przypisanie rolki i Spoolbase.
- **Okno ustawień w stylu systemu**: sześć paneli zamiast trzech zakładek.
- **Rozliczanie rolek, które nie zgaduje**: wydruk nie odejmuje się dwa razy, nie obciąża złej rolki i nie trafia w rolkę założoną po zakończeniu.
- **Kod diagnostyczny zamiast surowej liczby** przy błędzie druku.
- **Bezpieczniejszy aktualizator**: suma SHA-256 sprawdzana przed instalacją i powrót do starej wersji, gdy podmiana się nie uda.
- **GNU/Linux dogania macOS**: sterowanie, kamera P1 i A1, skrypty w automatyzacjach oraz poprawki akcji, które kończyły się błędem.
- **Mniej pracy w tle**: pulpit, szczegóły i pasek nie przeliczają się, gdy nikt na nie nie patrzy.
- **Komunikaty w wybranym języku**: błędy połączeń, kamer i aktualizacji oraz odpowiedzi bota Telegram nie są już po polsku przy angielskim interfejsie.

## Sterowanie drukarką

> **Bambu Lab: tylko lokalnie.** Polecenia z Gantry (temperatury, wentylatory, prędkość, pomijanie obiektów, pauza, wznowienie, stop) drukarka Bambu przyjmie tylko w **trybie Tylko LAN** z włączonym **Trybem deweloperskim**. W zwykłym trybie, połączona z chmurą Bambu, odrzuci je. Klipper takiego warunku nie ma.

Widok szczegółów przestaje być tylko do czytania, ale dopiero po świadomym włączeniu przełącznika **Sterowanie drukarką** w Ustawieniach. Domyślnie jest wyłączony, bo zmiana temperatury w trakcie druku nie powinna zależeć od przypadkowego kliknięcia.

Po włączeniu kafelki dyszy i stołu dostają kapsułę z nastawą: minus, cel, plus. Kafelek pokazuje bieżący odczyt, kapsuła nastawę. Przytrzymanie przycisku powtarza krok, wartość skacze po siatce co 5 stopni, a polecenie wychodzi dopiero wtedy, gdy wartość przestanie się zmieniać. Stara nastawa z telemetrii nie nadpisuje nowej przez sześć sekund, więc liczba nie cofa się, zanim drukarka odpowie. Dysza przyjmuje do 300 °C, stół do 120 °C, a nastawa 0 wyłącza grzanie.

Wentylatory i prędkość to kafelki po dwa w rzędzie, z krokiem 10 procent.

| | Bambu Lab | Klipper |
| --- | --- | --- |
| Dysza i stół | tak | tak |
| Wentylatory | część, aux, komora | wentylator części |
| Prędkość | tryby: Cichy, Standard, Sport, Wariat | procent, od 10 do 166 |

Klipper dostaje tylko wentylator części, bo makra pozostałych zależą od konfiguracji maszyny i Gantry celowo nie zgaduje ich nazw. Bambu ignoruje procentową zmianę prędkości, dlatego tam kafelek przełącza tryby, tak jak ekran drukarki.

Gantry czyta odpowiedzi drukarki na polecenia. Gdy drukarka odrzuci polecenie, karta, z której je wysłano, pokazuje powód, zamiast po cichu cofnąć liczbę. Wentylatory Bambu raportują wartość w piętnastu stopniach, więc ustawione 70 procent wraca jako 67. Gantry traktuje to jako potwierdzenie, a nie odmowę.

### Bambu Lab i tryb deweloperski

Nowsze oprogramowanie Bambu przyjmuje polecenia sterujące tylko wtedy, gdy są podpisane przez Bambu Connect, a na resztę odpowiada `mqtt message verify failed`. Gantry rozpoznaje ten stan z maski funkcji, którą drukarka podaje w telemetrii. Gdy podpis jest wymagany, kafelki sterowania się nie pokazują, a karta temperatur mówi, żeby włączyć na drukarce **tryb Tylko LAN**, a potem **Tryb deweloperski**. Po włączeniu blokada znika sama.

Drukarki, które maski nie podają, wchodzą w ten sam stan po pierwszej odmowie i wychodzą z niego po pierwszym przyjętym poleceniu.

## Pomijanie obiektów

Panel **Pomiń obiekt…** pokazuje się przy druku i pauzie. Zaznaczasz obiekty na płycie, a drukarka przestaje je drukować. Reszta idzie dalej.

- **Klipper** sam wystawia obiekty przez moduł `exclude_object`, a Gantry wysyła `EXCLUDE_OBJECT` dla każdego zaznaczonego.
- **Bambu Lab** nie podaje obiektów w MQTT, więc Gantry pobiera z drukarki dane aktywnego projektu, tak jak robi to Bambu Studio: listę obiektów i obrazek płyty. Na H2D i X2D, gdzie FTPS nie widzi pamięci wewnętrznej, plik jest czytany tunelem na porcie 6000.

## Pasek krawędziowy: kamery i pinezka

Autor zgłoszenia #34 chciał widzieć postęp i obraz z kamery jednym spojrzeniem, bez otwartego osobnego okna. Pasek krawędziowy dostaje obie rzeczy.

**Pinezka** na samym pasku przypina go i odpina. Przypięty pasek nie zwija się po zjechaniu kursorem.

**Kamera pod paskiem** wiesza obraz drukarki pod jej wierszem. W ustawieniach paska wybierasz, które drukarki są w pasku i dla których pokazywać obraz. Bez wyboru obraz idzie za drukarką, która akurat drukuje.

Świadomy koszt: strumień żyje, dopóki pasek jest na ekranie, także zwinięty, więc najechanie od razu pokazuje obraz zamiast kilku sekund łączenia. Bambu ma jedno gniazdo kamery, więc drukarka zaznaczona w pasku nie odda w tym samym czasie obrazu Bambu Studio. Schowanie paska gasi wszystkie strumienie.

Przy okazji naprawiona została **kamera X1, która milkła po kilku sekundach**. Klient RTSP nie podtrzymywał sesji, więc drukarka przestawała ją karmić. Teraz sesja jest podtrzymywana, a obraz milczący dłużej niż osiem sekund łączy się od nowa.

Naprawiona została też **kamera Elegoo Centauri Carbon**, która w 0.11 nie dawała podglądu, choć zdjęcia z kamery działały. Gantry nie czekało na zgodę drukarki na strumień i nigdy go nie wyłączało, a drukarka pozwala na jeden podgląd naraz. Teraz podglądy jednej drukarki dzielą strumień, ostatni go oddaje, a odmowa drukarki pokazuje powód zamiast wiecznego łączenia.

**Wybór monitora i miejsca.** Przy kilku monitorach wskazujesz, na którym ma stać pasek, i wybierasz jedno z sześciu miejsc: u góry, na środku albo na dole lewej lub prawej krawędzi. W ustawieniach służy do tego lista monitorów i mały ekran z kwadracikami, a te same wybory są w podmenu „Pasek krawędziowy” w menu Gantry. Odłączony monitor nie kasuje wyboru: pasek czeka na głównym i wraca, gdy monitor znów się pojawi. Na krawędzi, za którą jest drugi monitor, pasek otwiera się dopiero po chwili postoju kursora, a nie przy każdym przejściu na sąsiedni ekran.

## Skala interfejsu

Karta drukarki ma skalę od 75 do 150 procent, a pasek krawędziowy od 100 do 150, w krokach po 5. Oba ustawia się parą przycisków minus i plus w Ustawieniach.

Okno floty mierzy przy tym prawdziwą wysokość kart, więc przewijanie pojawia się dopiero przy krawędzi ekranu, a nie przy każdym powiększeniu. Ten sam pomiar zdjął z panelu szczegółów sztywną wysokość 720 punktów, przez którą przewijał się bez powodu.

## Panele i ustawienia

Diagnostyka, statystyki floty, konserwacja, przypisanie rolki i Spoolbase były nakładkami wewnątrz panelu, który je otwierał. W dymku przy pasku menu nie mogły być od niego większe, przygaszały karty i potrafiły rzucić całym oknem. Teraz każdy ma **własne okno na środku ekranu** z nagłówkiem GANTRY · nazwa panelu, a Escape je zamyka. Dymek zostaje otwarty pod spodem.

Okno ustawień zostało przepisane na **sześć paneli**: Ogólne, Wygląd, Powiadomienia, Okna i pasek, Integracje oraz Zaawansowane. Na macOS to systemowe okno preferencji z paskiem narzędzi, na Windows i GNU/Linuksie pasek boczny. Podpisy stoją w jednej kolumnie, kontrolki w drugiej, a okno przyjmuje wysokość swojego panelu i otwiera się na środku ekranu. Naprawione zostało też osiem kontrolek, które w ukrytych panelach pokazywały stare wartości.

Na Windows naprawiony został pasek boczny w Windows 11 (zgłoszenie #32) i ucięty pasek przewijania w odpiętym panelu (#33). Nagłówek floty mieści się w jednej linii.

## Rozliczanie rolek

Spoolbase odejmuje gramy po wydruku. Przegląd znalazł kilka dróg, którymi obciążał złą rolkę albo tę samą dwa razy. Wszystkie są zamknięte na trzech systemach.

- **Wydruk jest sesją**: zaczyna się, gdy drukarka drukuje, kończy przy zakończeniu i jest zapamiętany. Dwa wydruki tego samego pliku w jednej godzinie nie zlewają się w jeden, a koniec zobaczony ponownie po restarcie nie odejmuje się drugi raz.
- **Obciążana jest aktywna rolka.** Bez aktywnego slotu tylko pojedyncza załadowana rolka, a przy kilku nic nie jest odejmowane. Wcześniej obciążany bywał pierwszy slot albo pierwszy AMS.
- **Przypisanie rolek jest odczytywane w chwili końca wydruku**, a nie po pobraniu pliku z drukarki, więc rolka założona w międzyczasie nie przejmuje zużycia. Wyłączenie Spoolbase w trakcie pobierania przerywa rozliczenie.
- **Kolor wspólny dla kilku rolek rozstrzyga materiał.** Gdy dalej jest remis, nic nie jest odejmowane.
- **Ciche godziny na GNU/Linuksie** wyciszają już tylko alert. Wcześniej pomijały też historię i rozliczenie, więc nocny wydruk nigdy nie schodził z rolki.

## Niezawodność

- **Zapisy w jednym kroku**: ustawienia, rolki i magazyn filamentów na Windows i GNU/Linuksie zapisują się przez plik tymczasowy i podmianę, z kopią ostatniej dobrej wersji. Przerwany zapis nie zostawia pustego pliku, a błędy trafiają do logu zamiast znikać.
- **Pobieranie z drukarki przez FTPS na Windows** ma limit 60 sekund, zawsze zamyka połączenie i robi jeden transfer naraz na drukarkę.
- **Windows i GNU/Linux szukają pliku 3MF na tych samych ścieżkach co macOS**, więc zadanie zgłoszone bez rozszerzenia też jest znajdowane.
- **Pamięć podręczna plików 3MF na macOS** ma limit 64 MB i usuwa przeterminowane pliki.
- **Skrypty w automatyzacjach**: zakończenie zastąpionego skryptu nie wyrejestrowuje już skryptu, który go zastąpił.
- **Automatyzacje na Windows zapisują się same** przy każdej zmianie, jak na macOS, więc zamknięcie okna niczego nie gubi.
- **Kod diagnostyczny**: błąd druku jest rozwiązywany przez katalog HMS, więc karta pokazuje instrukcję, a nieznany kod jako `Kod diagnostyczny: 0x...`.
- **Aktualizator**: macOS porównuje sumę SHA-256 pobranego archiwum z tą, którą GitHub podaje przy pliku, odkłada starą aplikację na bok i wraca do niej, gdy podmiana się nie uda. GNU/Linux bierze format paczki (DEB, RPM albo AppImage) z ustawień albo sam rozpoznaje sposób instalacji.

## GNU/Linux

- **Sterowanie drukarką** z tym samym zakresem, blokadą Bambu i odczytem odpowiedzi co na macOS i Windows.
- **Kamera P1 i A1**: gdy RTSPS nie daje obrazu, podgląd, pasek i zdjęcie do Telegrama korzystają ze strumienia JPEG na porcie 6000.
- **Skrypty** respektują shebang, mają przycisk Stop, wieloliniowy edytor i komunikat o błędzie.
- **Kamery i pinezka w pasku krawędziowym.**

Naprawione:

- **pauza, wznowienie i stop na Elegoo** kończyły się błędem;
- **bot Telegram** zatrzymywał się na `/help`, `/status`, `/spools`, `/mute`, `/watch`, zdjęciu i potwierdzeniu zatrzymania;
- **potwierdzenie automatyzacji** zamrażało okno na dwie minuty;
- **statystyki floty** blokowały okno floty;
- **zmiana adresu drukarki** przy odmowie pęku kluczy mogła usunąć drukarkę;
- **autostart bez ikony w zasobniku** uruchamiał aplikację bez okna.

## Wydajność

Pomiary w działającej aplikacji pokazały, że większość czasu głównego wątku szła na przeliczanie widoków, których nikt nie oglądał. Pulpit floty i widok szczegółów przestały się odświeżać przy zamkniętym panelu i doganiają telemetrię przy otwarciu.

Kafle temperatur i fasolki filamentu aktualizują wartości w miejscu, zamiast budować się od nowa przy każdej paczce telemetrii, co kończy też ich miganie. Ustawienia odświeżają się raz na kliknięcie zamiast siedem razy. Na macOS pasek krawędziowy rozsuwa się płynną animacją na matowym szkle.

## Tłumaczenia

Przez katalog tłumaczeń przechodzą teraz:

- komunikaty błędów połączeń, kamer, tunelu plików X2D, aktualizacji i walidacji drukarek;
- odpowiedzi bota Telegram;
- menu Edycja na macOS;
- okna Spoolbase.

Przy angielskim interfejsie nie pojawiają się już polskie napisy. Polski katalog ma 911 haseł, a kontrola w CI zatrzymuje budowanie, gdy w plikach usług wróci polski napis wpisany na sztywno. Poza zakresem zostały strony panelu webowego i kiosk Raspberry Pi.

## Wymagania po stronie drukarki

Gantry łączy się z drukarkami tylko w sieci lokalnej, więc część funkcji zależy od ustawień samej drukarki.

| Drukarka | Podgląd stanu | Sterowanie i polecenia | Kamera |
| --- | --- | --- | --- |
| Bambu Lab | kod dostępu z drukarki | tryb Tylko LAN i Tryb deweloperski | tryb Tylko LAN lub „LAN Mode Live View” |
| Klipper (Moonraker) | adres drukarki, klucz API, jeśli jest ustawiony | bez dodatkowych warunków | kamera skonfigurowana w Moonrakerze |
| Elegoo Centauri Carbon | adres drukarki, bez kodu | bez dodatkowych warunków | port 3031, jeden podgląd naraz |
| Elegoo Centauri Carbon 2 | tryb LAN-only i kod dostępu | tryb LAN-only | port 8080 |
| Anycubic Kobra S1 | tryb LAN w drukarce | tryb LAN | port 18088 |

Co to oznacza dla Bambu Lab:

- **Sterowanie działa tylko lokalnie.** Nowsze oprogramowanie Bambu przyjmuje polecenia spoza Bambu Connect wyłącznie w trybie Tylko LAN z włączonym Trybem deweloperskim. Połączona z chmurą drukarka odpowiada na nie `mqtt message verify failed`.
- **Tryb Tylko LAN odłącza drukarkę od chmury.** Nie działa wtedy aplikacja Bambu Handy ani druk i podgląd przez chmurę. To ustawienie drukarki, a nie ograniczenie Gantry.
- **Gantry nie obchodzi tej blokady.** Wykrywa ją, ukrywa kafelki sterowania i podpowiada, co włączyć na drukarce.
- **Kamera Bambu też jest lokalna.** Strumień nie działa, gdy drukarka jest połączona z chmurą bez włączonego podglądu LAN.

## Zgodność i aktualizacja

- **macOS:** macOS 13 lub nowszy;
- **Windows:** 64-bitowy Windows 10 lub 11;
- **GNU/Linux:** GTK 3, pakiety `.deb`, `.rpm` i `.AppImage`.

Aktualizacja zachowuje zapisane drukarki, ustawienia, Spoolbase i bezpiecznie przechowywane kody dostępu. Sterowanie drukarką jest po aktualizacji wyłączone; włączasz je w Ustawieniach.

Po aktualizacji na macOS system może poprosić o ponowne przyznanie dostępu do sieci lokalnej. Znajdziesz to w Ustawieniach systemowych, w sekcji Prywatność i ochrona, Sieć lokalna.

## Kontrola jakości

- kontrakt UI 1.10.0 wspólny dla macOS, Windows i GNU/Linuksa, obejmujący sterowanie, blokadę podpisu Bambu, okna paneli i położenie paska krawędziowego;
- 75 testów macOS, 143 testy wersji Linux oraz testy konsolowe Windows (rozliczanie rolek, zapisy, skrypty, ścieżki 3MF), wszystkie uruchamiane w CI;
- wspólny plik przypadków ścieżek 3MF sprawdzany na trzech systemach;
- render podglądu Windows w CI sprawdza, że nie zmienia danych użytkownika;
- kontrola katalogu tłumaczeń w trybie `--strict`, w tym polskich napisów wpisanych na sztywno, oraz kontrola nazw w XAML.
