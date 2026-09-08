# Gantry 0.11.0: powiadomienia Telegram, konserwacja drukarek, tłumaczenia i Anycubic Kobra S1

Gantry 0.11.0 wyprowadza monitorowanie poza komputer. Powiadomienia i sterowanie trafiają na Telegram, a drukarki zyskują własny plan konserwacji, historię wydruków i centrum diagnostyczne. Wszystkie trzy nowości działają na macOS, Windows i GNU/Linux. Dochodzi też obsługa Anycubic Kobra S1 oraz wspólny katalog tłumaczeń, w którym nowy język to jeden plik.

Gantry nadal działa wyłącznie lokalnie. Nie ma konta, chmury ani serwera pośredniczącego.

## Najważniejsze zmiany

- **Powiadomienia i sterowanie przez Telegram**: alerty o zakończeniu, błędzie, pauzie i niskim filamencie trafiają na telefon, a bot pozwala odpytać drukarkę i nią sterować.
- **Konserwacja i historia**: cztery zadania serwisowe rozliczane w godzinach druku, z odkładaniem i własnymi interwałami, obok listy ostatnich wydruków i statystyk skuteczności.
- **Centrum diagnostyczne**: dostępne z menu prawego przycisku na ikonie, sprawdza całą flotę i pokazuje opóźnienie oraz ocenę jakości połączenia.
- **Anycubic Kobra S1**: lokalne MQTT/TLS w trybie LAN, bez konta Anycubic Cloud.
- **Statystyki floty**: zbiorcze podsumowanie wydruków, czasu i filamentu z eksportem do pliku tekstowego.
- **Alert przed końcem druku**, domyślnie wyłączony, do włączenia w ustawieniach.
- **Pasek krawędziowy**: wąski panel przyklejony do krawędzi ekranu, zawsze na wierzchu, z pierścieniem postępu na drukarkę. Domyślnie wyłączony.
- **Nowe okno ustawień**: trzy zakładki zamiast jednej długiej listy.
- **Tłumaczenia w osobnym pliku**: nowy język to jeden plik wrzucony do katalogu `i18n/`, bez dotykania kodu i bez nowego wydania.
- **Karta drukarki krótsza o 32 punkty na rząd** na macOS i o 29 pikseli na GNU/Linuksie, bez utraty żadnej informacji, na trzech systemach naraz.
- **Przełącznik Spoolbase gasi teraz całą funkcję**, a nie tylko pozycję w menu.
- **Synchronizacja między komputerami została usunięta.** Szczegóły niżej.
- **Instalator Windows schudł z 91 do 52 MB**, a paczka ZIP ze 130 do 76 MB.
- **Naprawione powiadomienia systemowe na Windows 11**, wentylatory na drukarkach Klipper oraz koniec skakania sekcji AMS w oknie szczegółów.

## Telegram

**Mostkiem jest Twój komputer.** Gantry nie ma serwera w chmurze, więc powiadomienia i komendy działają tylko wtedy, gdy maszyna z uruchomionym Gantry jest włączona, nie śpi i ma dostęp do sieci. Zamknięty laptop oznacza milczącego bota; po ponownym uruchomieniu wszystko wraca samo. Kto chce mieć to dostępne bez przerwy, powinien trzymać Gantry na czymś, co i tak chodzi cały czas.

Każdy użytkownik zakłada **własnego bota** u BotFather i wkleja token w Ustawieniach. Token zostaje na Twoim komputerze, nie ma wspólnego bota ani serwera Gantry pośrodku. Bot odpowiada wyłącznie na skonfigurowany czat, pozostałe wiadomości ignoruje.

Powiadomienia wychodzące podlegają tym samym przełącznikom co bannery systemowe: zakończenie, błąd (z opisem kodu HMS), pauza, drukarka offline, niski poziom filamentu i wysoka wilgotność AMS.

Bot obsługuje komendy:

