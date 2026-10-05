# Gantry 0.10.0 — wspólny interfejs macOS, Windows i Linux oraz Elegoo Centauri

Gantry 0.10.0 porządkuje trzy wydania aplikacji wokół dopracowanej wersji macOS. Windows i GNU/Linux otrzymują ten sam układ pulpitu, te same najważniejsze opcje oraz spójny przebieg dodawania, edycji i obsługi drukarek.

## Najważniejsze zmiany

- **Spójny pulpit na trzech systemach** — proporcje kart i sekcji, segmentowy postęp, temperatury, AMS / AMS HT / EXT, ostatnia nieparzysta karta na pełną szerokość oraz krótkie pastylki kolorów filamentu odpowiadają wersji macOS.
- **Spójne okna i flow pracy** — ujednolicone zostały Szczegóły, Dodaj drukarkę, Edytuj drukarkę, Ustawienia, opcje zaawansowane, Spoolbase oraz przypisywanie fizycznej rolki do slotu.
- **Natychmiastowe odświeżanie wyglądu** — zmiana motywu i przezroczystości jest stosowana bez restartu aplikacji. Na Windows nie trzeba już wchodzić w Szczegóły i wracać, aby zobaczyć nowy efekt tła.
- **Spoolbase** — poprawiony natywny wygląd list, pól i dialogów, czytelniejsze nazewnictwo oraz spójne akcje dodawania, edycji, usuwania i przypisywania filamentu.
- **Pasek główny** — przyciski układu, listy, zamknięcia, odświeżania i dodawania drukarki mają zgodne znaczenie i zachowanie na macOS, Windows i Linux.

## Elegoo Centauri Carbon 1 i 2

Przy dodawaniu drukarki wybierasz teraz markę **Elegoo**, a następnie model:

- **Centauri Carbon (CC1)** — lokalny SDCP/WebSocket na porcie 3030, kamera MJPEG na 3031, bez kodu dostępu;
- **Centauri Carbon 2 (CC2)** — lokalny MQTT na porcie 1883, kamera MJPEG na 8080, Canvas A1–A4; wymagany tryb LAN-only i kod dostępu drukarki.

Obsługa obejmuje wykrywanie w sieci lokalnej, stan zadania, postęp, warstwy, temperatury i kamerę. Szczegóły konfiguracji znajdują się w [`docs/elegoo-centauri.md`](https://github.com/parametryczny/gantrybar/blob/main/docs/elegoo-centauri.md).

## GNU/Linux — pakiety w przygotowaniu

Wydanie dla GNU/Linux jest nadal przygotowywane i przechodzi testy integracyjne na rzeczywistych środowiskach GTK. Docelowo na stronie wydania pojawią się trzy formaty:

1. **`.deb` / `.rpm`** — klasyczna instalacja systemowa z integracją z menu aplikacji i pulpitem;
2. **`.AppImage`** — pojedynczy przenośny plik zawierający aplikację i większość potrzebnych bibliotek.

Pakiety są budowane przez osobne zadania CI, instalowane testowo i sprawdzane przed dodaniem do GitHub Releases. Do czasu opublikowania artefaktów Linux należy traktować jako wersję beta.

## Zgodność i aktualizacja

- **macOS:** macOS 13 lub nowszy;
- **Windows:** 64-bitowy Windows 10 lub 11;
- **GNU/Linux:** GTK 3; paczki dystrybucyjne są w przygotowaniu.

Aktualizacja zachowuje zapisane drukarki, ustawienia, Spoolbase i bezpiecznie przechowywane kody dostępu. Gantry działa lokalnie — nie wymaga konta w chmurze producenta drukarki.

## Kontrola jakości

- automatyczna kontrola zgodności kontraktu UI macOS / Windows / Linux;
- 51 testów rdzenia i integracji wersji Linux;
- osobne workflow budujące macOS, Windows oraz pakiety `.deb`, `.rpm` i `.AppImage`.

