# Gantry native-source artwork

Final composition: `../gantry-two-modes-from-code-v4.png` (2800 × 1950).
No image-generation model is used in this version. All app content, typography, icons, progress,
AMS, layout and native window controls are rasterized by the production AppKit views.

## Provenance

- `scripts/render_native_campaign.swift` instantiates `PrinterDashboardViewController` twice:
  `.popover` in an `NSPopover`, and `.floatingWindow` via `FloatingDashboardWindowController`.
- Four isolated demonstration printers are injected using a `GANTRY_RENDER`-only initializer.
  The normal store initializer, migration/keychain access and network connections are not run.
  The render executable uses its own defaults domain and suppresses legacy settings migration.
- The application is not rebuilt, installed, restarted or changed for the user.
- `scripts/compose_native_campaign.swift` arranges those exported images and editorial text.
- The orange marker uses the actual toggle's view coordinates, exported to `window-toggle.json`.
  The toolbar enlargement is cropped directly from `macos-window.png`.

## Limits, intentionally not concealed

This machine provides macOS/AppKit, not Windows WPF or a Linux desktop session. The artwork names
the supported platforms but explicitly labels the pictured interface as macOS. It does not invent
a Windows taskbar, a Linux tray, or screenshots of those environments.

Computer Use permission was unavailable. AppKit's offscreen cache on this macOS version cannot
faithfully export the compositor-owned translucent popover border (its frame export has colored
artifacts). The final artwork therefore uses `macos-popover-content.png`, without that outer
system-glass frame. The menu icon is the real `GantryLogo.statusItemImage`, shown separately with
an editorial label, not placed inside a fabricated system menu bar. Inactive native window buttons
are left inactive; no red/yellow/green replacement is drawn. Genuine desktop captures are needed
for the final photographic OS-shell treatment.

## Rebuild from the repository root

```sh
swiftc -suppress-warnings -DGANTRY_RENDER -DKEYCHAIN_STORAGE \
  -Xfrontend -disable-dynamic-actor-isolation \
  -module-cache-path /private/tmp/gantry-swift-cache -I Sources/CCommonCrypto \
  $(rg --files Sources/Gantry -g '*.swift' | rg -v '/GantryApp.swift$') \
  scripts/render_native_campaign.swift -o /private/tmp/gantry-native-campaign-render
/private/tmp/gantry-native-campaign-render design/marketing/native-source
swiftc -module-cache-path /private/tmp/gantry-swift-cache \
  scripts/compose_native_campaign.swift -o /private/tmp/gantry-compose-campaign
/private/tmp/gantry-compose-campaign design/marketing/native-source \
  design/marketing/gantry-two-modes-from-code-v4.png
```

The two `GANTRY_RENDER` conditionals are excluded from normal app builds: fixture injection and
the offscreen window's screen-bound constraint override. Production UI layout is not replaced.