| Komenda | Działanie |
| --- | --- |
| `/status` | wybór drukarki, a potem stan i przyciski sterowania |
| `/all` | cała flota w jednym podsumowaniu |
| `/spools` | rolki schodzące poniżej 20 procent |
| `/history` | ostatnie wydruki |
| `/watch 10m` | cykliczne zdjęcia z kamery, `/watch off` wyłącza |
| `/mute 2h` | wyciszenie alertów, `/mute off` wyłącza |
| `/help` | ściąga z komendami |

Po wybraniu drukarki dostajesz stan zadania, postęp, warstwy, czas do końca, temperatury i wilgotność AMS, kafle załadowanych slotów (kolor, materiał, procent, aktywny slot) oraz przyciski: pauza, wznów, stop z potwierdzeniem, światło komory i zdjęcie z kamery.

Zdjęcia (`/photo`) i `/watch` działają na **wszystkich trzech systemach**. Bambu dekoduje klatkę kluczową H.264 (VideoToolbox na macOS, ffmpeg na Windows, GStreamer na Linuksie), Anycubic idzie przez FLV, a Klipper i Elegoo oddają pierwszą klatkę MJPEG bez żadnego dekodera.

Pod rozmową siedzi **stały pasek komend**, który Telegram trzyma niezależnie od przewijania. Wybór drukarki to klawiatura przyklejona do konkretnej wiadomości, więc gdy rozmowa odjedzie, nie ma jak do niej wrócić; jeden tap w `/status` wrzuca świeżą listę na dole. Pasek instaluje się sam przy pierwszym powiadomieniu, nie trzeba o nim wiedzieć.

