# Gantry for GNU/Linux — beta

The GNU/Linux edition uses GTK 3 and a system tray indicator. It connects locally to Bambu Lab
over MQTT/TLS, Klipper through Moonraker and Prusa through PrusaLink. Access codes and API keys
are stored in the desktop Secret Service (GNOME Keyring, KWallet with Secret Service support, or
another compatible provider).

Per-printer menus can open installed native or Flatpak editions of Bambu Studio, OrcaSlicer,
Creality Print and PrusaSlicer. For Bambu printers the Bambu Studio action also provides access
to the camera view.

## Install on Ubuntu, Debian, Linux Mint or Pop!_OS

Download `Gantry-0.6.0-Linux-all-hotfix.deb` from GitHub Releases, then run:

```sh
sudo apt install ./Gantry-0.6.0-Linux-all-hotfix.deb
```

Open **Gantry** from the application menu. The app can be configured to start automatically
after login in **Settings**.

![Gantry hotfix verified on Ubuntu 26.04](../docs/renders/gantry-ubuntu-26.04-hotfix.png)

## Add printers

Choose **Add printer** from the tray menu or click `+`, then select **Bambu Lab**, **Klipper** or
**Prusa**. Gantry scans every local network interface using Bambu SSDP announcements and the
MQTT/TLS certificate exposed on port 8883. The add window accepts a VPN/Tailscale IP, range or
CIDR and a custom MQTT port for a TCP/socat tunnel.

Klipper uses the local Moonraker API (port 7125 by default) with an optional API key. Happy Hare
MMU is read through Moonraker and Creality CFS through the printer's local WebSocket. Prusa uses
PrusaLink (port 80 by default) and its API key; no Prusa cloud account is required.

**Import from Bambu Studio** reads `BambuStudio.conf` from the native XDG path and the common
Flatpak paths. Imported access codes are immediately moved into the system Secret Service; they
are not written to Gantry's JSON settings.

Standard Linux and the RPi kiosk also accept bulk CSV. Existing five-column Bambu files remain
compatible; the current template is:

```csv
kind,name,host,serial,access_code,port
bambu,P1S Workshop,192.168.1.21,01P00A123456789,ACCESS_CODE,8883
klipper,Voron,192.168.1.30,,,7125
prusa,MK4,192.168.1.31,,PRUSALINK_API_KEY,80
```

## Build a Debian package

```sh
GANTRY_PACKAGE_SUFFIX=hotfix sh linux/scripts/build-deb.sh
```

The hotfix package is written to
`linux/dist/Gantry-0.6.0-Linux-all-hotfix.deb`. Omit
`GANTRY_PACKAGE_SUFFIX=hotfix` to produce the regular release filename. Core tests do not require
a graphical session:

```sh
PYTHONPATH=linux python3 -m unittest discover -s linux/tests -v
```

The Linux version is currently beta. KDE users need a Secret Service provider enabled; the
package uses `secret-tool` and will show an error instead of saving an access code in plain text.

Author: **Kamil Grzegorczyk** — [GitHub](https://github.com/parametryczny),
[X](https://x.com/parametryczny), [support](https://suppi.pl/parametryczny).

## Raspberry Pi workshop kiosk

On 64-bit Raspberry Pi OS with Desktop, install the same architecture-independent `.deb`, then
enable the workshop dashboard for the current desktop user:

```sh
gantry-kiosk-setup
gantry-kiosk
```

The setup command creates an XDG autostart entry and a CSV template in the user's Documents folder. Gantry
starts full-screen after login, prevents idle sleep where the desktop supports it and shows the
pairing address and six-digit code at the bottom of the screen.

Configuration is available in two places:

- click **Konfiguracja** on the connected display to scan, add or edit printers
- open the HTTPS address shown on the display from a phone or computer on the same LAN, accept the
  local certificate on first use, then enter the rotating pairing code

The remote panel shows live printer telemetry (refreshed every 15 seconds) and supports individual
printers and bulk CSV import. Download its template or use:

```csv
kind,name,host,serial,access_code,port
bambu,Drukarka warsztatowa,192.168.1.50,NUMER_SERYJNY,KOD_DOSTEPU,8883
```

The CSV contains printer access codes. Remove it after a successful import. Codes are moved into
the desktop Secret Service and are not copied to Gantry's JSON settings. SSH is only needed for
system updates and diagnostics.

Disable kiosk autostart with:

```sh
gantry-kiosk-setup --disable
```
