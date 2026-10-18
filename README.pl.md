<div align="center">

<img src="docs/branding/gantry-appicon.png" width="72" alt="Ikona aplikacji Gantry">

# Gantry

### Twoja flota drukarek 3D w jednym miejscu.

Monitoruj wydruki, zarządzaj filamentem, planuj produkcję i sprawdzaj koszty. Lokalnie, z opcjonalnym dostępem przez własny hosting.

**[English](README.md)** · **Polski**

**[Pobierz](https://github.com/parametryczny/Gantrybar/releases/latest)** · **[Pierwsze kroki](docs/wiki/Getting-started-PL.md)** · **[Poradniki](docs/wiki/Home.md)** · **[Co nowego](docs/release-0.14.0.md)**

[![Wydanie](https://img.shields.io/github/v/release/parametryczny/Gantrybar?label=stabilne)](https://github.com/parametryczny/Gantrybar/releases/latest) [![Licencja](https://img.shields.io/github/license/parametryczny/Gantrybar)](LICENSE) [![Pobrania](https://img.shields.io/github/downloads/parametryczny/Gantrybar/total)](https://github.com/parametryczny/Gantrybar/releases)

**macOS · Windows · Linux**

</div>

> **Status wydania:** aktualna publiczna wersja to **0.12.0**. Poniższe zrzuty i poradniki przedstawiają **0.14.0**, nad którą nadal pracujemy. Jej wydanie pozostaje szkicem; tych nowości nie ma jeszcze w aktualnym stabilnym pakiecie.

![Okno floty Gantry 0.14 Modern z sześcioma przykładowymi drukarkami](docs/renders/readme-modern-pl.png)

*Rzeczywisty interfejs Gantry z fikcyjnymi danymi drukarek. Motyw Modern, podgląd 0.14.*

Gantry daje podgląd floty w pasku menu lub zasobniku, pełnym oknie albo wąskim panelu przy krawędzi ekranu. Sprawdzisz postęp, pozostały czas, temperatury, załadowany filament i kamery bez otwierania osobnego slicera dla każdej drukarki.

## Poznaj Gantry 0.14

| Obszar | W czym pomaga |
| --- | --- |
| **Flota** | Śledź stan i kamery, odbieraj powiadomienia i ustawiaj narzędzia poszczególnych drukarek. Wybierz Basic, Modern albo ograniczony tryb LITE. [Widoki](docs/wiki/Appearance-and-LITE-PL.md) · [Narzędzia drukarki](docs/wiki/Printer-tools-PL.md) |
| **Farma** | Wyszukuj pocięte pliki, dobieraj zgodne drukarki, mapuj materiały i planuj partie. Kontroluj odbiór, jakość i ręczne zamówienia. [Poradnik Farmy](docs/wiki/Farm-PL.md) |
| **Filamenty** | Podglądaj AMS, HT, MMU i szpule zewnętrzne. Zarządzaj fizycznymi rolkami w Spoolbase i przypisuj je do załadowanych slotów. [Spoolbase](docs/wiki/Spoolbase-PL.md) |
| **Energia i koszty** | Zapisuj pomiary gniazdka przez cały wydruk, przeglądaj historię i eksportuj raporty. Odróżniaj dane zmierzone, częściowe i szacowane. [Energia i raporty](docs/wiki/Energy-and-reports-PL.md) |
| **Vision i serwis** | Sprawdzaj podejrzenia defektów, oznaczaj klatki i prowadź zadania serwisowe, harmonogramy, problemy oraz części. [Vision](docs/wiki/Gantry-Vision-PL.md) · [Konserwacja](docs/wiki/Maintenance-PL.md) |
| **Dostęp zdalny** | Podglądaj flotę w LAN lub wygeneruj skonfigurowaną paczkę strony na własny hosting. Opcjonalnie dodaj powiadomienia Telegram. [Panel WWW](docs/wiki/Web-dashboard-PL.md) |

### Od pliku do gotowej partii

![Farma Gantry 0.14: wyszukiwarka plików, sześć drukarek i mapowanie materiałów](docs/renders/readme-farm-pl.png)

*Podgląd natywnej Farmy z przykładowymi plikami, stanami drukarek i zamówieniem.*

W jednym widoku wybierzesz plik, drukarki i źródła materiałów. Zaplanujesz partie, potwierdzisz odbiór i zaakceptujesz lub odrzucisz gotowe kopie. Ręczne zamówienia łączą numer, SKU, ilość i termin z pociętą płytą. **Integracje z WooCommerce i Etsy są planowane.**

Samo wysłanie pliku nie uruchamia druku. Start z kolejki wymaga wyraźnego zatwierdzenia pustego, przygotowanego stołu; Gantry nie przelicza pliku na profil innej drukarki.

## Pobierz i zacznij

Pobierz instalator z **[najnowszego publicznego wydania](https://github.com/parametryczny/Gantrybar/releases/latest)**. Wybierz pakiet dla swojego systemu:

| System | Pakiet |
| --- | --- |
| macOS | `Gantry-*-macOS.dmg`; alternatywne warianty przechowywania danych są w archiwach ZIP |
| Windows x64 | `Gantry-Setup-Windows-x64.exe` lub przenośny `Gantry-Windows-x64.zip` |
| Linux | `.deb`, `.rpm` lub przenośny `.AppImage` |

Pakiety wydania Windows zawierają wymagane środowisko uruchomieniowe. Wymagania pakietów i uwagi instalacyjne znajdziesz w wybranym wydaniu.

1. Zainstaluj Gantry i zezwól na dostęp do sieci lokalnej, jeśli system o to poprosi.
2. Wybierz **Dodaj drukarkę…**, wskaż typ i podaj adres oraz wymagane dane dostępu.
3. Sprawdź kartę stanu, a potem Szczegóły — dostępne odczyty i kamerę.
4. Włącz potrzebne moduły opcjonalne. [Przejdź do pierwszych kroków](docs/wiki/Getting-started-PL.md).

### Drukarki

Bambu Lab · Anycubic Kobra S1 · Elegoo Centauri Carbon / CC2 · Klipper / Moonraker · PrusaLink · Snapmaker. Podgląd 0.14 obejmuje również OctoPrint.

Dostępne odczyty, systemy filamentów, kamery i komendy zależą od drukarki i jej firmware. [Dane połączenia i protokoły](docs/connections-PL.md).

## Twoje dane i konfiguracja

Podgląd lokalny nie wymaga konta Gantry ani serwera prowadzonego przez Gantry. Opcjonalny hosting i Telegram przesyłają dane potrzebne do włączonych integracji; dostęp zdalny wymaga działającego komputera z Gantry i połączenia z siecią.

Vision może przeoczyć defekt lub zgłosić fałszywy alarm. Porównuj wynik z obrazem kamery. Oznaczenie klatki **nie** powoduje automatycznego trenowania wag modelu. [Jak działa Vision](docs/wiki/Gantry-Vision-PL.md).

## Inne widoki

<details>
<summary><strong>Panel przy krawędzi</strong> — podgląd obok Twojej pracy</summary>

![Dotychczasowy render promocyjny panelu bocznego Gantry](docs/renders/readme-edge-panel.png)

Dotychczasowa ilustracja promocyjna. W aktualnej aplikacji wybierzesz rozwijanie po najechaniu lub kliknięciu, drukarki i podglądy kamer. [Ustawienia widoku](docs/wiki/Appearance-and-LITE-PL.md).

</details>

<details>
<summary><strong>Telegram</strong> — powiadomienia i flota na telefonie</summary>

Skonfiguruj własnego bota i czat; połączenie zapewnia komputer z Gantry. [Konfiguracja, polecenia i sterowanie w Telegramie](docs/wiki/Telegram-PL.md).

</details>

## Poradniki i społeczność

[Wszystkie poradniki PL/EN](docs/wiki/Home.md) · [Rozwiązywanie problemów](docs/wiki/Troubleshooting-PL.md) · [Opis wydania](docs/release-0.14.0.md)

Coś nie działa? [Zgłoś problem](https://github.com/parametryczny/Gantrybar/issues), podając wersję Gantry, model drukarki, system i kroki odtworzenia. Usuń kody dostępu i inne prywatne dane z logów oraz zrzutów.

Autor: **[Kamil Grzegorczyk / parametryczny](https://github.com/parametryczny)**. [Wesprzyj rozwój](https://buycoffee.to/parametryczny) · [Współtwórz](CONTRIBUTING.md) · [Licencja MIT](LICENSE).
