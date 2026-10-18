<div align="center">

<img src="docs/branding/gantry-appicon.png" width="72" alt="Gantry app icon">

# Gantry

### Your 3D printer fleet. One place.

Follow prints, organise filament, plan production and understand costs. Local monitoring, with optional access through your own hosting.

**English** · **[Polski](README.pl.md)**

**[Download](https://github.com/parametryczny/Gantrybar/releases/latest)** · **[Quick start](docs/wiki/Getting-started-EN.md)** · **[Guides](docs/wiki/Home.md)** · **[What’s new](docs/release-0.14.0.md)**

[![Release](https://img.shields.io/github/v/release/parametryczny/Gantrybar?label=stable)](https://github.com/parametryczny/Gantrybar/releases/latest) [![License](https://img.shields.io/github/license/parametryczny/Gantrybar)](LICENSE) [![Downloads](https://img.shields.io/github/downloads/parametryczny/Gantrybar/total)](https://github.com/parametryczny/Gantrybar/releases)

**macOS · Windows · Linux**

</div>

> **Release status:** the current public release is **0.12.0**. Screenshots and guides below preview **0.14.0**, which is still in development. Its release remains a draft; these additions are not included in the current stable download.

![Gantry 0.14 Modern fleet window with six demonstration printers](docs/renders/readme-modern-en.png)

*Actual Gantry interface, rendered with fictional printer data. Modern theme, 0.14 preview.*

Gantry keeps the fleet close: a menu-bar or tray preview, a full window, or a compact edge panel. Check progress, remaining time, temperatures, loaded filament and camera feeds without opening a separate slicer for every printer.

## Explore Gantry 0.14

| Area | What it helps you do |
| --- | --- |
| **Fleet** | Follow live status and cameras, receive notifications and adjust each printer’s tools. Choose Basic, Modern or a minimal LITE view. [Views](docs/wiki/Appearance-and-LITE-EN.md) · [Printer tools](docs/wiki/Printer-tools-EN.md) |
| **Farm** | Search sliced files, choose compatible printers, map materials and plan batches. Track pickup, quality checks and manual orders. [Farm guide](docs/wiki/Farm-EN.md) |
| **Filament** | See AMS, HT, MMU and external spools. Manage physical rolls in Spoolbase and link them to loaded slots. [Spoolbase](docs/wiki/Spoolbase-EN.md) |
| **Energy & costs** | Record metering-socket readings throughout a print, review history and export reports. Measured, partial and estimated values remain distinguishable. [Energy and reports](docs/wiki/Energy-and-reports-EN.md) |
| **Vision & maintenance** | Review suspected print failures, label frames and keep service tasks, schedules, problems and parts together. [Vision](docs/wiki/Gantry-Vision-EN.md) · [Maintenance](docs/wiki/Maintenance-EN.md) |
| **Remote access** | View the fleet on your LAN or generate a configured website package for your own hosting. Add Telegram alerts if you want them. [Web dashboard](docs/wiki/Web-dashboard-EN.md) |

### From file to finished batch

![Gantry 0.14 Farm: searchable files, six printers and material mapping](docs/renders/readme-farm-en.png)

*Native Farm preview with demonstration files, printer states and an example order.*

Prepare a file, select printers and map materials in one workspace. Queue batches, confirm pickup and accept or reject finished copies. Manual orders link a reference, SKU, quantity and deadline to a sliced plate. **WooCommerce and Etsy integrations are planned.**

Uploading a file alone does not start a print. Queue starts require explicit approval of a prepared, empty bed; Gantry does not reslice a file for a different printer.

## Download and start

Get the installer from **[the latest public release](https://github.com/parametryczny/Gantrybar/releases/latest)**. Choose the package for your system:

| System | Package |
| --- | --- |
| macOS | `Gantry-*-macOS.dmg`; alternative storage builds are ZIP archives |
| Windows x64 | `Gantry-Setup-Windows-x64.exe` or portable `Gantry-Windows-x64.zip` |
| Linux | `.deb`, `.rpm` or portable `.AppImage` |

Windows release packages include their runtime. Package requirements and installation notes belong to the selected release.

1. Install Gantry and allow local-network access when prompted.
2. Choose **Add printer…**, select its type and enter its address and required credentials.
3. Check the status card, then open Details to verify available readings and the camera.
4. Enable the optional modules you need. [Continue with the quick start](docs/wiki/Getting-started-EN.md).

### Printers

Bambu Lab · Anycubic Kobra S1 · Elegoo Centauri Carbon / CC2 · Klipper / Moonraker · PrusaLink · Snapmaker. The 0.14 preview also includes OctoPrint.

Available readings, filament systems, cameras and control commands depend on the printer and its firmware. [Connection requirements and protocols](docs/connections-EN.md).

## Your data, your setup

Local monitoring requires no Gantry account or Gantry-operated server. Optional hosting and Telegram send the data needed for the integrations you enable; remote viewing requires the Gantry computer to stay running and connected.

Vision can miss failures or raise false alarms. Confirm results against the camera image. Labelling a frame does **not** automatically retrain model weights. [How Vision works](docs/wiki/Gantry-Vision-EN.md).

## More views

<details>
<summary><strong>The edge panel</strong> — a compact view beside your work</summary>

![Gantry edge-panel promotional render](docs/renders/readme-edge-panel.png)

Existing promotional illustration. The current app lets you choose expansion on hover or click, select printers and show camera previews. [View settings](docs/wiki/Appearance-and-LITE-EN.md).

</details>

<details>
<summary><strong>Telegram</strong> — notifications and fleet access on your phone</summary>

Configure your own bot and chat; the Gantry computer provides the connection. [Telegram setup, commands and controls](docs/wiki/Telegram-EN.md).

</details>

## Guides and community

[All PL/EN guides](docs/wiki/Home.md) · [Troubleshooting](docs/wiki/Troubleshooting-EN.md) · [Release notes](docs/release-0.14.0.md)

Found a problem? [Open an issue](https://github.com/parametryczny/Gantrybar/issues) with your Gantry version, printer model, operating system and steps to reproduce. Remove access codes and other private data from logs and screenshots.

Created by **[Kamil Grzegorczyk / parametryczny](https://github.com/parametryczny)**. [Support development](https://buycoffee.to/parametryczny) · [Contribute](CONTRIBUTING.md) · [MIT license](LICENSE).
