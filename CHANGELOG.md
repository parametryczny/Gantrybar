# Historia zmian Gantry

Wszystkie istotne zmiany w aplikacji Gantry (dawniej BambuBar / PrismBar) są opisane w tym pliku.

## Niewydane

### Zmienione

- **oznaczone klatki liczą się także przy wskazanym silniku**: odkąd Gantry Vision stał się podstawą, przycisk „Zaznacz defekt…" nie robił dla wykrywania zupełnie nic, bo model był wyłącznym sędzią. Teraz pytane są obie strony naraz i mocniejszy powód wygrywa. Model zna kamery, na których był uczony; Twoje klatki znają kamerę, która stoi przed Tobą. Gdy silnik mówi „coś podobnego do awarii, ale za słabo", a zdjęcie z tej samej kamery, które sam oznaczyłeś, mówi wprost, to Twoje zdjęcie ma rację. Dotyczy tak samo pilnowania w tle jak przycisku „Testuj".
- **silnik podaje swój zmierzony próg**: suwak czułości jest wspólny dla wszystkich silników, ale skala wyników nie. „90%" u jednego modelu znaczy co innego niż u drugiego, a ustawienie go za wysoko potrafi wyciszyć wykrywanie tak, że nigdy się o tym nie dowiesz: Gantry Vision przy 70% łapie w teście 22 awarie na 22, a przy 90% dwie na 22. Gdy suwak stoi powyżej progu, przy którym silnik był mierzony, Ustawienia piszą to wprost obok suwaka.

