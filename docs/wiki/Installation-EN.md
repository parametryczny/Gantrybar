# Installation and updates

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Installation-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

This guide covers Gantry 0.14.0. [Download the release](https://github.com/parametryczny/Gantrybar/releases/tag/v0.14.0) and choose the package for your system.

## Choose an asset

| System | Package | Use |
| --- | --- | --- |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS.dmg` | drag Gantry into Applications |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS-Local.zip` | complete app in a ZIP; credentials use system key storage |
| macOS, Apple Silicon / Intel | `Gantry-0.14.0-macOS-Keychain.zip` | alternate application identifier; keep this variant if already in use |
| Windows 10/11 x64 | `Gantry-Setup-Windows-x64.exe` | PL/EN installer with the .NET runtime included |
| Windows 10/11 x64 | `Gantry-Windows-x64.zip` | portable folder; extract everything |
| Linux x86_64 | `.deb` file | Debian / Ubuntu derivatives |
| Linux x86_64 | `.rpm` file | Fedora and compatible distributions |
| Linux x86_64 | `.AppImage` file | portable launch without package installation |

Linux assets include the application runtime and are built on Ubuntu 24.04; they require glibc 2.39 or newer and a graphical session. They are not ARM/Raspberry Pi packages. Check architecture with `uname -m`; the filename and package metadata identify each asset's architecture.

## macOS

1. Open the DMG and drag **Gantry.app** into **Applications**. Extract ZIP files first.
2. Close the previous Gantry before replacing it. Keep your Local/Keychain variant to retain its application identifier and data location.
3. Allow local-network access and, optionally, notifications at first launch.
4. If macOS blocks the downloaded app, use the standard **System Settings → Privacy & Security → Open Anyway** action for Gantry. Do not disable system protection globally.

The Local variant also stores new access codes in Keychain; the filename does not mean plaintext password storage. The package is not Apple-notarised.

## Windows

Choose **Polski** or **English** in the installer. Installation is per-user; a separate .NET installation is unnecessary. A Start menu shortcut is added; change autostart in Gantry settings. Uninstallation preserves user data.

For ZIP, launch `Gantry.exe` from the extracted folder; keep the accompanying files. Close Gantry and replace the whole folder when updating. These test assets do not have a commercial publisher signature.

## Linux

Install `.deb` using your package manager or `sudo apt install ./NAME.deb`. For `.rpm`, use `sudo dnf install ./NAME.rpm`. Check the filename and architecture first.

For AppImage, run `chmod +x NAME.AppImage`, then `./NAME.AppImage`. If FUSE mounting is unavailable, use `./NAME.AppImage --appimage-extract-and-run`. A tray icon may require AppIndicator support in your desktop environment.

## Updating without deleting data

Close Gantry, install the same variant and reopen it. Do not delete printers, stock or history to refresh the interface. Keep your own backup before major changes. Hosted web files are a separate installation; updating the desktop app does not update your server.

Farm starts disabled: **Settings → General**. LITE hides most tools: **Settings → Advanced**. If Spoolbase is absent, also check its switch in General.

## Checksums

The release's `SHA256SUMS.txt` lists the exact attached packages. macOS: `shasum -a 256 NAME`; Linux: `sha256sum NAME`; Windows PowerShell: `Get-FileHash .\NAME -Algorithm SHA256`. Compare the complete digest. A checksum identifies a file; it does not replace a publisher signature.

[Add your first printer](https://github.com/parametryczny/Gantrybar/wiki/Getting-started-EN) · [Troubleshooting](https://github.com/parametryczny/Gantrybar/wiki/Troubleshooting-EN)
