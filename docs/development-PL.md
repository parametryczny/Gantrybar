# Budowanie i współtworzenie

[English](development-EN.md) · [Gantry](../README.pl.md)

Instrukcje dotyczą pobranych źródeł, które mogą różnić się od publicznego wydania. Używaj fikcyjnych danych drukarek i nie zapisuj danych dostępu w przykładach, zrzutach ani commitach.

## Kopia rozwojowa

Publiczna gałąź `main` zawiera obecnie informacje o wydaniach i dokumentację, a nie komplet źródeł aplikacji. Poniższe polecenia dotyczą kopii rozwojowej z katalogami `Sources/`, `windows/Gantry.Windows/` i `linux/gantry/`. Samo sklonowanie publicznej gałęzi dokumentacji nie wystarcza do zbudowania aplikacji.

## macOS

Użyj Swift 6 i Xcode Command Line Tools na zgodnym komputerze z macOS. Minimalny system docelowy określają `Package.swift` i `Resources/Info.plist`; poprawna kompilacja nie zastępuje testu na minimalnej wersji systemu.

```sh
swift build --disable-sandbox
.build/debug/Gantry --self-test
./scripts/run-tests.sh
./scripts/build-app.sh local
```

Pakiet aplikacji trafia do `dist/Gantry.app`. Pakowanie może wymagać wskazanego w skrypcie dekodera kamery i zasobów modelu. Testy pęku kluczy wymagają odblokowanej sesji użytkownika. Pakowanie opisują `scripts/build-app.sh` i `scripts/build-dmg.sh`.

## Windows

Do pracy nad WPF użyj .NET 8 SDK w Windows.

```powershell
dotnet restore windows/Gantry.Windows/Gantry.Windows.csproj
dotnet build windows/Gantry.Windows/Gantry.Windows.csproj -c Release
dotnet run --project windows/Gantry.Windows/Gantry.Windows.csproj
```

Workflow Windows publikuje samodzielny pakiet i buduje instalator. Kompilacja na innym komputerze nie potwierdza działania zasobnika, kamer ani powiadomień w Windows.

## Linux

Użyj Python 3.10 lub nowszego, GTK 3 / PyGObject, obsługi zasobnika i Secret Service. Pełne zależności pakietów określają `linux/packaging/` oraz `.github/workflows/linux.yml`.

```sh
PYTHONPATH=linux python3 -m unittest discover -s linux/tests -v
PYTHONPATH=linux python3 -m gantry
```

Testy graficzne uruchamiaj w sesji pulpitu lub przez Xvfb. Pakiety budują `linux/scripts/build-deb.sh`, `build-rpm.sh` i `build-appimage.sh`; RPM/AppImage wymagają odpowiednich narzędzi budowania w Linux.

## Sprawdź zmianę

Uruchom kontrole właściwe dla zmienianego obszaru. Sprawdź działanie na systemach docelowych; test parsera nie potwierdza poprawności okna aplikacji. Do zmian interfejsu dołącz zrzuty PL/EN z danymi demonstracyjnymi i sprawdź wąski oraz szeroki układ.

[Zasady współtworzenia](../CONTRIBUTING.md)
