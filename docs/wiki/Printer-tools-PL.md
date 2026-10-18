# Ustawienia i narzędzia drukarki

[English](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Printer-tools-EN.md) · [Spis treści](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

W pełnej wersji Gantry wybierz **boczne menu → Ustawienia drukarek** (ikona nad Ustawieniami), a następnie drukarkę na górze. W trybie samego paska/zasobnika wybierz **Ustawienia drukarek** bezpośrednio z menu aplikacji. Zmiany zatwierdza **Zapisz ustawienia drukarki**. Przełączanie między drukarkami zachowuje osobne szkice formularza.

## Kamera zewnętrzna

Pole **Zewnętrzna kamera JPEG / MJPEG** przyjmuje pełny adres HTTP lub HTTPS, np. `http://kamera.local/snapshot.jpg` albo `http://kamera.local/?action=stream`. Jest dostępne dla każdej marki, również Prusa i Snapmaker. Nie jest to adres RTSP ani strona HTML z osadzonym odtwarzaczem. Puste pole przywraca dotychczasową kamerę i jej ustawienia orientacji. Osobne, starsze pole adresu kamery nadal służy do zmiany hosta standardowej kamery drukarki.

Podgląd korzysta ze wspólnego źródła dla szczegółów, monitoringu i paska krawędziowego. Zdjęcia działają także przez istniejący panel WWW i most na hosting, zgodnie z włączonym dostępem. Zewnętrzny adres nie otrzymuje kodu ani klucza API drukarki. Ten wariant obsługuje kamerę bez osobnego logowania; nie wpisuj danych logowania w URL. Ustawienie **Zdjęcia w powiadomieniach** można wyłączyć osobno dla drukarki.

Zdjęcie w powiadomieniu jest pobierane z kamery lub ostatniej dostępnej klatki podglądu. Brak obrazu nie blokuje powiadomienia tekstowego. Alert Vision używa dokładnie klatki, która spowodowała alarm. Wygląd zdjęcia zależy od ustawień powiadomień środowiska. LITE nie otwiera kamer dla powiadomień.

## Panel WWW i własny przycisk

**Adres panelu WWW** jest opcjonalnym skrótem do przeglądarki. Dla PrusaLink i OctoPrint Gantry proponuje adres drukarki; dla Klippera port WWW 80, zamiast portu API 7125. Wpisz własny URL, jeśli panel działa gdzie indziej. Bambu i inne marki bez standardowego panelu wymagają własnego adresu.

**Własny przycisk HTTP**: podaj nazwę, URL i metodę GET albo POST. POST może mieć treść JSON. Opcjonalny token Bearer trafia do istniejącego magazynu kluczy dostępu. Pozostałe pola, w tym treść JSON, są zwykłą konfiguracją — token podawaj w polu tokenu. Puste pole tokenu usuwa zapisany token. Usuń nazwę i URL, aby usunąć przycisk.

Przycisk uruchomisz w szczegółach drukarki. Kliknięcie wysyła jedno żądanie, blokując przycisk do zakończenia. Zapis formularza niczego nie wysyła. Obsługiwane są HTTP/HTTPS, poprawny JSON do 64 KiB i limit 10 sekund. Przekierowania oraz automatyczne ponawianie polecenia przez Gantry są wyłączone. Sukces: kod HTTP w podpowiedzi przycisku; błąd: komunikat. To ręczna akcja, bez automatycznego uruchamiania po zakończeniu druku.

## Zapasowy adres i odświeżanie API

PrusaLink, Klipper/Moonraker i OctoPrint mają **Zapasowy adres API** oraz dwa interwały odświeżania: podczas druku/pauzy i w spoczynku. Podaj adres tej samej drukarki, np. przez VPN: `https://drukarka.vpn:8443`, bez ścieżki i parametrów. Ten sam klucz API zostanie użyty pod skonfigurowanym drugim adresem.

Po błędzie połączenia sieciowego kolejne połączenie użyje drugiego adresu. Wybrany adres zostaje wspólny dla odczytu API, sterowania i transferu plików; polecenie ani upload nie są automatycznie powtarzane pod drugim adresem. Błędy logowania i weryfikacji certyfikatu nie przełączają adresu. Kamera i dodatkowe połączenie Creality CFS na osobnym porcie zachowują osobną konfigurację. Interwały: 1–300 sekund; puste = dotychczasowe 2 sekundy. Ponowne próby po rozłączeniu nadal korzystają z dotychczasowego mechanizmu ponawiania.

## Widoczność, energia i filamenty

Dla wybranej drukarki ustawisz także widoczność zewnętrznych szpul EXT, postęp w pasku lub zasobniku, obecność w pasku krawędziowym, kamerę pod paskiem, średnią moc i amortyzację. Z tego widoku otworzysz edycję połączenia i konfigurację gniazdka. Klipper ma dodatkowo własne nazwy obiektów Moonrakera, a obsługiwane drukarki — własne komendy światła.

Puste pole średniej mocy korzysta z ustawienia floty. Gniazdko z pomiarem dostarcza rzeczywiste odczyty energii; [Energia i raporty](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Energy-and-reports-PL.md) wyjaśnia pomiar, braki i eksport.
