# Łączenie drukarek

[English](connections-EN.md) · [Gantry](../README.pl.md)

Strona opisuje obecną gałąź rozwojową 0.14. Dla publicznego pakietu sprawdź również opis jego wydania. Obsługa protokołu nie oznacza dostępności każdej funkcji w każdej wersji firmware.

| Drukarka / usługa | Połączenie | Wymagane dane |
| --- | --- | --- |
| Bambu Lab | MQTT przez TLS, zwykle port 8883 | IP, numer seryjny i kod dostępu LAN. Użyj wykrywania lub świadomie zaimportuj konfigurację Bambu Studio. |
| Anycubic Kobra S1 | LAN MQTT/TLS; kamera FLV | IP i włączony tryb LAN; kamera zwykle na porcie 18088. |
| Elegoo Centauri Carbon | SDCP / WebSocket 3030; MJPEG 3031 | IP i wykryty identyfikator urządzenia; bez kodu dostępu. |
| Elegoo Centauri Carbon 2 | MQTT 1883; MJPEG 8080 | IP, numer seryjny, kod dostępu i tryb LAN-only. |
| Klipper / Moonraker | API HTTP, zwykle 7125 | Host, port i klucz API, jeżeli wymaga go uwierzytelnianie. Obejmuje zgodne konfiguracje Creality, Qidi i Snapmaker U1. |
| PrusaLink | API HTTP, zwykle 80 | IP, port i klucz API PrusaLink. |
| Snapmaker 2.0 / Artisan | Lokalne API HTTP, zwykle 8080 | IP i zgoda na ekranie drukarki. Po ponownym włączeniu może być wymagana ponowna autoryzacja. |
| OctoPrint — podgląd 0.14 | API HTTP pod skonfigurowanym adresem serwera | Adres serwera i klucz API. |

## Sieć i dane dostępu

Komputer i drukarki muszą mieć łączność przez LAN lub VPN. Wykrywanie rozgłoszeniowe może nie przechodzić między VLAN-ami ani przez VPN; w razie potrzeby wpisz adres ręcznie. Wykrywanie Bambu może skanować dodatkowe adresy, zakresy lub podsieci CIDR skonfigurowane w aplikacji.

Powyższe porty są wartościami domyślnymi, a nie instrukcją wystawienia ich do internetu. Dostęp spoza sieci zapewnij przez VPN albo [most na własny hosting](wiki/Web-dashboard-PL.md).

Puste pole kodu dostępu podczas edycji zachowuje zapisany kod. Import danych ze slicera wymaga świadomego działania. Nie zamieszczaj kodów dostępu, kluczy API ani rzeczywistych identyfikatorów drukarek w zgłoszeniach i zrzutach.

## Kamery i materiały

Format standardowej kamery zależy od drukarki: Bambu RTSP/RTSPS, Kobra S1 FLV oraz obsługiwane kamery HTTP JPEG/MJPEG. Osobne źródło JPEG/MJPEG ustawisz w [Narzędziach drukarki](wiki/Printer-tools-PL.md). Strona z osadzonym odtwarzaczem nie jest adresem strumienia kamery.

Gantry uwzględnia obrót i odbicia skonfigurowane w Moonrakerze. Odczyty AMS, AMS HT, ACE Pro, Canvas, Happy Hare MMU i Creality CFS zależą od dostępnej telemetrii. Kolor slotu nie potwierdza tożsamości fizycznej rolki; skorzystaj z [procedury Spoolbase](wiki/Spoolbase-PL.md).

Komendy sterujące i wysyłanie plików z Farmy wymagają obsługi w API i firmware drukarki. Działająca karta stanu nie potwierdza jeszcze obsługi poleceń.
