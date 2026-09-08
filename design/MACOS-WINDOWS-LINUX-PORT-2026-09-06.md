# Port aktualnego Gantry z macOS — 2026-09-06

macOS pozostaje referencją wyglądu i zachowania. Port zachowuje natywne transporty, magazyny danych i integracje systemowe WPF/GTK; nie przenosi kodu AppKit dosłownie.

## Zakres

| Obszar | Windows / WPF | Linux / GTK |
|---|---|---|
| Tryb okna z ustawień | Trwały wybór, natywne zamknij/minimalizuj/maksymalizuj, obecność na pasku zadań | Trwały wybór, dekoracje i lista okien menedżera pulpitu; brak AppIndicator nadal daje zwykłe okno |
| Zamknięcie okna | Minimalizuje, nie zmienia ustawienia na dymek; ikona przywraca okno | Minimalizuje, nie wyłącza trybu okna; ikona przywraca okno |
| Rozmiar i przypięcie | Zapamiętany rozmiar, automatyczne kolumny, przełącznik zawsze na wierzchu | Zapamiętany rozmiar, automatyczne kolumny, przełącznik zawsze na wierzchu |
| Nagłówek | Ustawienia, pomoc, przypięcie, większe odstępy; drugi wiersz przy małej szerokości | Ustawienia, pomoc, przypięcie i odstępy między kontrolkami |
| Start aplikacji | Brak kart bez pierwszej telemetrii, ekran łączenia do 60% początkowej floty / 15 s / ręcznego pominięcia | Ta sama reguła |
| Przewodnik | Automatyczny raz, zapamiętany między startami; można otworzyć ręcznie; produkcyjna karta z rzeczywistą telemetrią, bez sterowania | Ta sama reguła; produkcyjny `PrinterCard`, również w dymku |
| Panele wewnątrz okna | Szczegóły, konserwacja, przypisanie rolki, diagnostyka, statystyki i główny Spoolbase; ograniczona szerokość i wysokość, przewijanie | Te same główne panele; ograniczenie ramy do viewportu, również przy zmniejszaniu okna |
| Karty / AMS / postęp | Zachowane wcześniej przeniesione segmenty, metryki temperatur, moduły i sloty AMS/EXT, ustawienia widoczności | Zachowany ten sam kontrakt widżetów |
| Spoolbase | Zachowane przypisania i zużycie; wyłączenie funkcji blokuje mutacje, NFC usuwa zastąpione przypisanie | Zachowane odpowiedniki i testy zużycia / przypisań / wyłączenia |
| Pasek boczny | Istniejący EdgeDock i jego ustawienia | Istniejący EdgeDock; naprawione błędne wywołania tłumaczeń statusów |
| Web | Wspólny `Resources/web-dashboard.html`, kopiowany do paczki | Ten sam plik kopiowany do DEB/RPM/AppImage |

## Różnice i granice

- Windows nie dostaje kontrolek AppKit ani menu przy logo Apple; używa natywnej ramy, paska zadań oraz menu aplikacji w trayu. Linux używa dekoracji i zachowania swojego menedżera okien.
- WPF rozmywa i przyciemnia pulpit pod panelem. GTK używa przyciemnienia; dostępność rozmycia pulpitu, pozycji okna i wymuszania zawsze-na-wierzchu zależy od kompozytora, zwłaszcza na Waylandzie.
- Ustawienia, konfiguracja drukarki, zaawansowane edytory, wybór plików i potwierdzenia mogą nadal korzystać z natywnych okien dialogowych. Przeniesione zostały główne dodatkowe panele pulpitu, nie wszystkie podrzędne formularze aplikacji.
- Zwykłe zmiany rozmiaru nie przebudowują kart w każdym pikselu; przebudowa następuje na progach układu. Nie jest to jeszcze pomiar wydajności na docelowych maszynach.
- Nie zmieniano danych drukarek, nie łączono się z nimi w testach i nie publikowano wydania. Lokalne pliki-kopie `HmsResolver 2.cs` i `MaintenanceWindow 2.cs` zachowano na dysku, wyłączając je z kompilacji.

## Weryfikacja

- Kompilacja całej aplikacji WPF: Debug i Release, .NET SDK 8.0.424, cross-target Windows na macOS. Dwa istniejące ostrzeżenia nullable w `Translations.cs`; brak błędów kompilacji.
- 65 testów jednostkowych Linuxa: transportowe parsery, layout, magazyny, zużycie, automatyzacje i nowy cykl startu.
- Osobny wykonywalny test polityki startu C# (`windows/Tests/PresentationTests.csproj`).
- Test rzeczywistego GTK (`scripts/check_linux_presentation.py`) z danymi wyłącznie w pamięci: automatyczny przewodnik, prawdziwy widżet AMS, brak pustych kart, rozmiary 1200×750 / 560×400 / 380×300 / 750×650, panele konserwacji/statystyk/diagnostyki, ponowne otwarcie i przełączenie na dymek.
- Kontrola kontraktu UI, tłumaczeń, składni Pythona i whitespace. Testy startu i GTK dodane do istniejących workflowów; workflowów zdalnych nie uruchamiano.
- GUI WPF nie było uruchomione w Windows. GTK sprawdzono na dostępnym runtime na Macu, nie na docelowym GNOME/KDE. Pakiety i zachowanie na Windows 10/11 oraz X11/Wayland wymagają jeszcze testu na tych systemach.
