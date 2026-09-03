# Gantry 0.11.0: powiadomienia Telegram, konserwacja drukarek i Anycubic Kobra S1

Gantry 0.11.0 wyprowadza monitorowanie poza komputer. Powiadomienia i sterowanie trafiają na Telegram, a drukarki zyskują własny plan konserwacji, historię wydruków i centrum diagnostyczne. Wszystkie trzy nowości działają na macOS, Windows i GNU/Linux. Dochodzi też obsługa Anycubic Kobra S1.

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

Nowa pozycja w menu prawego przycisku. `PrinterInsights` zbierał historię, godziny druku i zużycie filamentu osobno dla każdej drukarki, ale nic nie składało tego razem, więc nie dało się odpowiedzieć na pytanie ile wydrukowałem w tym miesiącu.

Panel pokazuje liczbę wydruków, nieudane, skuteczność, czas druku i filament w wybranym okresie (7 dni, 30 dni, rok, cała historia), a pod spodem rozbicie na drukarki posortowane po liczbie zadań. Przycisk eksportu zapisuje to samo podsumowanie jako zwykły tekst.

Uwaga o liczbach: godziny druku i gramy filamentu są licznikami dożywotnimi, więc widok okresowy liczy czas z samych wpisów historii, a zużycie filamentu pokazuje tylko dla całej historii. Inaczej „ostatnie 7 dni" pokazywałoby zużycie z całego życia drukarki.

## Alert przed końcem druku

Powiadomienie przychodziło dotąd dopiero po fakcie. Przy kilku drukarkach uprzedzenie bywa praktyczniejsze niż informacja, że coś skończyło się kwadrans temu.

Alert uzbraja się raz na wydruk i sam przezbraja, gdy pozostały czas wróci powyżej progu (nowe zadanie) albo drukarka przestanie drukować, więc jedno zadanie nie może przypominać o sobie w kółko. Próg to 10 minut. **Domyślnie wyłączony**, bo na zajętej flocie to jeden dodatkowy alert na każde zadanie obok tego o zakończeniu; włącznik jest w sekcji powiadomień.

## Pasek krawędziowy

Popover w pasku menu wymaga kliknięcia, a przy dłuższym wydruku zerka się na postęp co kilka minut. Pasek krawędziowy jest odpowiedzią na to zerkanie: wąski na 22 punkty panel przyklejony do lewej albo prawej krawędzi ekranu, zawsze nad innymi oknami, z jednym pierścieniem postępu na drukarkę. W spoczynku niesie tylko kolor statusu i wypełnienie pierścienia. Najechanie kursorem rozsuwa go do listy z nazwami, procentem i pozostałym czasem, a kliknięcie wiersza otwiera szczegóły tej drukarki.

Panel wyrasta z krawędzi zamiast obok niej stać: w miejscu styku ma wklęsłe przejścia, więc wtapia się w brzeg ekranu. Widać go na każdym pulpicie i nad aplikacją w trybie pełnoekranowym, a kliknięcie nie zabiera fokusu temu, w czym akurat piszesz.

W ustawieniach wybiera się krawędź, tryb **Tylko drukujące** oraz drukarki, które mają się pojawić. Lista jest zapisywana jako wykluczenia, więc nowo dodana drukarka pokazuje się sama, zamiast po cichu brakować. **Domyślnie wyłączony**, bo to druga powierzchnia obok popovera, a nie jego zamiennik.

Jedno zastrzeżenie dotyczy GNU/Linuksa: **na Wayland nie istnieje protokół trzymania okna na wierzchu**. Na X11 działa to normalnie, podobnie na kompozytorach wlroots (Sway, Hyprland), ale w sesji Wayland pod GNOME pasek da się przykryć innym oknem. Reszta zachowania jest tam identyczna.

## Nowe okno ustawień

Ustawienia urosły do dziewięciu sekcji w jednej przewijanej kolumnie i każda układała się po swojemu: raz siatka z etykietami do prawej, raz stos osiemnastu pól wyboru, raz przełącznik dosunięty do krawędzi. Okno zostało przepisane na **trzy zakładki**: Ogólne, Wygląd i Zaawansowane.

Pod spodem jest jeden system wierszy, więc etykiety mają teraz wspólną kolumnę po lewej, a kontrolki po prawej, w całym oknie. Pola wyboru zastąpiły przełączniki, doszła linia opisu tam, gdzie sama nazwa nie wystarcza, a nieaktywne sekcje przygasają w całości, nie tylko sama kontrolka.

Na wszystkich trzech systemach ten sam podział i ta sama wielkość okna. Windows dostał przełączniki przez szablon pola wyboru, a GNU/Linux korzysta z systemowego `StackSwitcher`, który sam rysuje pasek zakładek.

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

Aktualizacja zachowuje zapisane drukarki, ustawienia, Spoolbase i bezpiecznie przechowywane kody dostępu. Historia wydruków i liczniki konserwacji zaczynają się naliczać od pierwszego uruchomienia nowej wersji.

Po aktualizacji na macOS system może poprosić o ponowne przyznanie dostępu do sieci lokalnej. Znajdziesz to w Ustawieniach systemowych, w sekcji Prywatność i ochrona, Sieć lokalna.

## Kontrola jakości

- automatyczna kontrola zgodności kontraktu UI macOS, Windows i Linux;
- 33 testy jednostkowe macOS i 61 testów rdzenia oraz integracji wersji Linux;
- osobne workflow budujące macOS, Windows oraz pakiety `.deb`, `.rpm` i `.AppImage`.
