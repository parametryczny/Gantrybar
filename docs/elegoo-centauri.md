# Elegoo Centauri Carbon in Gantry

Gantry supports both Centauri Carbon generations on macOS, Windows and GNU/Linux. In the add-printer window choose **Elegoo**, then select the exact model. The two generations intentionally use separate drivers because their protocols, authentication and camera ports are different.

| Model | Status/control | Authentication | Camera | Filament system |
|---|---|---|---|---|
| Centauri Carbon (CC1) | SDCP v3 over WebSocket `:3030` | none; MainboardID is used for routing | MJPEG `:3031/video` | external/single filament reported by the printer |
| Centauri Carbon 2 (CC2) | MQTT 3.1.1 `:1883` | user `elegoo` + printer access code; LAN-only required | MJPEG `:8080/?action=stream` | Canvas A1–A4 |

## Adding CC1

1. Choose **Elegoo → Centauri Carbon**.
2. Pick the printer found by UDP discovery or enter its IP and MainboardID manually.
3. Keep port `3030` unless the connection is forwarded through a tunnel. No access code is stored.

Gantry keeps one persistent SDCP connection, polls status when an idle firmware stops pushing it, and reconnects automatically. The camera reader also keeps one upstream MJPEG stream to avoid exhausting the printer's small connection pool.

## Adding CC2

1. On the printer, enable **LAN-only mode** in network settings.
2. Choose **Elegoo → Centauri Carbon 2**.
3. Pick a discovered device or enter IP and serial manually.
4. Enter the access code displayed by the printer and keep port `1883`.

The access code is stored in Keychain (macOS), DPAPI (Windows), or Secret Service (Linux), never in the plain printer configuration. Gantry performs MQTT registration, sends the required application heartbeat, merges delta status frames, refreshes state after sequence gaps and renders Canvas slots without inventing an unavailable remaining-filament percentage.

## Available data and controls

- print state, progress, ETA, current/total layer and file name;
- nozzle, bed and chamber temperatures;
- part, auxiliary and chamber fan values;
- CC2 speed mode and Canvas slots/colors/active tray;
- camera in printer details;
- pause, resume, stop and chamber light, including use from Gantry automations.

This integration is local-only and does not use an Elegoo cloud account. It follows the protocol behavior documented by [elegoo-homeassistant](https://github.com/danielcherubini/elegoo-homeassistant), [centauri-sentinel](https://github.com/LegalMarc/centauri-sentinel), [cc2-dash](https://github.com/merberg-ai/cc2-dash), and the real-device notes in [pycentauri](https://github.com/bjan/pycentauri). Firmware changes can still require adjustments; CC1/CC2 hardware validation should be repeated before each release.
