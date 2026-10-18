# Build and contribute

[Polski](development-PL.md) · [Gantry](../README.md)

These instructions build the checked-out sources, which may differ from a public release. Use fictional printer data and keep credentials out of fixtures, screenshots and commits.

## Development checkout

The public `main` branch currently contains release information and documentation, not the complete application sources. The commands below apply to a development checkout containing `Sources/`, `windows/Gantry.Windows/` and `linux/gantry/`. Cloning the public documentation branch alone is not sufficient to build the app.

## macOS

Use Swift 6 and Xcode Command Line Tools on a compatible macOS development machine. The deployment minimum is declared in `Package.swift` and `Resources/Info.plist`; a successful build is not a substitute for testing the minimum system.

```sh
swift build --disable-sandbox
.build/debug/Gantry --self-test
./scripts/run-tests.sh
./scripts/build-app.sh local
```

The application bundle is written to `dist/Gantry.app`. Packaging may need the pinned camera decoder and model resources used by the build script. Keychain checks require an unlocked, interactive session. See `scripts/build-app.sh` and `scripts/build-dmg.sh` for packaging.

## Windows

Use the .NET 8 SDK on Windows for WPF development.

```powershell
dotnet restore windows/Gantry.Windows/Gantry.Windows.csproj
dotnet build windows/Gantry.Windows/Gantry.Windows.csproj -c Release
dotnet run --project windows/Gantry.Windows/Gantry.Windows.csproj
```

The Windows workflow publishes a self-contained package and builds the installer. A compilation on another host does not validate tray behaviour, camera playback or notifications on Windows.

## Linux

Use Python 3.10 or newer, GTK 3 / PyGObject, a desktop tray provider and Secret Service. The complete package dependencies are declared in `linux/packaging/` and `.github/workflows/linux.yml`.

```sh
PYTHONPATH=linux python3 -m unittest discover -s linux/tests -v
PYTHONPATH=linux python3 -m gantry
```

Run graphical checks in a desktop session or Xvfb. Package builders are `linux/scripts/build-deb.sh`, `build-rpm.sh` and `build-appimage.sh`; RPM/AppImage packaging needs the corresponding Linux build tools.

## Review a change

Run the checks relevant to the changed area. Verify user-visible behaviour on the target systems; a parser test does not validate a desktop window. For UI changes, include PL/EN screenshots with demonstration data and check both narrow and wide layouts.

[Contribution guidelines](../CONTRIBUTING.md)
