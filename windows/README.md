# Gantry for Windows

**[English](#english)** · **[Polski](#polski)**

A system-tray port of Gantry for Windows, built with .NET 8 (WPF + WinForms tray).
It mirrors the macOS app: local-network discovery, MQTT-over-TLS monitoring for Bambu Lab and
Anycubic Kobra S1, certificate pinning, AMS/ACE/HMS details and notifications — no printer cloud account required.

![Gantry Windows 11 beta dashboard and system tray menu](../docs/renders/gantry-windows-11-beta.jpg)

---

## English

### Requirements

- Windows 10 or 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) to build (end users only need the .NET 8 **Desktop Runtime**, or use the self-contained publish)
- The Mac/PC and the printers on the same local network, LAN access enabled on each printer
- The serial number and Access Code/PIN of each printer

### Installation

Download `Gantry-Setup-Windows-x64.exe` from the latest GitHub Release. The per-user
installer does not require administrator rights, starts Gantry after installation and
enables launch at Windows sign-in. It also adds a Start menu shortcut and a standard
uninstaller. The portable ZIP remains available as an alternative.

### Build and run

```bat
cd windows
dotnet restore Gantry.Windows\Gantry.Windows.csproj
dotnet build   Gantry.Windows\Gantry.Windows.csproj -c Release
dotnet run   --project Gantry.Windows\Gantry.Windows.csproj
```

### Single-file executable

```bat
cd windows
dotnet publish Gantry.Windows\Gantry.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o publish
```

The result is the self-contained `folder windows\publish\ (Gantry.exe)`, which does not require a
separate .NET installation. The GitHub Actions workflow `.github/workflows/windows.yml`
packages it as `Gantry-Windows-x64.zip` on every relevant push.

### How it maps to the macOS app

| macOS (Swift / AppKit) | Windows (C# / .NET) |
| --- | --- |
| `NSStatusItem` menu bar | `NotifyIcon` tray + context menu (`UI/TrayIcon.cs`) |
| `NWConnection` + TLS | `TcpClient` + `SslStream` (`Services/MqttClient.cs`) |
| custom MQTT codec | `Services/MqttCodec.cs` (1:1 port) |
| SSDP multicast discovery | `Services/SsdpDiscovery.cs` (UDP 2021 / 239.255.255.250) |
| subnet cert-CN probe | `Services/SubnetDiscovery.cs` |
| certificate pinning | `Services/CertificatePinStore.cs` (SHA-256) |
| Keychain / defaults | `Services/Storage.cs` — JSON in `%AppData%\Gantry` + DPAPI for codes |
| status/AMS/HMS parsing | `Services/StatusParser.cs`, `Services/HmsResolver.cs` |
| notifications | tray balloon tips (`Services/NotificationService.cs`) |
| Launch at Login | `Services/LaunchAtLogin.cs` (HKCU Run key) |
| SwiftUI dashboard | WPF window (`UI/DashboardWindow.xaml`) |

### Storage & privacy

Access codes are encrypted with Windows DPAPI (per-user) and stored under
`%AppData%\Gantry\defaults.json`; certificate pins and settings live in the same file.
The app talks only to the local network. Bambu Studio codes are imported only after you
explicitly choose **Import from Bambu Studio** (reads `%AppData%\BambuStudio\BambuStudio.conf`).

---

## Polski

### Wymagania

- Windows 10 lub 11
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) do zbudowania (użytkownik końcowy potrzebuje tylko **.NET 8 Desktop Runtime** albo wersji self-contained)
- Komputer i drukarki w tej samej sieci lokalnej, włączony dostęp LAN na każdej drukarce
- Numer seryjny i kod dostępu (Access Code / PIN) każdej drukarki

### Instalacja

Pobierz `Gantry-Setup-Windows-x64.exe` z najnowszego wydania GitHub. Instalator działa
dla bieżącego użytkownika bez uprawnień administratora, uruchamia Gantry po instalacji i
włącza start aplikacji przy logowaniu do Windows. Dodaje również skrót w menu Start oraz
standardowy deinstalator. Wariant przenośny ZIP pozostaje dostępny jako alternatywa.

### Budowanie i uruchamianie

```bat
cd windows
dotnet restore Gantry.Windows\Gantry.Windows.csproj
dotnet build   Gantry.Windows\Gantry.Windows.csproj -c Release
dotnet run   --project Gantry.Windows\Gantry.Windows.csproj
```

### Pojedynczy plik .exe

```bat
cd windows
dotnet publish Gantry.Windows\Gantry.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o publish
```

Wynik to samodzielny `folder windows\publish\ (Gantry.exe)`, który nie wymaga osobnej instalacji
.NET. Workflow `.github/workflows/windows.yml` przy każdym odpowiednim pushu pakuje go jako
`Gantry-Windows-x64.zip`.

### Przechowywanie i prywatność

Kody dostępu są szyfrowane przez Windows DPAPI (dla użytkownika) i zapisywane w
`%AppData%\Gantry\defaults.json`; tam też trafiają piny certyfikatów i ustawienia.
Aplikacja komunikuje się wyłącznie z siecią lokalną. Kody z Bambu Studio są importowane
dopiero po świadomym wybraniu **Importuj z Bambu Studio**.

### Uwaga

Kompilacja jest wykonywana na Windows przez GitHub Actions. Przed oznaczeniem wersji jako
stabilnej zalecany jest test interfejsu, zasobnika, zapory i wykrywania drukarek na fizycznym
komputerze z Windows 10 lub 11.
