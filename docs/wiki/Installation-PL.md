# Instalacja i aktualizacja

[English](https://github.com/parametryczny/Gantrybar/wiki/Installation-EN) · [Spis treści](https://github.com/parametryczny/Gantrybar/wiki/Home)

Dokument dotyczy Gantry 0.14.0. Dopóki wydanie jest szkicem, publiczny przycisk **Latest** prowadzi do poprzedniej stabilnej wersji. Pliki 0.14.0 będą publicznie dostępne po opublikowaniu wydania przez autora.

## Wybierz plik

| System | Paczka | Zastosowanie |
| --- | --- | --- |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS.dmg` | przeciągnięcie Gantry do Aplikacji |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS-Local.zip` | pełna aplikacja w ZIP; hasła w systemowym magazynie kluczy |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS-Keychain.zip` | alternatywny identyfikator aplikacji; zachowaj ten wariant, jeśli już go używasz |
| Windows 10/11 x64 | `Gantry-Setup-Windows-x64.exe` | instalator PL/EN; środowisko .NET dołączone |
| Windows 10/11 x64 | `Gantry-Windows-x64.zip` | wersja przenośna; wypakuj całość |
| Linux x86_64 | plik `.deb` | Debian / Ubuntu i pochodne |
| Linux x86_64 | plik `.rpm` | Fedora i zgodne dystrybucje |
| Linux x86_64 | plik `.AppImage` | przenośne uruchomienie bez instalowania pakietu |

Linux: paczki z własnym środowiskiem aplikacji, zbudowane na Ubuntu 24.04; wymagają glibc 2.39 lub nowszej i działającej sesji graficznej. Nie są paczkami ARM/Raspberry Pi. Sprawdź architekturę przez `uname -m`. Nazwa pliku i metadane pakietu rozstrzygają jego architekturę.

## macOS

1. Otwórz DMG i przeciągnij **Gantry.app** do **Aplikacji**. ZIP należy najpierw rozpakować.
2. Zamknij dotychczasowe Gantry przed zastąpieniem aplikacji. Zachowaj używany wariant Local/Keychain, aby nie zmieniać identyfikatora i miejsca jego danych.
3. Przy pierwszym uruchomieniu zezwól na sieć lokalną i — jeśli chcesz — powiadomienia.
4. Jeśli macOS blokuje uruchomienie, użyj standardowej opcji **Ustawienia systemowe → Prywatność i ochrona → Otwórz mimo to** dla pobranego Gantry. Nie wyłączaj ochrony systemu globalnie.

Wariant Local również przechowuje nowe kody dostępu w pęku kluczy. Nazwa pliku nie oznacza zapisu haseł jawnym tekstem. Paczka nie jest poświadczona notaryzacją Apple.

## Windows

W instalatorze wybierz **Polski** lub **English**. Instalacja odbywa się dla bieżącego użytkownika; nie potrzeba osobnego .NET. Skrót jest w menu Start, a autostart można zmienić w ustawieniach Gantry. Odinstalowanie zachowuje dane użytkownika.

W ZIP uruchamiaj `Gantry.exe` z wypakowanego katalogu; nie przenoś samego EXE. Zaktualizuj cały folder po zamknięciu programu. Paczki testowe nie mają komercyjnego podpisu wydawcy.

## Linux

Dla `.deb` użyj menedżera pakietów lub `sudo apt install ./NAZWA.deb`. Dla `.rpm`: `sudo dnf install ./NAZWA.rpm`. Sprawdź nazwę i architekturę pobranego pliku.

Dla AppImage: `chmod +x NAZWA.AppImage`, następnie `./NAZWA.AppImage`. Jeśli system nie obsługuje montowania FUSE, można użyć `./NAZWA.AppImage --appimage-extract-and-run`. Ikona zasobnika może wymagać obsługi AppIndicator w danym pulpicie.

## Aktualizacja bez utraty danych

Zamknij Gantry, zainstaluj nową paczkę tego samego wariantu i uruchom aplikację. Drukarek, magazynu ani historii nie usuwa się w celu aktualizacji wyglądu. Przed większą zmianą zrób własną kopię danych. Konfiguracja hostingu jest osobną instalacją — aktualizacja aplikacji nie podmienia strony na serwerze.

Farma jest domyślnie wyłączona: **Ustawienia → Ogólne**. LITE ukrywa większość narzędzi: **Ustawienia → Zaawansowane**. Jeżeli nie widzisz Spoolbase, sprawdź również jego przełącznik w Ogólnych.

## Suma kontrolna

`SHA256SUMS.txt` w wydaniu zawiera sumy dokładnie dołączonych paczek. macOS: `shasum -a 256 NAZWA`; Linux: `sha256sum NAZWA`; Windows PowerShell: `Get-FileHash .\NAZWA -Algorithm SHA256`. Porównaj pełny wynik z plikiem wydania. Suma identyfikuje plik, ale nie zastępuje podpisu wydawcy.

[Dodaj pierwszą drukarkę](https://github.com/parametryczny/Gantrybar/wiki/Getting-started-PL) · [Pomoc](https://github.com/parametryczny/Gantrybar/wiki/Troubleshooting-PL)