- **drukarka, która straciła połączenie, zawsze wraca**: zaplanowane ponowienie służyło jednocześnie za blokadę („nie planuj, jeśli jedno już czeka"), więc każda droga wyjścia z niego, która zapomniała tę blokadę zwolnić, zatrzymywała ponawianie dla tej drukarki do końca sesji. Karta dalej obiecywała „ponowna próba za 20 s", a nic już się nie działo. Blokady nie ma: najnowsze rozłączenie po prostu przejmuje ponowienie, a pod tym leży zamiatarka, która raz na minutę szuka drukarek bez zaplanowanego powrotu i planuje im go. Zamiatarka, która zawsze znajduje zero roboty, jest tu sensem, a nie marnotrawstwem.
- **pilnowanie wydruków nie dobija się do kamer**: klatka z podglądu, który ktoś już ma otwarty, jest darmowa, ale klatka wymagająca własnego połączenia to świeża sesja TLS na małej płytce w drukarce, a przy odstępie 20 s wychodziły z tego trzy na minutę na drukarkę, bez końca. Teraz własne połączenie otwiera się najwyżej raz na minutę, a kamera, która odmawia, jest pytana coraz rzadziej, aż do pięciu minut.

- **wykrywanie przesunięcia warstw wycofane**: szukało całego obrazu jadącego w bok i na prawdziwej flocie myliło się prawie za każdym razem, gdy się odezwało: dziesięć fałszywych alarmów w pół godziny na pięciu drukarkach, z których żadna nie miała najmniejszego problemu. Zmierzone potem na tych samych klatkach: kamera, która nie drgnęła, raportowała przesunięcie o siedem pikseli w jedną stronę i osiem w drugą. Porównywanie kolumn krawędzi całego kadru nie odróżnia obiektu, który się przesunął, od głowicy, która przejechała przed obiektywem. Złapanie tego naprawdę wymaga śledzenia samego obiektu, a nie całej klatki, i do tego czasu Gantry nie udaje, że potrafi. Oznaczanie przesunięcia warstw z ręki, w Szczegółach, zostaje bez zmian.
- **klatki z dwóch różnych strumieni nie są ze sobą porównywane**: drukarki P1 i A1 mają dwa strumienie o różnym kadrze, a Gantry brało z nich klatki na przemian. Porównanie klatki z jednego z klatką z drugiego czytało zmianę kamery jako zmianę wydruku i było głównym źródłem fałszywych alarmów. Teraz zmiana źródła kasuje historię i obserwacja zaczyna od nowa.
- **o tej samej wpadce raz na wydruk**: licznik spokojnych klatek kasował się po minucie, więc to samo ostrzeżenie wracało co kilka minut i karta zbierała trzy identyczne komunikaty jeden pod drugim. Teraz każdy rodzaj wpadki jest zgłaszany raz na wydruk i wraca dopiero przy następnym.

- **podgląd kamery i pilnowanie wydruków nie odbierają sobie kamery**: kamera drukarki wpuszcza jednego klienta naraz, a drugie połączenie nie dostaje drugiej kopii obrazu, tylko zabiera go pierwszemu. Wykrywanie wpadek i strona www biorą teraz klatkę z podglądu, który już działa, zamiast otwierać własne połączenie. Przy strumieniu H.264 z drukarki Bambu podgląd oddaje ostatnią klatkę kluczową, a Gantry rozkodowuje ją poza głównym wątkiem, więc oglądanie na żywo nie przeszkadza pilnowaniu, tylko je karmi. Własne połączenie otwiera się dopiero wtedy, gdy nikt nie patrzy. Sprawdzone na flocie: przy otwartym pasku krawędziowym wszystkie trzy drukarki z podglądem oddają klatkę co 20 sekund.
- **migawka z P1S i A1 mini w ogóle działa**: te maszyny nie mają RTSP, a migawka próbowała tylko RTSP, więc przez dwanaście sekund czekała na nic i wracała pusta. Zdjęcie na Telegramie było dla nich puste, a pilnowanie wydruków nie zajrzało do nich ani razu. Teraz migawka schodzi na strumień JPEG z portu 6000, tak jak od dawna robi podgląd na żywo, i zapamiętuje, którym sposobem dana kamera odpowiedziała, żeby następnym razem nie tracić czasu na ten drugi.

- **strona wygląda jak aplikacja**: karta na stronie to czwarty port tej samej karty floty, co macOS, Windows i GNU/Linux. Nagłówek z ikoną drukarki, nazwą i podpisem protokołu, wiersz stanu z plikiem i procentem w kolorze neutralnym, pasek postępu złożony z 32 segmentów, metryki czasu i warstw w pigułkach, bento temperatur w kolorach dyszy, stołu i komory, dok filamentów z kaflami slotów, procentem na kaflu i kropką ostrzeżenia przy kończącej się rolce. Kamera została na dole karty. Kolorów ani wymiarów nie ma tam wpisanych z ręki: `web/assets/tokens.css` powstaje z `design/gantry-card-layout.impl.json` przez `scripts/build_web_theme.py`, a sprawdzenie zgodności nie przepuści nieaktualnego pliku ani koloru wpisanego obok kontraktu.
- **pomijanie obiektów tylko tam, gdzie zadziała**: przycisk „Pomiń obiekt” na karcie floty, w menu karty i w widoku szczegółów pokazuje się dla drukarki Bambu Lab wtedy, gdy przyjmuje ona polecenia z Gantry, czyli w trybie Tylko LAN z włączonym Trybem deweloperskim. Drukarka związana z chmurą odmówiłaby pominięcia, więc nie dostaje przycisku, którego i tak nie da się użyć. Gantry rozpoznaje to po masce funkcji, którą drukarka podaje w telemetrii, tak samo jak przy sterowaniu temperaturami i wentylatorami; gdy firmware jej nie podaje, rozstrzyga pierwsza odmowa polecenia. Klipper ma ten przycisk zawsze. Przy okazji widok szczegółów na Windows i GNU/Linuksie dostał ten sam przycisk obok „Wróć”, który dotąd miał tylko macOS. Na macOS, Windows i GNU/Linuksie.
- **pasek krawędziowy: podpis na obrazie kamery**: po rozwinięciu każda drukarka to jeden blok w kolumnie, a do następnej prowadzi cienka linia. Drukarka z podglądem to sam obraz kamery, pokazany w całości, bez przycinania i rozciągania; nazwa, procent, czas i pierścień leżą na jego dolnej krawędzi, na łagodnym przyciemnieniu, więc kamera nie zajmuje więcej miejsca niż jej obraz. Na macOS pod podpisem jest dodatkowo pas matowego szkła, który wyłania się od góry. Długa nazwa na obrazie mieści się w jednym wierszu i kończy wielokropkiem. Drukarki z podglądem są na górze, pozostałe pod nimi, w kolejności z floty. Drukarka z kamerą, której podgląd nie jest włączony, ma dopisek „Podgląd wyłączony”, a drukarka bez kamery „Bez kamery”, bez pustego miejsca na obraz. Gdy obraz przestaje przychodzić, miejsce zostaje i pokazuje „Brak obrazu”, a dane wydruku dalej się odświeżają. Na małym ekranie pasek się mieści: najpierw zmniejsza obrazy, potem zastępuje je dopiskiem „Za mało miejsca na podgląd”. Ciemne tło i sterowanie jego przezroczystością zostają bez zmian. Tak samo na macOS, Windows i GNU/Linuksie.
- **pasek krawędziowy pokazuje, ile zostało i o której koniec**: zamiast „75% · 1:16”, które łatwo brać za godzinę, jest „75% · 1h 16m · 15:42”, tak jak na kartach floty. Godzina zakończenia jest w formacie 12- lub 24-godzinnym, zależnie od ustawień systemu.
- **karty floty nie zlewają się ze sobą**: karta drukarki ma jaśniejsze, prawie nieprzezroczyste tło (`#1B1E21` przy 86%) i wyraźniejszą obwódkę (16% bieli zamiast 9%), a między kartami jest 12 pt odstępu w poziomie i w pionie. Karty zachowują szerokość 325 pt, a panel z dwiema kolumnami ma 645 pt zamiast 643; okno w trybie okna przyciąga się do siatki co 337 pt i startuje z szerokością 682 pt. Na macOS, Windows i GNU/Linuksie.

### Dodane

- **Gantry Vision: własny silnik rozpoznawania wpadek, w zestawie**: Gantry wozi teraz własny model i nie trzeba niczego wybierać. Jest uczony na szerokich kadrach z kamer w komorze, czyli dokładnie na takim obrazie, jaki Gantry naprawdę dostaje, i to jest cała różnica. Zmierzone na 62 takich klatkach przy domyślnej czułości: **22 awarie z 22 złapane, jeden fałszywy alarm na 40 poprawnych klatek**. Pobrany z sieci detektor YOLO, uczony na zbliżeniach, znalazł z tych samych 22 awarii jedną. Model waży 3 MB, liczy 2 ms na klatkę i działa w całości na Twoim Macu. Nazwa pokazywana na ekranie bierze się z metadanych modelu, więc nie zmienia się po przemianowaniu pliku. Własny plik Core ML dalej można wskazać w Ustawieniach i zastępuje wtedy silnik wbudowany, w pilnowaniu w tle i w przycisku „Testuj" jednocześnie. Szczegóły i pomiary w `docs/gantry-vision.md`.

- **wskazany model Core ML działa też w „Testuj" i nie budzi przez drobiazgi**: gdy wskażesz własny plik modelu, sprawdzenie ze zdjęcia i „Testuj" w Szczegółach pytają teraz właśnie jego, a nie klatek wzorcowych. Sprawdzanie jednego, a uruchamianie drugiego byłoby gorsze niż brak sprawdzania. Przy okazji Gantry rozumie nazwy klas, których używają pobierane detektory: „Successful Print" czy „no_defected" znaczą, że jest dobrze, a nitkowanie, pryszcze, nadmiar i niedomiar materiału to **skazy, nie wpadki**, więc są rozpoznawane i nazywane, ale nigdy nie wywołują ostrzeżenia. Wydruk z nitkowaniem kończy się i czyści nożem; wydruk ze spaghetti jest skończony. Zmierzone na prawdziwych klatkach z floty: jeden poprawny wydruk pobrany model nazwał nitkowaniem ze stuprocentową pewnością, więc bez tego pierwsza noc z takim modelem byłaby fałszywym alarmem.

- **sprawdzenie wykrywania na żywo, per drukarka**: w Szczegółach, nad podglądem, obok „Zaznacz defekt…" jest „Testuj". Bierze klatkę dokładnie z tej kamery, w tym świetle i z tego kadru, i odpowiada tak samo jak sprawdzenie ze zdjęcia w Ustawieniach, tylko z nazwą drukarki w nagłówku. Pyta o to, o co się naprawdę chce zapytać: nie „czy to działa w ogóle", tylko „czy działa na tej maszynie". Klatka idzie tą samą drogą co pilnowanie w tle, więc pytanie nie zabiera kamery podglądowi, który leci pod przyciskiem. Obie drogi liczą to samo w jednym miejscu, więc nie mogą zacząć odpowiadać inaczej.
- **sprawdzenie wykrywania na własnym zdjęciu**: w Ustawieniach, w Zaawansowanych, przy wykrywaniu wpadek jest „Sprawdź na zdjęciu…". Wskazujesz dowolne zdjęcie wydruku, udanego albo nie, i wyskakuje okno z tym zdjęciem i odpowiedzią: czy to wywołałoby ostrzeżenie, jak bardzo Gantry jest pewne, od ilu procent ostrzega przy obecnej czułości i z iloma klatkami wzorcowymi to porównało, w tym iloma Twoimi. Dotąd jedynym sposobem, żeby się dowiedzieć, czy to w ogóle działa, było zaczekać aż wydruk się wywali, co jest kiepskim momentem na takie odkrycie. Sprawdza rozpoznawanie po wyglądzie; obserwowania, jak wydruk zmienia się w czasie, nie da się odtworzyć z jednego zdjęcia, i okno mówi to wprost.

- **wpadka zostaje na karcie drukarki**: powiadomienie łatwo przegapić, można je zmieść nieprzeczytane, a godziny ciszy wyciszają je całkiem. Dlatego ostrzeżenie o możliwej wpadce zostaje też na karcie drukarki, z godziną i rodzajem, i wisi tam aż klikniesz OK. Karta nie jest dziennikiem: ta sama wiadomość nie powtarza się, a starsze ustępują miejsca, gdy zbierze się ich więcej niż trzy.

- **wykrywanie wpadek z kamery**: Gantry ogląda klatkę z każdej drukującej maszyny co kilkanaście sekund i ostrzega, gdy kilka razy z rzędu widzi to samo nieszczęście. Ostrzeżenie idzie jako powiadomienie i na Telegram, a klatka, która je wywołała, zapisuje się do zbioru, bo to najcenniejsze zdjęcie do dalszej nauki. Opcjonalnie wydruk może zostać wstrzymany, domyślnie nie jest. Działa od pierwszego uruchomienia, bez żadnego pliku i bez oznaczania czegokolwiek. Są trzy drogi i się uzupełniają. Pierwsza to **zachowanie wydruku**: kamera drukarki nigdy się nie rusza, więc Gantry nie musi wiedzieć, jak wygląda spaghetti, tylko jak wyglądał ten wydruk przez ostatnie kilkanaście minut. Normalny druk zmienia wąski pas przy dyszy i zostawia resztę kadru w spokoju; filament rozrzucony po stole zmienia cały kadr naraz i robi to dalej. Stąd dwie rzeczy, których nie da się pomylić z rosnącym wydrukiem: **spaghetti** (zmiana przestaje trzymać się dyszy i rozłazi się po kadrze, a obraz robi się znacznie gęstszy, niż był przez cały wydruk) i **oderwanie obiektu** (jedna gwałtowna klatka, po której zostaje obraz o wiele uboższy niż wszystko, co ten wydruk pokazywał, i taki zostaje na następnej). Wszystko to zwykła arytmetyka na pomniejszonej klatce, bez modelu i bez danych: przez pierwsze kilka minut Gantry tylko się przygląda i nic nie mówi, zmianę światła w komorze pomija, a każdą ocenę wystawia względem historii tego konkretnego wydruku, nie względem sztywnej liczby. Progi są wzięte z pomiaru na prawdziwej flocie: na poprawnie pracujących drukarkach rozrzut zmian między spojrzeniami wynosił od 0.14 do 0.51, więc próg stoi na 0.70, wyraźnie poza tym, co robi normalny druk. Druga droga to **rozpoznawanie po wyglądzie**. Gantry wozi 64 wzorce spaghetti policzone z 380 zdjęć na CC BY 4.0 (autorzy w `docs/defect-starter-attribution.md`); w pliku nie ma zdjęć, tylko liczby, których nie da się odwrócić z powrotem w obraz. Wzorców **poprawnego** druku Gantry nie wozi i nie będzie, bo nie da się ich przywieźć z zewnątrz: zdjęcia udanych wydruków z sieci są robione w dzień i z zewnątrz, a wpadki to zbliżenia z wnętrza komory, więc taki bank rozpoznaje nie „dobrze kontra źle", tylko „na zewnątrz kontra w środku", i klatkę z prawdziwej kamery bierze za spaghetti. Zmierzone uczciwie, z odłożoną całą jedną kamerą po każdej stronie, wychodziło do 37 fałszywych alarmów na sto poprawnych wydruków. Dlatego drugą połowę Gantry bierze z Twojej kamery: z klatek oznaczonych w Szczegółach i z kilku klatek, które **zachowuje samo**, gdy wydruk idzie dobrze, najwyżej trzy na wydruk, z jego środka, co najmniej osiem minut od siebie. Dopóki ich nie ma, rozpoznawanie po wyglądzie milczy, bo bank z jedną klasą nie ma z czym porównać, i zostaje samo zachowanie wydruku. Trzecia droga to **wskazany plik Core ML**, jeśli masz własny wytrenowany model, i wtedy zastępuje drugą. Gotowych detektorów z sieci Gantry nie wozi, bo ich licencje zabraniają rozdawania ich w cudzej aplikacji; ten bank jest policzony od zera ze zdjęć, które wolno i używać, i rozdawać dalej. Decyzja o alarmie jest osobnym, przetestowanym kawałkiem: potrzeba kilku zgodnych klatek z rzędu, jedna spokojna klatka nie kasuje trwającej wpadki, a o tej samej wpadce Gantry mówi raz, nie przy każdym spojrzeniu.
- **zaznaczanie defektów z podglądu kamery**: w Szczegółach, nad obrazem, jest „Zaznacz defekt…”. Wybierasz z listy, co widzisz (drukuje poprawnie, spaghetti, obiekt oderwany od stołu, blob na dyszy, przesunięcie warstw, coś innego), a Gantry zapisuje dokładnie tę klatkę razem z tym, co robił wydruk: drukarka, plik, warstwa, postęp, temperatury. Etykieta powstaje wtedy, gdy człowiek patrzy na obraz, więc jest warta więcej niż worek klatek do przejrzenia później. Zbiór ma twardy limit miejsca (domyślnie 500 MB, do zmiany w Zaawansowanych), a po jego przekroczeniu znikają najstarsze kadry, najpierw te poprawne, bo zwykły druk łatwo sfotografować jeszcze raz, a prawdziwej wpadki nie. Obok limitu jest licznik zdjęć i przycisk „Pokaż”, który otwiera katalog. Zdjęcia nigdzie nie wychodzą: leżą w Application Support obok reszty danych Gantry.
- **czuwanie Maca na skrót ⌃⌥⌘G**: most działa tylko wtedy, gdy Mac nie śpi, więc Gantry potrafi go w czuwaniu przytrzymać. Skrót działa z każdego programu, ikona w pasku menu robi się wtedy niebieska, a ten sam przełącznik jest w menu Gantry. W Ustawieniach, przy moście, jest osobny wybór „Nie pozwól Macowi zasnąć, gdy most działa”, który trzyma czuwanie tak długo, jak długo most chodzi. Gantry nie prosi o żadne zezwolenia i nie czyta tego, co piszesz: rejestruje jedną kombinację klawiszy w systemie, tak samo jak robi to skrót w menu. Skrót zawsze coś robi: gdy czuwanie trzyma most, naciśnięcie je wycisza i Mac znowu może zasnąć, a pole w Ustawieniach zostaje zaznaczone i wraca do pracy przy następnym starcie mostu. Przy wyjściu z Gantry czuwanie wraca do normy, więc zapomniany przełącznik nie zostaje na zawsze. Zamknięta klapa to osobna sprawa: żadna asercja jej nie zatrzyma, robi to dopiero systemowe `disablesleep`, czyli prawa roota. W Ustawieniach, przy moście, jest na to przycisk „Zezwól…”. Pyta raz o hasło administratora i zakłada jedną regułę w `/etc/sudoers.d`, która pozwala Gantry uruchomić dokładnie `pmset -a disablesleep 1` albo `0` i nic więcej: jeden użytkownik, pełne ścieżki, pełne listy argumentów, zero gwiazdek. Reguła jest sprawdzana przez `visudo` przed instalacją, więc nie da się nią popsuć sudo, a przycisk „Odbierz uprawnienie” kasuje ją w całości. Gantry wyłącza to ustawienie, gdy gaśnie przełącznik i gdy się zamyka, i nigdy nie rusza wartości, której samo nie włączyło. Dopóki uprawnienia nie ma, wiersz w menu mówi „tylko przy otwartej klapie”, więc niebieska ikona nie obiecuje nocy, której nie dowiezie.
- **własna strona w internecie**: Gantry potrafi pokazać flotę na stronie na Twoim serwerze i, jeśli tak ustawisz, przyjmować z niej polecenia. Aplikacja sama dzwoni do strony co kilka sekund, więc na routerze nie trzeba niczego otwierać ani mieć stałego adresu IP, a serwer nigdy nie poznaje adresu drukarki ani jej kodu dostępu. Obie strony podpisują każdą paczkę wspólnym kluczem. W Ustawieniach, w Integracjach, jest przełącznik „Strona może”: nic, tylko pokazywać flotę albo pokazywać i sterować. Wybór jest pilnowany w aplikacji, nie na stronie: przy samym podglądzie Gantry odrzuca każde polecenie i odsyła powód, a przy sterowaniu i tak decyduje drukarka, więc Bambu poza trybem Tylko LAN dalej nie da sobą sterować. Ze strony działa pauza, wznowienie, zatrzymanie, światło, temperatury dyszy i stołu, wentylatory, prędkość i pomijanie obiektów. Obraz z kamery leci tylko wtedy, gdy ktoś ma stronę otwartą, i na serwerze leży jedna nadpisywana klatka na drukarkę. Gotowa strona w PHP, bez bazy danych, jest w katalogu `web/` razem z instrukcją.
- **przycisk ustawień pod paskiem krawędziowym**: w spoczynku pod dolnym zakolem paska widać tylko ćwierć łuku, biegnącą równolegle do zakola. Po najechaniu ten sam okrąg wypełnia się w kółko z zębatką, a kliknięcie obraca zębatkę i otwiera Ustawienia od razu na zakładce „Okna i pasek”. Najechanie na przycisk nie rozwija zwiniętego paska. Zębatka jest rysowana, a nie brana z czcionki, więc wygląda tak samo na macOS, Windows i GNU/Linuksie. Pomysł pochodzi z projektu codenotch (licencja MIT).
- **ostrzeżenie o kończącym się filamencie także dla rolek spoza Bambu**: dotąd przychodziło tylko dla szpul Bambu z chipem RFID w AMS, więc przy innych rolkach nie było go wcale. Teraz rolka przypisana w Spoolbase ostrzega, gdy zostanie na niej 100 g lub mniej, według gramów, które Gantry odlicza po wydrukach; szpula z chipem nadal ostrzega przy 15%. Każdy slot ostrzega raz i znowu dopiero po założeniu pełniejszej rolki, także po ponownym połączeniu z drukarką. Próg 15% jest ten sam na macOS, Windows i GNU/Linuksie (na GNU/Linuksie było 10%).
- **powiadomienie „Skończył się filament”**: gdy drukarka Bambu zatrzymuje wydruk z braku filamentu, przychodzi powiadomienie z nazwą slotu i materiałem, np. „A3 • PLA: załóż nową rolkę, aby kontynuować.”, zamiast ogólnego „Wydruk wstrzymany”. Również na Telegramie.
- **Gantry LITE**: prace wstrzymane, edycja nie wchodzi do wydań. Druga edycja tej samej aplikacji, zbudowana z tych samych źródeł z wyłączonymi dodatkami (`scripts/build-app.sh lite`, `dotnet build -p:GantryEdition=lite`, `GANTRY_EDITION=lite linux/scripts/build-deb.sh`). Zostaje monitor: ikona w pasku menu/zasobniku, panel floty z kartami, dodawanie i wyszukiwanie drukarek wszystkich obsługiwanych marek, powiadomienia z godzinami ciszy oraz krótkie ustawienia — język, autostart, motyw, przezroczystość, kolory monochromatyczne i przełączniki zawartości karty. Znika Spoolbase, widok szczegółów, kamera, konserwacja z wykrzyknikiem alertu, automatyzacje, centrum diagnostyczne, statystyki floty, Telegram, panel webowy, tryb okna, pasek krawędziowy, przewodnik „Jak czytać Gantry", czyszczenie zakończonych druków, temperatura i wilgotność AMS na karcie, otwieranie kamery w Bambu Studio i slicera, a także cały moduł aktualizacji — LITE ich nie sprawdza ani nie instaluje. Osobna nazwa i identyfikator (macOS `pl.gantry.lite`, Windows `GantryLite.exe`, GNU/Linux pakiet `gantry-lite`), więc na macOS i Windows stoi obok pełnego Gantry; paczka macOS waży 4 MB zamiast 13 MB.

### Poprawione

- **okna zachowują się jak okna systemowe**: okno floty w trybie okna było domyślnie nad wszystkimi innymi oknami, więc nie dawało się go zasłonić, a alert Gantry otwierał się pod nim i trzeba było wachlować oknami, żeby zauważyć, o co pyta. Teraz jest zwykłym oknem; pinezka w nagłówku floty dalej je podnosi, gdy ktoś tego chce, a zapisane „na górze” z poprzednich wersji jest raz czyszczone, bo była to wartość fabryczna, nie wybór. Do tego każdy alert przechodzi przez jedno miejsce, które na czas pytania sprowadza wszystkie podniesione okna Gantry, także pasek krawędziowy, na zwykły poziom i po zamknięciu przywraca je na swoje. Żaden alert nie może już schować się za czymkolwiek, co należy do Gantry.
- **Ustawienia mieszczą się na ekranie**: strona internetowa i czuwanie mają własną zakładkę „Własna strona”, zamiast rosnąć pod Integracjami, aż okno zjeżdżało poza dolną krawędź ekranu. Każda zakładka przewija się, gdy jej treść jest wyższa niż ekran, a okno nigdy nie przekracza tego, co da się pokazać, więc ostatni wiersz zawsze da się doczytać. Dotyczy to także zakładki „Okna i pasek”, która była za wysoka już wcześniej. Osobne sprawdzenie w `scripts/check_settings_height.swift` mierzy każdą zakładkę i nie przepuści kolejnego takiego wzrostu.
- **tryb warsztatowy na GNU/Linuksie wywracał się przy pierwszej drukarce**: startował z niepełnym stanem aplikacji, więc już tworzenie karty drukarki kończyło się błędem. Teraz startuje z tym samym stanem co zwykłe Gantry. Kafelki aktualizują się w miejscu, zamiast przebudowywać cały ekran przy pierwszej odpowiedzi każdej drukarki i przy każdym błędzie, a pasek z błędem jest w nagłówku, więc nie przesuwa kafelków. Tryb warsztatowy nie zapisuje już ciemnego motywu do ustawień wspólnych ze zwykłym Gantry.
- **skakanie zmaksymalizowanego okna na GNU/Linuksie**: po każdej przebudowie kart Gantry dopasowywało wysokość okna do treści także wtedy, gdy okno było zmaksymalizowane albo na pełnym ekranie, a menedżer okien przerzucał je między dwoma rozmiarami. Takie okno nie jest już zmieniane.
- **wygryzione narożniki paska krawędziowego na GNU/Linuksie**: lewe narożniki rysowały się łukiem w złą stronę, więc w każdym zostawała okrągła dziura.
- **skaner kodów w Spoolbase zamrażał Gantry na GNU/Linuksie**: kamera była uruchamiana i zatrzymywana w głównym wątku, więc gdy nie dawała obrazu („Internal data stream error”), zatrzymanie potrafiło się nie skończyć i wszystkie okna Gantry przestawały odpowiadać. Teraz zmiany stanu kamery idą w osobnym wątku, błąd kończy skanowanie komunikatem, a zamknięcie okna nie czeka na kamerę. Skaner wybiera pierwszą kamerę V4L2 zamiast dowolnego źródła obrazu, a bez kamery od razu podpowiada wpisanie kodu w wyszukiwarkę. Przycisk w oknie dodawania filamentu nazywa się „Dodaj filament” zamiast „Dodaj drukarkę”.
- **Gantry Workshop na zwykłym pulpicie GNU/Linuksa**: pełnoekranowy widok warsztatowy dla Raspberry Pi był widoczny w menu aplikacji obok Gantry, a po uruchomieniu nie dawał się zamknąć. Nie miał przycisków okna, ignorował Alt+F4 i zamykanie z paska zadań, a do tego wyłączał wygaszanie ekranu do końca sesji. Teraz domyślnie otwiera się zwykła aplikacja, a tryb warsztatowy jest jej trybem: włączasz go w Ustawieniach, w panelu Zaawansowane, przyciskiem „Przełącz na tryb warsztatowy” (paczki DEB, RPM i Arch). W trybie warsztatowym Konfiguracja ma przyciski „Otwórz zwykłe Gantry” i „Zakończ tryb warsztatowy”. Oba tryby korzystają z tych samych drukarek i ustawień, a start po zalogowaniu przechodzi razem z przełączeniem. Ctrl+Q, Alt+F4 i zamknięcie z paska zadań pytają, co zrobić, wygaszanie ekranu wraca po wyjściu, a skrót Gantry Workshop nie pokazuje się w menu (autostart ustawiany przez `gantry-kiosk-setup` działa jak dotąd).

## 0.12.0 - 2026-09-15

Wydanie po raz pierwszy pozwala wpłynąć na trwający wydruk: sterowanie temperaturami, wentylatorami i prędkością z widoku szczegółów oraz pomijanie obiektów. Pasek krawędziowy dostaje kamery, pinezkę, wybór monitora i sześć miejsc na ekranie, panele pomocnicze trafiają do własnych okien, a ustawienia wyglądają jak systemowe. Druga połowa to przegląd niezawodności z audytu. Na Bambu Lab sterowanie działa tylko lokalnie, w trybie Tylko LAN z włączonym Trybem deweloperskim. Pełny opis: `docs/release-0.12.0.md`.

Paczki: macOS (dmg oraz zip w wariantach Local i Keychain), Windows (instalator i wersja przenośna zip) i GNU/Linux (deb, rpm i AppImage). Edycja LITE nie jest wydawana.

### Dodane

- **pasek krawędziowy na wybranym monitorze i w jednym z sześciu miejsc**: w ustawieniach lista monitorów („Monitor główny” albo konkretny monitor z nazwą i rozdzielczością) oraz mały ekran z sześcioma kwadracikami: u góry, na środku i na dole lewej lub prawej krawędzi. „U góry” i „na dole” trzymają się jednej piątej wysokości od brzegu, poniżej paska menu i powyżej paska zadań, a rozwinięty pasek rośnie w stronę środka ekranu. Te same wybory są w podmenu „Pasek krawędziowy” w menu Gantry na macOS, Windows i GNU/Linuksie. Wybrany monitor jest rozpoznawany także po zmianie jego identyfikatora (położenie i rozmiar z tolerancją 8 px); gdy jest odłączony, pasek czeka na monitorze głównym i wraca po ponownym podłączeniu. Na krawędzi wspólnej z drugim monitorem pasek rozwija się dopiero po chwili postoju kursora, więc nie otwiera się przy przejściu na sąsiedni ekran. Pomysły na rozpoznawanie monitora i przejście między ekranami pochodzą z projektu Edge-Drop.

### Poprawione

- **karty drukarek nie ucinają przycisków**: karta jest szersza (325 zamiast 285 punktów, panel 643 zamiast 563 przy dwóch kolumnach i 420 zamiast 380 przy jednej). W nagłówku alert, konserwacja, pomijanie obiektów, uchwyt i menu zawsze mieszczą się w karcie; gdy brakuje miejsca, najpierw chowa się pigułka połączenia, a nazwa oddaje resztę. Długa nazwa drukarki i nazwa pliku nie łamią się na dwa wiersze, tylko przewijają do końca po najechaniu kursorem, na macOS, Windows i GNU/Linuksie. Na Windows panel rośnie razem ze skalą karty, więc powiększona karta zachowuje proporcje zamiast rosnąć w górę i tracić treść z boku.
- **pasek krawędziowy przy kilku monitorach**: na macOS podążał za ekranem z aktywnym oknem i potrafił przeskakiwać między monitorami, na Windows brał krawędź z całego pulpitu, a wysokość z monitora głównego, więc przy monitorach różnej wysokości mógł wisieć krzywo, a na GNU/Linuksie zawsze stał na monitorze głównym.
- **procesy ffmpeg na Windows kończą się razem z Gantry**: każdy podgląd kamery Bambu po RTSP i Anycubic ma własny dekoder ffmpeg. Przy zwykłym zamknięciu Gantry kończyło je samo, ale gdy aplikację zamknął instalator aktualizacji, Menedżer zadań albo awaria, dekodery zostawały w pamięci, blokowały plik `ffmpeg.exe` przy aktualizacji i zajmowały procesor. Teraz system kończy je razem z Gantry niezależnie od sposobu zamknięcia.
- **kamera Elegoo Centauri Carbon**: podgląd na żywo nie łączył się, choć zdjęcia z kamery działały. Gantry wysyłało polecenie włączenia strumienia i od razu otwierało port 3031, nie czekając na odpowiedź drukarki, a strumienia nigdy nie wyłączało, więc jedyne miejsce na podgląd zostawało zajęte do restartu drukarki. Teraz na macOS, Windows i GNU/Linuksie wszystkie podglądy jednej drukarki (szczegóły, pasek krawędziowy, zdjęcia z Telegrama) dzielą wspólną bramkę: pierwszy czeka na potwierdzenie, ostatni po kilku sekundach wyłącza strumień. Odmowa drukarki pokazuje powód (limit jednego podglądu, brak kamery), strumień bez obrazu jest ponawiany i ma limit czasu zamiast wiecznego „Łączenie z kamerą…”, klatki bez tablic Huffmana dostają standardowe tablice, a obraz, którego nie da się odczytać, jest zgłaszany zamiast po cichu pomijany. Na macOS podział strumienia na klatki nie przeszukuje już całego bufora dla każdego bajtu.

## 0.11.0 - 2026-09-07

Wydanie wyprowadza monitorowanie poza komputer i porządkuje to, co zostało w środku. Powiadomienia i sterowanie trafiają na Telegram, drukarki zyskują plan konserwacji, historię wydruków i centrum diagnostyczne, a napisy przenoszą się do wspólnego katalogu, w którym nowy język to jeden plik. Dochodzi obsługa Anycubic Kobra S1, pasek krawędziowy i przepisane okno ustawień. Synchronizacja między komputerami zostaje wycofana.

### Najważniejsze

- **powiadomienia i sterowanie przez Telegram**: własny bot użytkownika, alerty o zakończeniu, błędzie, pauzie i niskim filamencie, komendy `/status`, `/all`, `/spools`, `/history`, `/watch`, `/mute` oraz zdjęcia z kamery na trzech systemach;
- **konserwacja i historia**: cztery zadania serwisowe rozliczane w godzinach faktycznego druku, z odkładaniem i własnymi interwałami, obok listy ostatnich wydruków i statystyk skuteczności;
- **centrum diagnostyczne**: sprawdza całą flotę, pokazuje opóźnienie i ocenę jakości połączenia, z twardym limitem trzech sekund na drukarkę;
- **wspólny katalog tłumaczeń** w `i18n/`, kluczowany angielskim napisem źródłowym; nowy język to jeden plik wrzucony do katalogu, bez zmian w kodzie i bez nowego wydania;
- **Anycubic Kobra S1** przez lokalne MQTT/TLS w trybie LAN, bez konta w chmurze producenta;
- **statystyki floty** z eksportem do pliku tekstowego, na macOS, Windows i GNU/Linuksie;
- **pasek krawędziowy**: wąski panel przy krawędzi ekranu, zawsze na wierzchu, z pierścieniem postępu na drukarkę, domyślnie wyłączony;
- **nowe okno ustawień**: trzy zakładki zamiast jednej długiej listy, ten sam podział na trzech systemach;
- **tryb okna**: ten sam pulpit floty odpięty od paska menu jako zwykłe okno pulpitu, z własnym zapamiętanym rozmiarem, natywną ramą, obecnością w pasku zadań i pinezką „zawsze na wierzchu". Zamknięcie okna chowa Gantry zamiast kończyć program, a ikona przywraca je z powrotem. Przełącznik w nagłówku panelu i w Ustawieniach, domyślnie wyłączony;
- **ekran łączenia przy starcie**: karty nie pojawiają się z pustymi wartościami, tylko po pierwszej telemetrii, z zejściem po piętnastu sekundach albo na kliknięcie;
- **przewodnik po karcie** przy pierwszym uruchomieniu, pokazywany raz, do otwarcia ponownie z nagłówka;
- **alert przed końcem druku**, domyślnie wyłączony;
- **instalator Windows schudł z 91 do 52 MB**, a paczka ZIP ze 130 do 76 MB.

### Zmienione

- **karta drukarki jest krótsza o rząd wielkości jednego wiersza**, bez utraty jakiejkolwiek informacji: procent przeniósł się do linii statusu, czas i warstwy stanęły obok paska postępu, a etykiety temperatur obok wartości zamiast nad nimi. Zmierzone: macOS ze 134 do 102 punktów, GNU/Linux z 220 do 191 pikseli. Zmiana obejmuje macOS, Windows i GNU/Linuksa;
- **kafelek szczegółów na karcie** dostał własny przełącznik w Ustawieniach, w sekcji Karty drukarek, domyślnie wyłączony, na trzech systemach;
- **kontrakt układu karty pilnuje teraz wariantu B** osobno dla każdego systemu (rozmiar procentu, wysokość wiersza temperatur, obecność przełącznika kafelka), więc rozjazd między platformami zatrzyma budowanie;
- **przełącznik Spoolbase gasi teraz całą funkcję**, a nie tylko pozycję w menu. Przy wyłączonym Spoolbase kliknięcie slotu AMS nie otwiera okna przypisania, karta pokazuje surowe odczyty z AMS zamiast danych przypisanej rolki, po skończonym wydruku nic nie jest odejmowane, a tag NFC nie odpina przypisań. Rolki zostają nietknięte, więc ponowne włączenie wraca do stanu sprzed wyłączenia. Dotąd macOS i Windows ignorowały ten przełącznik poza kartą, a Linux blokował sam klik;
- **wydania budowane są w konfiguracji release**, wcześniej skrypt pakował build debug.

### Naprawione

- **temperatura komory na H2D i X2D**: po włączeniu podgrzewania pojawiało się `4259904` zamiast 64 stopni, bo drukarka pakuje w to pole odczyt i nastawę naraz, a parsery czytały je surowo;
- **konserwacja pokazywała `78.52096950885323 h`** zamiast `78.5`; podstawianie liczb ma teraz własne formatowanie, więc błąd nie może się powtórzyć w kolejnym miejscu;
- **nakładka drukarki offline zasłaniała menu karty**, przez co niedostępnej drukarki nie dało się wyedytować ani usunąć;
- **powiadomienia systemowe na Windows 11**: rejestracja odbywa się na wątku STA aplikacji, z powrotem do dymka w zasobniku, gdy powiadomienia są wyłączone;
- **sekcja AMS przestała skakać** w oknie szczegółów;
- **wentylatory na drukarkach Klipper**: odpytywane są wszystkie wentylatory, jakie maszyna wystawia, nie tylko obiekt o nazwie `fan`;
- **kamera Anycubica na macOS** (wydania nie zawierały wymaganego ffmpeg) oraz **kamera P1 i A1 na macOS** przez strumień JPEG na porcie 6000;
- **podsumowanie reguły automatyzacji na macOS** pokazuje linijkę „wyzwalacz, akcja", tak jak na Linuksie;
- **karta na Linuksie nie wywala się już przy pustej liście dysz**: pamięć o drugiej dyszy jest celowo trwała, żeby częściowy pakiet nie zwijał karty dwudyszowej, ale odwołania do listy dysz nie znosiły pakietu bez dysz ani karty budowanej przed pierwszą telemetrią.

### Usunięte

- **synchronizacja między komputerami** została w całości wycofana z macOS, Windows i GNU/Linuksa. Aplikacja nie wysyła już niczego do innych komputerów, nie przyjmuje zapisów przez sieć i nie przechowuje tokenu parowania ani listy sparowanych maszyn. Podgląd floty w przeglądarce zostaje i pozostaje tylko do odczytu. Dane lokalne nie są kasowane, przestaje działać wyłącznie ich przenoszenie między maszynami.

Pełny opis wydania: [`docs/release-0.11.0.md`](docs/release-0.11.0.md).

## 0.10.0 - 2026-09-01

To wydanie ujednolica macOS, Windows i GNU/Linux wokół dopracowanego interfejsu oraz flow wersji macOS. Windows i Linux otrzymują zgodny pulpit, proporcje sekcji AMS / AMS HT / EXT, krótkie pastylki filamentu, spójne okna Szczegółów, Ustawień, edycji i dodawania drukarki, a także poprawione Spoolbase i przypisywanie fizycznych rolek.

### Najważniejsze

- dodano obsługę **Elegoo Centauri Carbon (CC1)** przez lokalny SDCP/WebSocket oraz **Centauri Carbon 2 (CC2)** przez lokalny MQTT w trybie LAN-only, wraz z wykrywaniem, telemetrią i kamerą MJPEG;
- zmiana motywu i przezroczystości odświeża interfejs natychmiast, także na Windows, bez przechodzenia do Szczegółów lub restartu;
- ujednolicono zachowanie przycisków głównego paska, nawigację widoku Szczegółów i obsługę okien dodatkowych;
- dodano automatyczny kontrakt zgodności UI dla macOS, Windows i Linux oraz testy układu kart;
- przygotowano workflow i skrypty budowania Linuxa jako `.deb`, `.rpm` oraz przenośnego `.AppImage`.

### GNU/Linux

Pakiety Linux dla 0.10.0 są **w przygotowaniu** i przechodzą testy integracyjne. `.deb` i `.rpm` zapewnią klasyczną instalację systemową, a `.AppImage` będzie pojedynczym przenośnym plikiem z aplikacją i większością wymaganych bibliotek.

Pełny opis wydania: [`docs/release-0.10.0.md`](docs/release-0.10.0.md).

## 0.9.0 - 2026-08-29

Dalej dopracowujemy wygląd i wydajność oraz sukcesywnie dodajemy personalizację. W tym wydaniu dochodzą też duże rzeczy: **śledzenie fizycznych rolek filamentu w Spoolbase** (z automatycznym odejmowaniem wagi po wydruku), **podgląd floty w przeglądarce**, **synchronizacja między komputerami**, a na macOS **uniwersalny build (Intel + Apple Silicon)**. Na Windows dochodzi natywny efekt szkła i dopracowanie karty do parytetu 1:1 z macOS.

Najważniejsze: to wydanie domyka **parytet na trzech platformach**. Linux dostaje pełny komplet nowości i nadrabia to, co dotąd było tylko na macOS/Windows: **widok „Szczegóły”, automatyzacje ze sterowaniem i podgląd kamery na żywo**, a do tego fizyczne rolki z odejmowaniem wagi, podgląd floty w przeglądarce, synchronizację i efekt szkła. Ten sam zestaw funkcji i ten sam układ karty działają teraz na macOS, Windows i Linux; różni się tylko natywny rendering każdego systemu (czcionki, sposób realizacji frosted‑glass).

### Fizyczne rolki filamentu (nowość)

Do tej pory Spoolbase znał tylko rodzaje filamentu. Teraz możesz prowadzić konkretne rolki z wagą, przypisane do slotów AMS/EXT. Stan należy do rolki, nie do slotu, więc gdy przełożysz ją do innej drukarki, gramy jadą razem z nią.

Jak dodać filament do AMS, krok po kroku:

1. Kliknij pastylkę slotu (fasolkę AMS albo EXT) na karcie drukarki. Otworzy się panel przypisania dla tego slotu (np. „AMS A2").
2. Panel pokazuje materiał widziany przez AMS, aktualnie przypisaną rolkę (albo „Brak") i listę Twoich rolek.
3. Masz już rolkę w bazie? Wybierz ją z listy. Pasujące materiałem i kolorem są na górze i podświetlone. Jeśli rolka jest w innej drukarce, Gantry zapyta „Przenieść tutaj?" i zwolni poprzedni slot.
4. Nowa rolka? Kliknij „+ Nowa rolka":
   * wybierz filament ze swojego katalogu Spoolbase (albo „Nowa definicja z AMS", która weźmie materiał i kolor prosto z drukarki),
   * podaj ilość na start: 1000, 750, 500 g albo własną wartość,
   * gotowe. Rolka dostaje własne ID, np. `SP-00001`.
5. Od teraz slot pokazuje realny procent i gramy (liczone lokalnie z pozostałej wagi), w kolorze wybranego filamentu, nawet dla filamentu bez RFID.
6. Wymiana lub zdjęcie: kliknij slot ponownie i użyj „Odepnij", albo przypisz inną rolkę.
7. Przenoszenie między drukarkami: wyjmujesz rolkę, w drugiej drukarce klikasz slot i wybierasz tę samą rolkę (`SP-000xx`). Stan zostaje bez zmian.

Działa dla AMS i zewnętrznej szpuli (EXT), wspólnie dla wszystkich drukarek, dane są trwale zapisywane. Jedna rolka może być tylko w jednym miejscu naraz.

Jeśli do slotu z ręcznie przypisaną rolką **włożysz rolkę z tagiem NFC/RFID**, Gantry rozpozna, że tamta rolka została wyjęta, i **automatycznie odpina** przypisaną (wraca do magazynu). Na karcie pojawia się wtedy krótka informacja z przyciskiem **OK**, np. „SP-00003 wróciła do magazynu (wykryto tag NFC w AMS A3)".

### Automatyczne odejmowanie wagi po wydruku (nowość)

Po zakończonym wydruku Gantry odejmuje realnie zużyty filament od przypisanej rolki, lokalnie i bez chmury:

* **Klipper / Moonraker:** realne `filament_used` (mm) przeliczone na gramy (Ø1,75),
* **Bambu:** `used_g` z wydrukowanego pliku `.gcode.3mf` pobranego po **lokalnym FTPS** (bez logowania do chmury, bez chmury Bambu).

Odejmowanie jest **idempotentne per zadanie**, więc reconnect, restart albo dwa komputery patrzące na tę samą drukarkę nie policzą zużycia podwójnie.

### Gramy z AMS (tag NFC/RFID)

* nowy przełącznik w Ustawieniach, w sekcji „Karty drukarek": **„Gramy na rolce (AMS NFC / Spoolbase)"**, domyślnie wyłączony,
* po włączeniu pod slotem widać pozostałe gramy: dla rolek Bambu **z tagiem RFID/NFC** liczone z odczytu tagu (`tray_weight × remain%`), a dla rolek przypisanych w Spoolbase z ich wagi,
* rolka bez tagu i bez przypisania nie ma skąd wziąć wagi (można przypisać rolkę Spoolbase).

### Podgląd floty w przeglądarce (nowość)

* lekki, **tylko do odczytu** serwer WWW w sieci lokalnej: całą flotę widać z telefonu albo innego komputera w tej samej sieci Wi-Fi, bez logowania i bez chmury,
* **na żywo przez WebSocket** (push przy każdej zmianie), z automatycznym fallbackiem na odpytywanie,
* ta sama estetyka co aplikacja: karty, kolorowe temperatury, sloty AMS/EXT, procent,
* w Ustawieniach nowa sekcja z **adresami** (`<nazwa>.local` i IP), **kodem QR** do zeskanowania telefonem oraz **przełącznikiem włączania serwera** (wyłączony = zero otwartych portów).

### Synchronizacja między komputerami (nowość)

* dwukierunkowa synchronizacja **Spoolbase, listy drukarek i ustawień** między Twoimi komputerami, **tylko w sieci lokalnej** (bez chmury),
* parowanie przez **wspólny token**: kopiujesz go z jednego komputera na drugi i podajesz adres, reszta dzieje się sama,
* scalanie „ostatni wygrywa" po czasie; zużycie filamentu jest idempotentne, więc wspólny wydruk nie odejmie się podwójnie,
* **kody dostępu do drukarek nie są przesyłane** (zostają w Keychain każdego komputera).

### Uniwersalny build macOS i niższy próg systemu

* aplikacja macOS jest teraz **uniwersalna (Apple Silicon + Intel)** — koniec z przekreśloną ikoną i komunikatem „tylko na układach Apple" na Intelu,
* **obniżony próg do macOS 13 (Ventura)**: jedyne API blokujące starsze systemy (efekt „liquid glass") ma teraz łagodny fallback.

### Windows: natywny efekt szkła i parytet karty z macOS

* główny dymek to teraz prawdziwy **Desktop Acrylic** (rozmyte tło pulpitu pod ciemnym, półprzezroczystym tintem, zaokrąglone rogi); przełącznik **Przezroczystość (Mała / Średnia / Duża)** steruje tylko siłą tintu, bez restartu, z fallbackiem na solidny ciemny panel,
* karta dopracowana do macOS: **wordmark GANTRY** i licznik „X drukarek · Y pracuje", **ikona wykresu** zamiast napisu „Szczegóły", uchwyt przeciągania i „⋯" w zaokrąglonych pigułkach, temperatury z **„/ —"** przy braku wartości zadanej, **kreskowanie** pustych slotów, karta offline bez dublowania komunikatu.

### Linux: parytet funkcji z macOS

* **widok „Szczegóły”**: wykres temperatur w czasie (dysza / stół / komora), temperatury z wartościami zadanymi, wentylatory (części / aux / komora), poziom prędkości i średnica dyszy, moduły AMS/EXT oraz postęp / warstwy / ETA; wejście z ikony wykresu na karcie i z menu,
* **automatyzacje ze sterowaniem**: reguły per drukarka (wyzwalacz: po warstwie / po % / na stan; akcja: światło komory, pauza/wznów/stop, powiadomienie, własna komenda MQTT/G‑code, skrypt), odpalane raz na wydruk; akcje „komenda” i „skrypt” są domyślnie wyłączone i wymagają jednorazowej zgody (kill‑switch w Ustawieniach),
* **podgląd kamery na żywo**: Bambu przez RTSPS:322 (ffmpeg jako dekoder H.264, akceptacja self‑signed), Klipper/Moonraker jako MJPEG czytany natywnie; wejście z karty i z Szczegółów,
* **fizyczne rolki w Spoolbase**: klik w slot AMS/EXT otwiera panel przypisania (rolka z katalogu, nowa rolka, przeniesienie istniejącej, ustawienie pozostałych gramów, odłączenie do magazynu); slot pokazuje kolor i gramy przypisanej rolki,
* **automatyczne odejmowanie wagi po wydruku** (Klipper realnie z `filament_used`, Bambu z `used_g` w `.gcode.3mf` pobieranym po FTPS), idempotentne per zadanie,
* **auto‑odpięcie** przy włożeniu rolki z tagiem NFC/RFID, z **krótką informacją na karcie** i przyciskiem OK,
* **podgląd floty w przeglądarce** i **dwukierunkowa synchronizacja** (Spoolbase, katalog filamentów, lista drukarek i ustawienia) w sieci lokalnej, zgodna z macOS/Windows,
* frosted‑glass dymka tray (rozmycie na KWin, przezroczystość w innych środowiskach).

### Personalizacja

* Przełącznik kolumn 1 / 2 w nagłówku (szeroka lub ostatnia samotna karta zajmuje pełną szerokość, zasada 2-2-1).
* „Karty drukarek" w Ustawieniach: włącz albo wyłącz Nazwę pliku, Postęp, Temperatury, Filamenty / AMS (a teraz również Gramy na rolce).
* „Dostosuj…" w Szczegółach: ukryj moduły (Kamera, AMS, Temperatury, Wentylatory, Sterowanie), przestawiaj kafle, wróć do domyślnego układu.

### Spokojniejsze, płaskie karty

* Stonowana kolorystyka: stan czyta się z tekstu i ikony, kolor niosą tylko wartości temperatur i realne kolory filamentu.
* Płaski układ: zamiast pudełek w pudełku sekcje (zadanie, temperatury, filamenty) rozdzielają długie, cienkie linie. Między urządzeniami (AMS, HT, EXT) delikatna pionowa kreska.
* Temperatury: kolor tylko na liczbie (dysza, stół, komora), a kafel komory znika, gdy nie ma czujnika.
* Filamenty: procent wewnątrz kolorowej fasolki z auto-kontrastem, poziom wypełnia się od dołu z delikatną falą, a każdy kafelek ma cienki obrys, więc pusta lub 0% rolka nie ginie.
* **Sloty pojedyncze (AMS HT / EXT)** to szerszy, wyśrodkowany prostokąt skalujący się z kartą (35% kolumny, min 60 px); grupa AMS jest ~3× szersza od pojedynczej, a dwie pojedyncze obok siebie (HT + EXT) są równe. Sloty nie migają ani nie skaczą przy odświeżaniu.

### Offline

* Gdy drukarka traci połączenie, jej karta przygasa i pokazuje komunikat błędu. Menu i Szczegóły dalej są dostępne.

### Poprawki

* **Nazwa pliku po wydruku:** karta pokazuje nazwę zadania tylko podczas druku; po zakończeniu i w bezczynności wraca „BRAK AKTYWNEGO ZADANIA" (koniec ze starą nazwą wiszącą po zakończeniu i po odświeżeniu).
* **[#27] Fałszywy „Filament low" dla rolek bez chipa:** ostrzeżenie (czerwona kropka i powiadomienie) odpala się tylko przy wiarygodnym odczycie poziomu, czyli tag RFID/NFC (waga) albo przypisana rolka Spoolbase; rolka bez chipa (remain=0 „nieznane") już nie wywoła alarmu.

### Pod maską

* Segmentowy pasek postępu, licznik warstw przy ETA (pełna nazwa pliku przestała się ucinać).
* Kompaktowy nagłówek i węższe okno, więcej drukarek na ekranie.

## 0.8.0 — 2026-08-20

Duże wydanie: pełny widok **„Szczegóły"** drukarki, **podgląd kamery na żywo**, **automatyzacje ze sterowaniem** i **nadpisania per‑drukarka** — najpierw na macOS, a w tym wydaniu doprowadzone do **parytetu 1:1 na Windows**.

### Szczegóły drukarki (nowość)

- nowy widok **„Szczegóły"** otwierany **w obrębie głównego dymka** (z przyciskiem **„‹ Wróć"**), nie jako osobne okno — spójnie na macOS i Windows
- wejście prosto z karty: **widoczny przycisk „Szczegóły"** przy nazwie (oraz nadal z menu ⋯)
- zawartość: **wykres temperatur w czasie** (dysza / stół / komora), temperatury z wartościami zadanymi, **wentylatory** (part / aux / komora), **poziom prędkości** i **średnica dyszy**, **AMS/filamenty** tym samym widokiem co okno główne (AMS / AMS+EXT / EXT / AMS HT) z **pozostałym %** i wizualnym wypełnieniem szpuli, oraz postęp / warstwy / ETA
- **kafle Szczegółów można przestawiać** metodą przeciągnij‑i‑upuść (uchwyt ⠿); kolejność jest zapamiętywana
- widok tylko‑do‑odczytu jest domyślny; sterowanie pojawia się w trybie deweloperskim

### Kamera na żywo

- **Bambu (macOS):** natywny odbiór **RTSPS na porcie 322** (`rtsps://…/streaming/live/1`, LIVE555, autoryzacja Digest) — działa nawet przy połączeniu z chmurą, wystarczy **„LAN Mode Live View"** na drukarce; dekodowanie H.264 przez VideoToolbox. Zastępuje nieskuteczny na nowszym firmware strumień portu 6000
- **Bambu (Windows):** własny natywny klient **RTSPS/RTSP/JPEG** — aplikacja sama nawiązuje TLS i **akceptuje self‑signed certyfikat drukarki**, a `ffmpeg` służy wyłącznie jako dekoder H.264 (bez sieci/TLS). Kolejność prób **322 → 554 → 6000** (A1/P1), autoryzacja Digest/Basic. W rogu obrazu **plakietka trybu i rozdzielczości** (np. `RTSPS · 1920×1080`)
- **Klipper / Creality (Moonraker):** podgląd jako **MJPEG** (z `/server/webcams/list`, fallback `/webcam/?action=snapshot`)
- czytelne komunikaty, gdy drukarka nie oddaje obrazu (np. wyłączony podgląd LAN)

### Automatyzacje i sterowanie

- Gantry potrafi teraz **wysyłać komendy** (dotąd tylko czytał): **światło komory**, **pauza / wznów / stop**
- **silnik reguł „raz na wydruk":** wyzwalacz (ręcznie / po warstwie ≥ N / po ≥ % / zmiana stanu) → akcja: **LED**, **pauza/wznów/stop**, **powiadomienie**, **własna komenda** (Bambu: JSON MQTT / Klipper: G‑code) lub **skrypt**
- **skrypty własne:** wskazanie pliku albo **wklejenie kodu** z obsługą **shebang** (`#!/usr/bin/env python3` itd.), więc można wklejać czysty kod `.py`
- osobny **edytor reguł** (dodaj / edytuj / usuń, Uruchom / Stop, skrypt z potwierdzeniem)
- reset licznika reguł następuje **tylko przy realnym końcu wydruku** (idle/finished) — koniec z regułą odpalaną w kółko (np. gaszeniem lampy) przez chwilowe gubienie nazwy zadania w raportach MQTT
- dokumentacja: **[`docs/automations.md`](docs/automations.md)** — komendy, przykłady skryptów i przepisy (w tym Python)

### Nadpisania per‑drukarka („Zaawansowane…")

- **opcjonalne IP kamery** — gdy kamera jest pod innym adresem niż drukarka (np. Raspberry Pi z kamerą)
- **własne komendy światła** wł./wył. (Bambu: JSON MQTT / Klipper: G‑code)
- **nazwy obiektów Moonraker** dla niestandardowych konfiguracji Klippera: **dysza / stół / czujnik komory / wentylator** (puste = domyślne/auto); zapis od razu ponawia połączenie

### Tryb deweloperski

- nowy przełącznik w Ustawieniach; odsłania **kafel „Sterowanie i automatyzacje"** w Szczegółach oraz (macOS) diagnostyczny **podgląd surowego AMS** (JSON `ams`/`vt_tray`/`vir_slot`)

### Parytet Windows (1:1 z macOS)

- pełna migracja powyższych funkcji na Windows: Szczegóły, telemetria wentylatorów / prędkości / ⌀ dyszy, historia temperatur, sterowanie + automatyzacje, nadpisania per‑drukarka, tryb deweloperski i kamera

### Wygląd i poprawki

- **spokojniejsze okno główne (macOS):** karty nie zalewają się kolorem stanu — kolor zostaje na kropce, pasku i tekście, błąd to cienka statyczna krawędź; „Szczegóły" jako stonowany chip z obrysem
- **Windows:** po wejściu i wyjściu ze Szczegółów okno od razu dobiera właściwą wysokość (bez chwilowego „za dużego" okna)
- pod maską: kamera Bambu na Windows przez statyczny `ffmpeg.exe` (dokładany przez CI) zamiast LibVLC, który nie obsługiwał schematu `rtsps://`

## 0.6.0 — 2026-08-09

- **Linux hotfix:** jawne przypięcie `Gdk 3.0`, `Gtk 3.0`, `GLib 2.0` i `Pango 1.0` przed importem PyGObject; usuwa awarię startu na Ubuntu 26.04, gdy równolegle zainstalowane są biblioteki GTK 3 i GTK 4
- **nowa nazwa i logo: Gantry** — litera **G** na pasku menu / w zasobniku i jako ikona aplikacji (macOS `.icns`, Windows `.ico`); zapisane drukarki, kody i uprawnienia pozostają bez zmian
- **modularny filament** — każdy fizyczny moduł (AMS, AMS HT, CFS, MMU, EXT) to osobna grupa z własną nazwą, wilgotnością i temperaturą; AMS HT / pojedyncza szpula pokazują 1 slot, standardowy AMS trzyma 4 pozycje (puste zostają szare)
- **Creality CFS** — każdy box jako osobny zestaw (`CFS 1`, `CFS 2`), szpula zewnętrzna jako `EXT`; **Klipper / Happy Hare** — dowolna liczba bramek `T0…Tn` bez sztucznego dzielenia po cztery
- **dwie dysze** na drukarkach dwudyszowych (H2D) pokazywane jawnie jako **L / P** (PL) lub **L / R** (EN); **temperatura komory** tylko dla drukarek z realnym czujnikiem
- **prywatność: import konfiguracji Bambu Studio za jawną zgodą** — nic nie jest czytane z plików slicera, dopóki nie zaznaczysz zgody (checkbox + komunikat) przy dodawaniu drukarki
- przeprojektowane kafle: duże kafelki koloru z etykietą pod spodem, aktywny slot z białym pierścieniem, równa wysokość kafli w wierszu
- **poprawka:** biała ramka aktywnego slotu AMS nie znika już po połączeniu — częściowy raport MQTT nie kasuje aktywnego slotu ani grup
- ten sam model danych i układ na macOS, Windows i GNU/Linux

## 0.5.0 — 2026-08-05

- dodano pierwszą wersję beta **Gantry dla GNU/Linux** z interfejsem GTK 3 i ikoną w zasobniku systemowym
- wersja Linux łączy się bezpośrednio z drukarkami Bambu przez MQTT/TLS, pokazuje stan, postęp, ETA, warstwy, temperatury oraz sloty AMS
- dodano w Linux i kiosku RPi wybór **Bambu Lab / Klipper / Prusa**; Moonraker obsługuje status, temperatury, ETA, Happy Hare MMU i Creality CFS, a PrusaLink status, postęp, czas, temperatury i nazwę pliku
- formularz dodawania, panel telefonu oraz import CSV rozpoznają typ drukarki i właściwe porty: Bambu `8883`, Moonraker `7125`, PrusaLink `80`
- dodano automatyczne wykrywanie przez SSDP i certyfikat MQTT, ręczne IP i port oraz dodatkowe cele VPN w formie IP, zakresu lub CIDR
- kody dostępu są przechowywane w systemowym Secret Service, a certyfikaty drukarek przypinane po pierwszym zaufanym połączeniu (TOFU)
- dodano import konfiguracji Bambu Studio z natywnych i Flatpakowych lokalizacji GNU/Linux
- dodano język polski i angielski, jasny i ciemny wygląd, powiadomienia, autostart po zalogowaniu oraz tryb zwarty dla większej liczby drukarek
- dodano paczkę instalacyjną `.deb`, testy rdzenia i lokalnie przygotowany workflow budowania dla Ubuntu
- dodano tryb **Gantry Workshop** dla Raspberry Pi: pełnoekranowy kiosk, układ monitoringu większej floty, alerty, bezpieczny panel WWW ze statusem drukarek oraz automatyczny start po zalogowaniu
- dodano lokalny panel konfiguracji HTTPS dostępny z telefonu lub komputera, chroniony sześciocyfrowym kodem parowania wyświetlanym na ekranie
- dodano masowy import drukarek z CSV (`kind,name,host,serial,access_code,port`), pobieranie i lokalne generowanie szablonu oraz import z Dokumentów lub pendrive'a
- ujednolicono numer wersji macOS, Windows i GNU/Linux oraz poprawiono wersję deklarowaną przez instalator Windows

## 0.4.0 — 2026-08-03

- dodano obsługę drukarek Prusa przez PrusaLink (macOS i Windows) — lokalnie po IP + klucz API, bez konta Prusy; odczyt stanu, postępu, czasu, temperatur i nazwy pliku
- dodano godziny ciszy — wyciszenie powiadomień w wybranym oknie dobowym (domyślnie 22:00–07:00), ustawiane w Ustawieniach i przełączane z menu PPM / zasobnika
- tryb kompaktowy z akordeonem: pełne kafle do 8 drukarek, powyżej zwarta lista (z przełącznikiem), klik w wiersz rozwija pełną kartę pod spodem; na Windows okno panelu powiększa się do rozwiniętej karty
- przenoszenie kolejności drukarek metodą przeciągnij-i-upuść na obu platformach
- dodano rozwijaną „Legendę kolorów" w PPM / zasobniku objaśniającą kolory statusu na kartach
- macOS wykrywa język systemu przy pierwszym uruchomieniu (parytet z Windows); ręczny wybór ma pierwszeństwo

### Poprawki

- okno dodawania drukarki nie nadpisuje już wpisanych danych, gdy w tle odświeża się inna drukarka podczas skanowania (macOS i Windows)
- Windows: menu „…" na karcie nie miga i nie zamyka się natychmiast (nakładka w oknie zamiast Popup)
- Windows: karty aktualizowane przyrostowo zamiast przebudowy całego panelu przy każdym odczycie (koniec zacięć)
- Windows: menu karty w bieżącym języku po przełączeniu PL/EN; log błędów do %AppData%\BambuBar\error.log
- macOS: stan rozwinięcia czyszczony po usunięciu drukarki

## 0.3.0 — 2026-08-02

- dodano obsługę systemu filamentów Creality CFS na drukarkach Klipper (macOS i Windows) — odczyt przez WebSocket drukarki (`ws://host:9999`), sloty CFS (materiał, kolor, % pozostałości, aktywna szpula) pokazywane jako AMS; drukarki Klipper bez CFS działają bez zmian
- opcje kamery i Bambu Studio pokazują się tylko dla drukarek Bambu; dla pozostałych dostępne jest podmenu „Otwórz slicer" z auto-wykrywaniem (Bambu Studio, OrcaSlicer, Creality Print, PrusaSlicer)
- w edycji drukarki można przypiąć jej postęp do paska menu (macOS) / zasobnika (Windows) jako osobny wskaźnik %
- dodano powiadomienie o dostępnej aktualizacji (macOS i Windows) — automatyczne sprawdzanie GitHub; kliknięcie instaluje (macOS) lub otwiera stronę wydania (Windows)

### Windows

- panel drukarek działa jak popover przy zasobniku (chowany po utracie fokusu), z zaokrąglonymi rogami, tłem acrylic i kafelkami w stylu macOS
- przebudowane, czytelne okno ustawień ze skonsolidowanymi opcjami: język, autostart, powiadomienia oraz „Sprawdź aktualizacje"
- karta drukarki ma menu „…" jak na macOS (Połącz ponownie, Kamera w Bambu Studio, Otwórz slicer, Kopiuj adres IP, Edytuj, Usuń)

## 0.2.0 — 2026-08-02

### Klipper (macOS i Windows)

- dodano obsługę drukarek Klipper (Moonraker) — dodawanie przez adres IP/host, opcjonalny port (domyślnie 7125) i klucz API, bez kodu dostępu i numeru seryjnego
- wieloszpulowe systemy MMU (Happy Hare) są pokazywane jako sloty AMS: materiał, kolor i aktywna szpula

### macOS

- przebudowane menu prawego przycisku na ikonie paska — większe, czytelniejsze wiersze z szybkimi akcjami: „Szukaj drukarek…", „Połącz ponownie (wszystkie)", „Sprawdź aktualizacje…" oraz przełącznik języka PL/EN, bez wchodzenia w Ustawienia

### Bezpieczeństwo (macOS)

- kody dostępu do drukarek są teraz szyfrowane w pęku kluczy (Keychain) zamiast zwykłego tekstu; przechowywane w jednej pozycji, więc macOS nie pyta o dostęp osobno dla każdej drukarki. Istniejące kody są przenoszone automatycznie przy pierwszym uruchomieniu
- auto-aktualizacja weryfikuje podpis pobranej wersji przed instalacją (musi być podpisana tą samą tożsamością co bieżąca aplikacja) — obcy lub zmodyfikowany pakiet jest odrzucany

## 0.1.19 — 2026-08-01

- powiadomienia macOS są teraz natywne: mają własną ikonę BambuBar, a kliknięcie otwiera pulpit aplikacji zamiast Edytora skryptów
- w ustawieniach macOS można wybrać, które powiadomienia mają się pojawiać (druk zakończony, błąd drukarki, druk wstrzymany, niski poziom filamentu, wysoka wilgotność AMS)
- okno pulpitu dopasowuje wysokość do liczby drukarek — przy 1–3 drukarkach nie ma już pustej przestrzeni, a przy dużej flocie pojawia się przewijanie
- dodano przycisk „Sprawdź aktualizacje" w ustawieniach macOS, który pobiera i instaluje nowszą wersję oraz uruchamia aplikację ponownie
- AMS i kolory pozostają widoczne przez cały czas druku (wcześniej znikały przy cząstkowych aktualizacjach statusu, m.in. na A1 mini z AMS lite)
- temperatura komory jest pokazywana wyłącznie dla drukarek z rzeczywistym czujnikiem (X1, X2, P2), a ukrywana tam, gdzie go nie ma (A1, A1 mini, P1) — wykrywane bezpośrednio z telemetrii drukarki

### Windows

- dodano okno ustawień z wyborem, które powiadomienia mają się pojawiać (druk zakończony, błąd, wstrzymany, niski poziom filamentu, wysoka wilgotność AMS) oraz przełącznikami języka i autostartu
- AMS pozostaje widoczny przez cały czas druku — ta sama poprawka cząstkowych aktualizacji statusu co w macOS
- temperatura komory jest odczytywana z tego samego pola telemetrii co w macOS, więc rozpoznanie obecności czujnika działa spójnie na obu platformach
- import z Bambu Studio obsługuje formaty JSON (z końcową sumą kontrolną) i starszy INI, także gdy Bambu Studio pozostaje otwarte, oraz wyszukuje konfigurację w kilku lokalizacjach

## 0.1.18 — 2026-07-30

- dodano pierwszą wersję beta BambuBar dla 64-bitowego Windows 10 i 11, działającą jako aplikacja w zasobniku systemowym
- wersja Windows jest publikowana jako samodzielny `BambuBar.exe` w archiwum ZIP i nie wymaga osobnej instalacji środowiska .NET
- dodano instalator `BambuBar-Setup-Windows-x64.exe`, który nie wymaga uprawnień administratora, uruchamia aplikację po instalacji, dodaje skrót w menu Start oraz automatyczny start przy logowaniu do Windows
- przeniesiono na Windows najważniejsze funkcje wersji macOS: wykrywanie drukarek, lokalne połączenie MQTT przez TLS, statusy druku, AMS/HMS, powiadomienia oraz import z Bambu Studio
- kody dostępu w wersji Windows są szyfrowane dla bieżącego użytkownika za pomocą Windows DPAPI
- poprawiono import konfiguracji Bambu Studio na Windows — obsługiwane są formaty JSON z końcową sumą kontrolną i starszy INI, również gdy Bambu Studio pozostaje otwarte
- wersja Windows pozostaje betą i nie jest jeszcze podpisana certyfikatem; wymaga dalszych testów interfejsu, zasobnika, zapory oraz wykrywania drukarek na fizycznych komputerach z Windows
- dodano usuwanie drukarki z menu „⋯" na karcie (z potwierdzeniem)
- skanowanie sieci kończy się w kilka sekund zamiast ~30 s (nie poddaje się już po 8 s)
- import z Bambu Studio działa na czystej instalacji — czyta adres IP z konfiguracji i tworzy drukarki bez potrzeby skanu, a przycisk importu nie czeka już na skanowanie
- wykrywanie SSDP działa również przy uruchomionym Bambu Studio (rezerwowy port, gdy 2021 jest zajęty)
- okno dodawania i edycji drukarki jest w pełni tłumaczone przy każdym otwarciu
- dodano testy jednostkowe (kodek MQTT, parser SSDP, parser statusu) oraz skrypt `scripts/run-tests.sh`
- ustabilizowano podpis aplikacji, dzięki czemu zgoda macOS na dostęp do sieci lokalnej przetrwa kolejne przebudowy
- README dostępne w wersji polskiej i angielskiej

## 0.1.14 — 2026-07-30

- opublikowano kompletny kod źródłowy projektu na licencji MIT
- import z Bambu Studio odbywa się wyłącznie po świadomym kliknięciu przycisku przez użytkownika
- zaimportowane kody dostępu są zapisywane w pęku kluczy macOS i nie wymagają ponownego odczytu konfiguracji Bambu Studio przy starcie
- dodano dokumentację bezpieczeństwa, zasady współtworzenia i automatyczny build dla macOS 26
- dodano informacje o autorze oraz odnośniki do profili GitHub, X i strony wsparcia
- wyeliminowano wielokrotne pytania pęku kluczy podczas automatycznego ponownego łączenia
- ujednolicono lokalną tożsamość podpisu dla aplikacji i uruchamiania przez plik `.command`

## 0.1.13 — 2026-07-29

- wydano pierwszą kompletną wersję natywnego monitora drukarek Bambu Lab dla paska menu macOS
- dodano wykrywanie drukarek w sieci lokalnej, ręczne dodawanie urządzeń oraz automatyczne ponowne łączenie
- dodano status wydruku, procent postępu, pozostały czas, warstwy oraz temperatury dyszy, stołu i komory
- dodano szczegółowe etapy pracy, m.in. bazowanie, nagrzewanie, poziomowanie, ładowanie i zmianę filamentu
- dodano komunikaty HMS, powiadomienia o błędach i zakończeniu druku oraz subtelne wyróżnienie kafelków błędu i zakończonego zadania
- dodano obsługę AMS na cztery szpule i pojedynczego AMS wraz z kolorami, aktywnym slotem, wilgotnością, temperaturą i ostrzeżeniami o niskim poziomie filamentu
- dodano obsługę polskich znaków w nazwach plików oraz czytelne skrócone informacje AMS
- dodano przeciąganie kafelków, zapisywanie kolejności drukarek i znacznik miejsca upuszczenia
- widok rozwinięty korzysta z dwóch kolumn, a od dziewięciu drukarek automatycznie przechodzi na trzy kolumny
- od czterech drukarek dostępny jest tryb zwarty, mieszczący do piętnastu statusów w wąskim panelu
- wybrany układ, język polski lub angielski oraz jasny lub ciemny wygląd są zapamiętywane
- ustawienia otwierają się w osobnym oknie z menu kontekstowego ikony `BL` i zawierają opcję uruchamiania przy logowaniu oraz odnośnik do wsparcia
- ograniczono odświeżanie ETA do pięciu minut, ukryto licznik świeżych danych i dodano ostrzeżenie o nieaktualnej telemetrii
- kody dostępu są bezpiecznie przechowywane w pęku kluczy macOS, a komunikacja z drukarkami odbywa się lokalnie bez konta Bambu Cloud
