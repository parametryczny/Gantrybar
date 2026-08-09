# Gantry

**[English](#english)** · **[Polski](#polski)**

[![Latest release](https://img.shields.io/github/v/release/parametryczny/gantrybar)](https://github.com/parametryczny/gantrybar/releases/latest)
[![Total downloads](https://img.shields.io/github/downloads/parametryczny/gantrybar/total)](https://github.com/parametryczny/gantrybar/releases)
[![License: MIT](https://img.shields.io/github/license/parametryczny/gantrybar)](LICENSE)

![Gantry fleet dashboard](docs/renders/bambubar-fleet-dark-centered.png)

<p align="center">
  <img src="docs/renders/bambubar-fleet-light-right.png" width="49%" alt="Gantry on a light macOS desktop">
  <img src="docs/renders/bambubar-fleet-dark-left.png" width="49%" alt="Gantry on a dark macOS desktop">
</p>

---

## Downloads / Pobieranie

Grab the latest build from the **[Releases page](https://github.com/parametryczny/gantrybar/releases/latest)** / Pobierz najnowszy build ze **[strony wydań](https://github.com/parametryczny/gantrybar/releases/latest)**:

- **macOS** — `Gantry-macOS-*.zip` (access codes in the macOS Keychain / kody dostępu w pęku kluczy macOS)
- **Windows x64** — installer `Gantry-Setup-Windows-x64.exe` (recommended / zalecany) or portable `Gantry-Windows-x64.zip`
- **GNU/Linux** — `.deb` package (beta, GTK)

The Windows installer starts Gantry after installation and enables launch at sign-in; neither Windows download requires a separate .NET installation. / Instalator Windows uruchamia Gantry po instalacji i włącza start przy logowaniu; żaden wariant Windows nie wymaga osobnej instalacji .NET.

### Windows 11 beta / Podgląd wersji beta

<p align="center">
  <img src="docs/renders/bambubar-windows-11-beta.jpg" width="72%" alt="Gantry Windows 11 beta dashboard and system tray menu">
</p>

---

## English

A compact, MIT-licensed macOS menu bar, Windows system-tray and GNU/Linux monitor named Gantry. The applications discover printers on the local network and present larger fleets in an adaptive dashboard.

### Latest changes

Version 0.5.0 adds the first GNU/Linux/Raspberry Pi beta with Bambu Lab, Klipper/Moonraker and PrusaLink support, a GTK dashboard, Secret Service credentials and a Debian package.

[Read the full changelog](CHANGELOG.md)

### Features

- monitors multiple printers from one menu bar popover
- supports Bambu Lab, Klipper/Moonraker and PrusaLink locally on all three desktop platforms
- supports persistent drag-and-drop printer card reordering
- offers a compact one-line status mode when four or more printers are configured
- shows print state, progress, ETA, layers and temperatures
- displays regular four-slot AMS and single-slot AMS units correctly
- preserves empty AMS positions and highlights active or low-filament slots
- reports HMS errors and useful printer notifications
- reconnects automatically and refreshes printer addresses on the local network
- discovers printers via SSDP multicast — now sent on every local network interface, not just the default route — plus a unicast subnet scan; a VPN like Tailscale carries no multicast, so a VPN printer is found by adding its IP, CIDR or range as an extra scan target (not by SSDP)
- supports Polish and English, light and dark appearance
- offers a Local build and a macOS Keychain build
- pins each printer's TLS certificate after the first trusted connection
- communicates locally without requiring a Bambu Cloud account
- includes a self-contained Windows x64 system-tray build with per-user DPAPI encryption
- includes a GTK 3 GNU/Linux beta with Secret Service storage and a Debian package

### Requirements

- macOS 26 or newer, 64-bit Windows 10/11, or a Debian/Ubuntu-family GNU/Linux desktop for the Linux beta
- a Mac or PC and the printers on the same local network
- LAN access enabled on each printer
- the serial number and Access Code/PIN for each printer
- Swift 6 and Xcode Command Line Tools when building from source
- .NET 8 SDK when building the Windows version from source
- Python 3.10, GTK 3 and Ayatana AppIndicator when running the GNU/Linux version

### Adding printers

#### Import from Bambu Studio

If Bambu Studio is installed and already has your printers configured, Gantry can match printers discovered on the local network with access codes stored in the local Bambu Studio configuration.

1. Connect the Mac and printers to the same local network and enable LAN access on every printer.
2. Make sure the printers are configured and visible in Bambu Studio.
3. Click the Gantry icon in the menu bar and then `+`.
4. Wait for the network scan to finish; it normally takes about 4 seconds and stops after 8 seconds.
5. Click **Import printers and codes**. Codes are saved using the storage mode of the installed build.

Installing Bambu Studio alone is not enough: the printers and their access codes must already be present in its local configuration.

#### Automatic network discovery

Click the Gantry icon, choose `+`, select a printer from **Detected**, enter its Access Code/PIN and click **Add**. Gantry fills in the detected name, IP address and serial number automatically.

#### Manual setup

If discovery is blocked, enter the printer name, local IP address, serial number and Access Code/PIN manually. The name is optional; IP address, serial number and access code are required. Check macOS Local Network permission, guest-network isolation and VLAN separation if no printers are found.

### Build and run

Clone the repository and build either application variant:

```bash
git clone https://github.com/parametryczny/gantrybar.git
cd gantrybar
chmod +x scripts/build-app.sh scripts/build-release.sh
./scripts/build-app.sh local
./scripts/build-app.sh keychain
```

The applications are created at `dist/Gantry.app` and `dist/Gantry Keychain.app`. Run `./scripts/build-release.sh` to create both release ZIP archives.

See [windows/README.md](windows/README.md) for Windows build instructions. GitHub Actions produces a self-contained `BambuBar.exe` that does not require the .NET runtime on the target PC.

See [linux/README.md](linux/README.md) for the GNU/Linux beta, local tests and `.deb` build instructions.

On the first launch, allow Local Network access when macOS asks for it.

### Tests

```bash
swift build --disable-sandbox
.build/debug/Gantry --self-test
.build/debug/Gantry --storage-self-test
.build/debug/Gantry --certificate-pin-self-test
```

The self-test covers SSDP parsing, subnet-target parsing, MQTT framing, Unicode print names, telemetry and both four-slot and single-slot AMS layouts. Run the unit tests with `./scripts/run-tests.sh`.

### Privacy

Gantry reads printer status only from the local network. The **Local** build stores access codes in the app's preferences; the **Keychain** build stores them in the macOS Keychain. Bambu Studio configuration is read only after the user selects **Import printers and codes**.

See [SECURITY.md](SECURITY.md) for the local network trust model and vulnerability reporting guidance.

### Project status

This is an early, community-built release. Bambu Lab's printer MQTT protocol is not a stable public API, so firmware changes may require updates to Gantry.

Gantry is an independent project and is not affiliated with, endorsed by or sponsored by Bambu Lab. Bambu Lab and related product names are trademarks of their respective owners.

---

## Polski

Kompaktowy monitor drukarek 3D na licencji MIT: Gantry dla macOS, Windows i GNU/Linux. Aplikacje wykrywają drukarki w sieci lokalnej i prezentują większe floty na adaptacyjnym pulpicie.

### Najnowsze zmiany

Wersja 0.5.0 dodaje pierwszą betę GNU/Linux/Raspberry Pi z obsługą Bambu Lab, Klipper/Moonraker i PrusaLink, pulpitem GTK, zapisem kodów w Secret Service i paczką Debiana.

[Zobacz pełny changelog](CHANGELOG.md)

### Funkcje

- monitoruje wiele drukarek z jednego okienka w pasku menu
- lokalnie obsługuje Bambu Lab, Klipper/Moonraker i PrusaLink na wszystkich trzech platformach desktopowych
- pozwala trwale porządkować karty drukarek metodą przeciągnij i upuść
- oferuje kompaktowy, jednoliniowy tryb statusu przy czterech lub więcej drukarkach
- pokazuje stan druku, postęp, szacowany czas, warstwy i temperatury
- poprawnie wyświetla zwykłe AMS z czterema slotami oraz jednoslotowe
- zachowuje puste pozycje AMS i wyróżnia aktywne sloty lub te z niskim poziomem filamentu
- zgłasza błędy HMS i przydatne powiadomienia z drukarki
- łączy się ponownie automatycznie i odświeża adresy drukarek w sieci lokalnej
- wykrywa drukarki przez multicast SSDP — teraz wysyłany na każdej karcie sieciowej, nie tylko domyślnej — oraz unicastowy skan podsieci; VPN (np. Tailscale) nie przenosi multicastu, więc drukarkę przez VPN znajdziesz, dodając jej adres IP, CIDR lub zakres jako dodatkowy cel skanu (nie przez SSDP)
- obsługuje polski i angielski, wygląd jasny i ciemny
- oferuje wariant Local oraz wariant z pękiem kluczy macOS
- przypina (pinuje) certyfikat TLS każdej drukarki po pierwszym zaufanym połączeniu
- komunikuje się lokalnie, bez konieczności posiadania konta Bambu Cloud
- zawiera samodzielną wersję dla Windows x64 z ikoną w zasobniku i szyfrowaniem DPAPI
- zawiera wersję beta GTK 3 dla GNU/Linux z systemowym Secret Service i paczką `.deb`

### Wymagania

- macOS 26 lub nowszy, 64-bitowy Windows 10/11 albo desktop GNU/Linux z rodziny Debian/Ubuntu dla wersji beta
- Mac lub PC i drukarki w tej samej sieci lokalnej
- włączony dostęp LAN na każdej drukarce
- numer seryjny i kod dostępu (Access Code / PIN) każdej drukarki
- Swift 6 i Xcode Command Line Tools przy budowaniu ze źródeł
- .NET 8 SDK przy budowaniu wersji Windows ze źródeł
- Python 3.10, GTK 3 i Ayatana AppIndicator dla wersji GNU/Linux

### Dodawanie drukarek

#### Import z Bambu Studio

Jeśli Bambu Studio jest zainstalowane i ma już skonfigurowane Twoje drukarki, Gantry może dopasować drukarki wykryte w sieci lokalnej do kodów dostępu zapisanych w lokalnej konfiguracji Bambu Studio.

1. Podłącz Maca i drukarki do tej samej sieci lokalnej i włącz dostęp LAN na każdej drukarce.
2. Upewnij się, że drukarki są skonfigurowane i widoczne w Bambu Studio.
3. Kliknij ikonę Gantry w pasku menu, a następnie `+`.
4. Poczekaj na zakończenie skanowania sieci; zwykle trwa około 4 sekund i kończy się po 8 sekundach.
5. Kliknij **Importuj drukarki i kody**. Kody są zapisywane zgodnie z trybem przechowywania zainstalowanego wariantu.

Sama instalacja Bambu Studio nie wystarczy: drukarki i ich kody dostępu muszą już być obecne w jego lokalnej konfiguracji.

#### Automatyczne wykrywanie w sieci

Kliknij ikonę Gantry, wybierz `+`, zaznacz drukarkę na liście **Wykryte**, wpisz jej kod dostępu (Access Code / PIN) i kliknij **Dodaj**. Gantry automatycznie uzupełni wykrytą nazwę, adres IP i numer seryjny.

#### Konfiguracja ręczna

Jeśli wykrywanie jest zablokowane, wpisz ręcznie nazwę drukarki, lokalny adres IP, numer seryjny i kod dostępu. Nazwa jest opcjonalna; adres IP, numer seryjny i kod dostępu są wymagane. Gdy nie znaleziono żadnych drukarek, sprawdź uprawnienie macOS do sieci lokalnej, izolację sieci gościnnej oraz podział na VLAN-y.

### Budowanie i uruchamianie

Sklonuj repozytorium i zbuduj wybrany wariant aplikacji:

```bash
git clone https://github.com/parametryczny/gantrybar.git
cd gantrybar
chmod +x scripts/build-app.sh scripts/build-release.sh
./scripts/build-app.sh local
./scripts/build-app.sh keychain
```

Aplikacje powstają jako `dist/Gantry.app` oraz `dist/Gantry Keychain.app`. Uruchom `./scripts/build-release.sh`, aby utworzyć oba archiwa ZIP do wydania.

Instrukcja budowania wersji Windows znajduje się w [windows/README.md](windows/README.md). GitHub Actions tworzy samodzielny `BambuBar.exe`, który nie wymaga środowiska .NET na komputerze docelowym.

Instrukcja wersji GNU/Linux, testów lokalnych i budowania paczki `.deb` znajduje się w [linux/README.md](linux/README.md).

Przy pierwszym uruchomieniu zezwól na dostęp do sieci lokalnej, gdy macOS o to zapyta.

### Testy

```bash
swift build --disable-sandbox
.build/debug/Gantry --self-test
.build/debug/Gantry --storage-self-test
.build/debug/Gantry --certificate-pin-self-test
```

Self-test obejmuje parsowanie SSDP, parsowanie celów skanu, ramkowanie MQTT, nazwy druków z Unicode, telemetrię oraz układy AMS cztero- i jednoslotowe. Testy jednostkowe uruchomisz przez `./scripts/run-tests.sh`.

### Prywatność

Gantry odczytuje status drukarek wyłącznie z sieci lokalnej. Wariant **Local** przechowuje kody dostępu w ustawieniach aplikacji; wariant **Keychain** przechowuje je w pęku kluczy macOS. Konfiguracja Bambu Studio jest odczytywana dopiero po wybraniu przez użytkownika opcji **Importuj drukarki i kody**.

Zobacz [SECURITY.md](SECURITY.md), gdzie opisano model zaufania w sieci lokalnej oraz zasady zgłaszania podatności.

### Status projektu

To wczesne wydanie tworzone przez społeczność. Protokół MQTT drukarek Bambu Lab nie jest stabilnym, publicznym API, więc zmiany firmware'u mogą wymagać aktualizacji Gantry.

Gantry jest projektem niezależnym i nie jest powiązany z Bambu Lab, wspierany ani sponsorowany przez Bambu Lab. Bambu Lab i powiązane nazwy produktów są znakami towarowymi ich właścicieli.

---

## Author / Autor

**Kamil Grzegorczyk**

- GitHub: [@parametryczny](https://github.com/parametryczny)
- X: [@parametryczny](https://x.com/parametryczny)
- Support / Wsparcie: [suppi.pl/parametryczny](https://suppi.pl/parametryczny)

## License / Licencja

[MIT](LICENSE)

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
Wkład jest mile widziany. Przed otwarciem pull requesta zobacz [CONTRIBUTING.md](CONTRIBUTING.md).