Instrukcja krok po kroku: [`docs/telegram-setup.md`](https://github.com/parametryczny/gantrybar/blob/main/docs/telegram-setup.md).

## Konserwacja, historia i diagnostyka

Każda drukarka ma panel konserwacji z czterema zadaniami rozliczanymi w **godzinach faktycznego druku**, a nie w dniach kalendarzowych:

| Zadanie | Domyślny interwał |
| --- | --- |
| Czyszczenie prowadnic | 100 h |
| Smarowanie osi | 200 h |
| Kontrola pasków | 300 h |
| Kontrola dyszy | 500 h |

Zadanie po terminie podświetla się na karcie. Możesz oznaczyć je jako wykonane, odłożyć o siedem dni albo ustawić własny interwał. Obok panelu znajdziesz listę ostatnich wydruków ze statusem i czasem trwania oraz statystyki: liczbę ukończonych zadań, skuteczność i zużycie filamentu w gramach.

Panel otwiera się jako nakładka wewnątrz aplikacji, a nie w osobnym oknie, więc nie odbiera fokusu i zamyka się kliknięciem obok. Akcje zostały skrócone do zwartego rzędu przycisków, a otwarcie panelu nie powoduje już podskoku całego okna.

Uwagi drukarki (kody HMS) są teraz oddzielone od zadań konserwacji, więc awaria sprzętu nie miesza się z planem serwisowym.

Centrum diagnostyczne otwierasz z menu prawego przycisku na ikonie Gantry. Dla każdej drukarki sprawdza dwie rzeczy: czy odpowiada jej port (z opóźnieniem w milisekundach i oceną jakości) oraz czy Gantry ma z nią żywe połączenie, a przy jego braku podaje powód. W trakcie widzisz nazwę aktualnie badanej drukarki i pasek postępu, a każda drukarka ma twardy limit trzech sekund, więc jeden host, który nie odpowiada, nie zatrzyma przebiegu. Na macOS panel jest nakładką w stylu pozostałych paneli aplikacji.

## Statystyki floty

Nowa pozycja w menu prawego przycisku, **na wszystkich trzech systemach**. `PrinterInsights` zbierał historię, godziny druku i zużycie filamentu osobno dla każdej drukarki, ale nic nie składało tego razem, więc nie dało się odpowiedzieć na pytanie ile wydrukowałem w tym miesiącu.

Panel pokazuje liczbę wydruków, nieudane, skuteczność, czas druku i filament w wybranym okresie (7 dni, 30 dni, rok, cała historia), a pod spodem rozbicie na drukarki posortowane po liczbie zadań. Przycisk eksportu zapisuje to samo podsumowanie jako zwykły tekst.

Uwaga o liczbach: godziny druku i gramy filamentu są licznikami dożywotnimi, więc widok okresowy liczy czas z samych wpisów historii, a zużycie filamentu pokazuje tylko dla całej historii. Inaczej „ostatnie 7 dni" pokazywałoby zużycie z całego życia drukarki.

## Alert przed końcem druku

Powiadomienie przychodziło dotąd dopiero po fakcie. Przy kilku drukarkach uprzedzenie bywa praktyczniejsze niż informacja, że coś skończyło się kwadrans temu.

Alert uzbraja się raz na wydruk i sam przezbraja, gdy pozostały czas wróci powyżej progu (nowe zadanie) albo drukarka przestanie drukować, więc jedno zadanie nie może przypominać o sobie w kółko. Próg to 10 minut. **Domyślnie wyłączony**, bo na zajętej flocie to jeden dodatkowy alert na każde zadanie obok tego o zakończeniu; włącznik jest w sekcji powiadomień.

## Pasek krawędziowy

Popover w pasku menu wymaga kliknięcia, a przy dłuższym wydruku zerka się na postęp co kilka minut. Pasek krawędziowy jest odpowiedzią na to zerkanie: wąski na 22 punkty panel przyklejony do lewej albo prawej krawędzi ekranu, zawsze nad innymi oknami, z jednym pierścieniem postępu na drukarkę. W spoczynku niesie tylko kolor statusu i wypełnienie pierścienia. Najechanie kursorem rozsuwa go do listy z nazwami, procentem i pozostałym czasem, a kliknięcie wiersza otwiera szczegóły tej drukarki.

Panel wyrasta z krawędzi zamiast obok niej stać: w miejscu styku ma wklęsłe przejścia, więc wtapia się w brzeg ekranu. Widać go na każdym pulpicie i nad aplikacją w trybie pełnoekranowym, a kliknięcie nie zabiera fokusu temu, w czym akurat piszesz.

Pasek działa na macOS, Windows i GNU/Linuksie, z tą samą sylwetką wrastającą w krawędź. W ustawieniach wybiera się krawędź, tryb **Tylko drukujące** oraz drukarki, które mają się pojawić. Lista jest zapisywana jako wykluczenia, więc nowo dodana drukarka pokazuje się sama, zamiast po cichu brakować. **Domyślnie wyłączony**, bo to druga powierzchnia obok popovera, a nie jego zamiennik.

Jedno zastrzeżenie dotyczy GNU/Linuksa: **na Wayland nie istnieje protokół trzymania okna na wierzchu**. Na X11 działa to normalnie, podobnie na kompozytorach wlroots (Sway, Hyprland), ale w sesji Wayland pod GNOME pasek da się przykryć innym oknem. Reszta zachowania jest tam identyczna.

## Nowe okno ustawień

Ustawienia urosły do dziewięciu sekcji w jednej przewijanej kolumnie i każda układała się po swojemu: raz siatka z etykietami do prawej, raz stos osiemnastu pól wyboru, raz przełącznik dosunięty do krawędzi. Okno zostało przepisane na **trzy zakładki**: Ogólne, Wygląd i Zaawansowane.

Pod spodem jest jeden system wierszy, więc etykiety mają teraz wspólną kolumnę po lewej, a kontrolki po prawej, w całym oknie. Pola wyboru zastąpiły przełączniki, doszła linia opisu tam, gdzie sama nazwa nie wystarcza, a nieaktywne sekcje przygasają w całości, nie tylko sama kontrolka.

Na wszystkich trzech systemach ten sam podział i ta sama wielkość okna. Windows dostał przełączniki przez szablon pola wyboru, a GNU/Linux korzysta z systemowego `StackSwitcher`, który sam rysuje pasek zakładek.

## Tłumaczenia

Napisy były dotąd wpisane parami wprost w kod, w czterech różnych idiomach naraz: `text(pl, en)` na macOS, `AppSettings.Text(pl, en)` i wyrażenia warunkowe na Windows, a na Linuksie wyrażenie warunkowe obok słownika `TEXT`. Łącznie 1091 wywołań i 623 unikalne pary. Dodanie trzeciego języka oznaczało dopisanie trzeciego argumentu w 1091 miejscach na trzech systemach.

Teraz jest jeden katalog w `i18n/`, wspólny dla macOS, Windows i GNU/Linuksa, kluczowany **angielskim napisem źródłowym**, tak jak gettext kluczuje po `msgid`. Ma to dwa praktyczne skutki. Brakujące hasło degraduje się do czytelnego angielskiego zamiast pokazywać surowy klucz w rodzaju `settings.launchAtLogin`. Angielski nie potrzebuje własnego pliku, bo **jest** kluczem.

**Nowy język to jeden plik.** Kopiujesz `i18n/pl.json`, tłumaczysz wartości, zapisujesz jako `i18n/de.json` i gotowe: język pojawia się na liście w Ustawieniach sam. Nazwę własną języka niesie klucz `@name` w środku pliku, więc nigdzie w kodzie nie ma tabeli nazw ani listy dostępnych języków. Nie trzeba rekompilować aplikacji ani czekać na wydanie.

Wypełniacze są pozycyjne (`{0}`, `{1}`), bo to natywny format `string.Format` w C# i `str.format` w Pythonie, więc ten sam plik działa bez tłumaczenia na formaty każdego systemu.

W wydaniu jedzie polski katalog: 722 hasła. Przy scalaniu wyszło pięć miejsc, gdzie ten sam angielski napis miał wcześniej dwa różne polskie tłumaczenia (`Printing` raz jako „Drukowanie", raz „Drukuje", `Paused` raz „Wstrzymana", raz „Pauza"), więc kilka napisów jest teraz spójnych, choć brzmią inaczej niż w 0.10.0.

Katalogu pilnuje kontrola w CI: sprawdza brakujące hasła, hasła bez użycia w kodzie i klucze urwane w połowie.

## Krótsza karta drukarki

Karta rosła przez kolejne wydania i przy pięciu drukarkach okno zajmowało większość ekranu. Zmieniony został układ, nie zawartość: **żadna informacja nie znika**.

Procent przeniósł się do linii statusu, po prawej, więc zniknął cały wiersz, w którym stał sam w 22 punktach; sam procent schodzi do 14 punktów pogrubionych. Czas do końca i warstwy stają obok paska postępu, w tym samym wierszu. Etykieta temperatury stoi teraz obok wartości zamiast nad nią, więc sekcja temperatur ma 22 punkty zamiast 34.

Zmierzone, nie oszacowane: na macOS karta schudła ze **134 do 102 punktów**, czyli 32 punkty na rząd. Przy pięciu drukarkach w dwóch kolumnach to około 96 punktów mniej w oknie. Na GNU/Linuksie ta sama zmiana daje **220 na 191 pikseli**, czyli 29 na rząd; różnica bierze się z innych metryk czcionek, nie z innego układu.

Mały kafelek wykresu obok nazwy drukarki dostał własny przełącznik w Ustawieniach, w sekcji Karty drukarek, **domyślnie wyłączony**. Nic się przez to nie traci, bo menu trzech kropek zawsze niesie pozycję Szczegóły; kafelek był skrótem, nie jedyną drogą.

Zmiana wchodzi **na wszystkich trzech systemach naraz**, razem z przełącznikiem kafelka. Kontrakt układu karty (`design/gantry-card-layout.impl.json`) opisuje teraz wariant B i pilnuje go w CI osobno dla macOS, Windows i Linuksa: rozmiar procentu, wysokość wiersza temperatur i obecność przełącznika. Wcześniej kontrakt opisywał starą kartę, więc nic nie łapało rozjazdu między systemami.

## Spoolbase: przełącznik gasi całą funkcję

Przełącznik Spoolbase chował dotąd wyłącznie pozycję w menu, a reszta funkcji chodziła dalej. Na macOS i Windows kliknięcie slotu AMS nadal otwierało okno przypisania rolki, karta nadal czytała przypisaną rolkę zamiast odczytu z AMS, a po skończonym wydruku gramy nadal były odejmowane. Linux blokował sam klik, ale odejmował tak samo. Trzy systemy, trzy różne zachowania.

Teraz obowiązuje jedna zasada wszędzie. Wyłączony Spoolbase oznacza: brak okna przypisania, karta z surowym odczytem z AMS, brak automatycznego odejmowania po wydruku i brak odpinania przypisań przez tag NFC. Podgląd w przeglądarce i komenda `/spools` w Telegramie idą za tym samym przełącznikiem, żeby dane rolek nie wyciekały bokiem.

Rolki nie są ruszane, a wydruki skończone przy wyłączonej funkcji nie są zapamiętywane jako odjęte, więc ponowne włączenie wraca do gramów sprzed wyłączenia.

## Usunięte: synchronizacja między komputerami

Dwukierunkowa synchronizacja Spoolbase, listy drukarek i ustawień między własnymi komputerami weszła w 0.9.0. W 0.11.0 **znika w całości**, z macOS, Windows i GNU/Linuksa.

Znikają usługi synchronizacji, sekcja „Synchronizacja między komputerami" w Ustawieniach, wpisy w konfiguracji (token parowania, identyfikator urządzenia, lista sparowanych maszyn) oraz cały ruch sieciowy. Serwer podglądu floty zostaje, ale przestaje przyjmować jakiekolwiek zapisy: endpoint `/api/sync` i autoryzacja tokenem znikają na wszystkich trzech systemach, więc **każda ścieżka serwera jest teraz tylko do odczytu**.

Co to znaczy przy aktualizacji: dane lokalne zostają nietknięte, nic nie jest kasowane. Przestaje działać wyłącznie przenoszenie ich między maszynami. Jeżeli używałeś synchronizacji, po aktualizacji każdy komputer trzyma swoją kopię magazynu i listy drukarek, tak jak przed 0.9.0.

## Anycubic Kobra S1

Przy dodawaniu drukarki wybierasz markę **Anycubic**, model **Kobra S1**, włączasz w drukarce tryb LAN i podajesz jej adres IP. Gantry sam pobiera lokalną sesję MQTT, więc konto Anycubic Cloud ani kod dostępu nie są potrzebne.

Obsługa obejmuje stan zadania, temperatury, sterowanie drukiem, światło komory, moduł ACE Pro oraz kamerę FLV na porcie 18088. Szczegóły: [`docs/anycubic-kobra-s1.md`](https://github.com/parametryczny/gantrybar/blob/main/docs/anycubic-kobra-s1.md).

## Poprawki

- **Powiadomienia systemowe na Windows 11**: rejestracja powiadomień odbywa się teraz na wątku STA aplikacji. Telemetria drukarek przychodzi na wątkach roboczych, gdzie inicjalizacja WinRT potrafiła po cichu zawieść, przez co nie pojawiało się nic. Gantry sprawdza dodatkowo, czy powiadomienia nie zostały wyłączone przez użytkownika lub politykę firmową, i w takim wypadku wraca do dymka w zasobniku zamiast milczeć. Błędy trafiają do logu.
- **Sekcja AMS przestała skakać w oknie szczegółów**: widok filamentów przebudowywał się przy każdym pakiecie telemetrii, nawet gdy nic się nie zmieniło. Dodatkowo pakiet częściowy zawierający wyłącznie tacę zewnętrzną chwilowo usuwał znane moduły AMS, przez co karta zmieniała wysokość i wracała. Bambu wysyła dane AMS i tacy zewnętrznej w niezależnych pakietach, więc każdy z nich aktualizuje teraz tylko tę część, którą faktycznie niesie.
- **Centrum diagnostyczne nie wywraca już aplikacji ani nie zawiesza się w połowie**: okno trzymał kontroler ustawień, więc zamknięcie ustawień zostawiało je osierocone i pierwszy ruch myszy sięgał po zwolnione widoki. Panel żyje teraz wewnątrz aplikacji, tak jak konserwacja. Osobno naprawiony został przebieg testu, który potrafił zamilknąć po pierwszej drukarce.
- **Panel konserwacji na macOS otwiera się poprawnie**: wcześniej potrafił nie zareagować na kliknięcie. Przy okazji zniknął podskok okna przy otwieraniu.
- **Panel konserwacji, układ**: wyrównane wiersze akcji, szersze pole interwału mieszczące wartości czterocyfrowe i nazwy zadań, które nie urywają się wielokropkiem.
- **Wentylatory na drukarkach Klipper**: Aux i Chamber pokazywały kreskę zawsze, bo czytany był wyłącznie obiekt o nazwie `fan`, a wentylatory pomocniczy i komory żyją pod `fan_generic`. Na forkach producenta, które nie publikują gołego `fan`, znikał też Part. Teraz odpytywane są wszystkie wentylatory, jakie maszyna wystawia, i klasyfikowane po nazwie.
- **Kamera Anycubica na macOS**: wydania nie zawierały ffmpeg, którego ta kamera wymaga, więc funkcja obiecana w README po prostu nie działała. Aplikacja niesie teraz własny, minimalny build.
- **Kamera P1 i A1 na macOS**: te modele nie mają punktu RTSP i serwują obraz strumieniem JPEG na porcie 6000. macOS próbował wyłącznie RTSP, więc nie miał jak się połączyć. Protokół, który Windows obsługuje od początku, działa teraz także na macOS.
- **Okno szczegółów na Windows**: przebudowywało sześć sekcji co sekundę, bezwarunkowo, podczas gdy macOS i Linux robią to zdarzeniowo. Przebudowuje się już tylko to, co faktycznie się zmieniło.
- **Wyciszenie Telegrama** zapisywane jest w tym samym formacie na wszystkich systemach. Starszy zapis jest odczytywany i migrowany, więc aktywne wyciszenie nie przepada przy aktualizacji.
- **Temperatura komory na H2D i X2D**: po włączeniu podgrzewania komory na ekranie pojawiało się `4259904` zamiast 64 stopni. Drukarka pakuje w to pole dwie liczby naraz, bieżący odczyt i nastawę, tak samo jak przy dyszach, a wszystkie trzy parsery czytały je surowo. Przy wyłączonym podgrzewaniu nastawa wynosi zero i liczba wyglądała poprawnie, dlatego błąd ujawniał się dopiero po włączeniu grzania. Przy okazji nastawa komory jest już pokazywana obok odczytu, tak jak przy dyszy i stole.
- **Konserwacja pokazywała `78.52096950885323 h` zamiast `78.5`**: ujednolicanie wypełniaczy zdjęło z kilku napisów informację o precyzji, więc liczba szła na ekran ze wszystkimi piętnastoma cyframi. Widoczne było w konserwacji, statystykach floty i szczegółach. Poza poprawieniem tych miejsc podstawianie liczb ma teraz własne formatowanie, jedno miejsce po przecinku i bez ogona `.0` przy całkowitych, więc następne takie wywołanie nie powtórzy błędu.
- **Nakładka drukarki offline zasłaniała menu karty**: przykrywała całą kartę razem z nagłówkiem, więc nazwa, kafelek szczegółów i menu trzech kropek znikały pod przyciemnieniem. Efekt był taki, że niedostępnej drukarki nie dało się wyedytować ani usunąć, czyli akcje znikały dokładnie wtedy, gdy są potrzebne. Nakładka zaczyna się teraz pod nagłówkiem, a płaską plamę koloru zastąpiło rozmycie tym samym materiałem, którego używa panel.
- **Podsumowanie reguły automatyzacji na macOS**: wiersz reguły pokazuje pod nazwą linijkę „wyzwalacz, akcja", tak jak od dawna robi to Linux. Przy okazji stan drukarki w podsumowaniu pokazywał surową wartość zapisu (`printing` zamiast nazwy stanu).
- **Kody HMS**: poprawione rozpoznawanie katalogów i wycentrowane pola formularzy.

## Rozmiar pakietów

Instalator Windows ważył 91 MB, z czego **139 MB nieskompresowanej zawartości stanowił sam `ffmpeg.exe`**, czyli pełny build ze wszystkimi kodekami, filtrami i muxerami. Gantry używa go wyłącznie jako dekodera H.264 i FLV, więc wydanie niesie teraz build zawierający tylko to, co faktycznie wywołujemy.

| Pakiet | Przed | Po |
| --- | --- | --- |
| Instalator Windows | 91 MB | **52 MB** |
| ZIP Windows | 130 MB | **76 MB** |

Przy okazji zeszliśmy z licencji GPL na LGPL, bo dekoder H.264 nie wymaga tej pierwszej.

W AppImage zdeduplikowano 290 bibliotek, które były w paczce po dwa razy (raz z bundlera Pythona, raz z narzędzia wdrożeniowego). Rozmiar samego pliku prawie się nie zmienił, bo squashfs i tak sklejał identyczne kopie, ale zniknęło ryzyko, że przy dwóch wersjach tej samej biblioteki o wyniku zdecyduje kolejność ładowania.

## Uwaga dla macOS 26 i nowszych

Na najnowszych wersjach macOS runtime współbieżności Swifta potrafi przewrócić aplikację przy wewnętrznej kontroli izolacji wątku, w miejscach zupełnie niezwiązanych z tym, co robisz. Objawiało się to nagłym zamknięciem Gantry przy ruchu myszy albo w trakcie testu diagnostycznego. Wydanie jest budowane bez tych kontroli, które i tak były zbędne, bo interfejs działa wyłącznie na głównym wątku.

Wydania są teraz budowane w konfiguracji release. Wcześniej skrypt pakował build debug, wolniejszy i z dodatkowymi asercjami.

## Zgodność i aktualizacja

- **macOS:** macOS 13 lub nowszy;
- **Windows:** 64-bitowy Windows 10 lub 11;
- **GNU/Linux:** GTK 3, pakiety `.deb`, `.rpm` i `.AppImage`.

Aktualizacja zachowuje zapisane drukarki, ustawienia, Spoolbase i bezpiecznie przechowywane kody dostępu. Historia wydruków i liczniki konserwacji zaczynają się naliczać od pierwszego uruchomienia nowej wersji. Usunięcie synchronizacji nie kasuje żadnych danych lokalnych, przestaje działać wyłącznie ich przenoszenie między maszynami.

Po aktualizacji na macOS system może poprosić o ponowne przyznanie dostępu do sieci lokalnej. Znajdziesz to w Ustawieniach systemowych, w sekcji Prywatność i ochrona, Sieć lokalna.

## Kontrola jakości

- automatyczna kontrola zgodności kontraktu UI macOS, Windows i Linux;
- kontrola katalogu tłumaczeń w trybie `--strict`: brakujące hasła, hasła bez użycia w kodzie i klucze urwane w połowie zatrzymują budowanie;
- 33 testy jednostkowe macOS i 57 testów rdzenia oraz integracji wersji Linux;
- osobne workflow budujące macOS, Windows oraz pakiety `.deb`, `.rpm` i `.AppImage`.
