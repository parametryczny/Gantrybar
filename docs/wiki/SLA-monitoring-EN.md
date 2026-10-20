# Local SLA and Fiberpunk monitoring

[Polski](https://github.com/parametryczny/Gantrybar/wiki/SLA-monitoring-PL) · [Home](https://github.com/parametryczny/Gantrybar/wiki/Home)

These integrations are experimental. Parsers and simulated connections have been checked; no physical printers were available for validation. Compatibility depends on the model, firmware and connection mode.

## Adding a printer

Choose **Add printer → SLA / MSLA** (macOS: **SLA**) and select a model. Fiberpunk has a separate **Fiberpunk** choice. Monitoring continues with details closed while Gantry runs.

| Model | Local connection | Available readings |
|---|---|---|
| Elegoo Saturn 4 Ultra 12K / 16K, Mars 5 Ultra | SDCP v3 WebSocket 3030; UDP discovery 3000 | State, job, layer-based progress, layers and time |
| Elegoo Saturn 3 Ultra / Mars 4 Ultra | Legacy SDCP, UDP 3000 | State, job, layers and time; progress derived from layers |
| Anycubic Photon Mono X 6K | TCP 6000, `getstatus` | State, job, progress, layers and time |
| Anycubic Photon P1 / P1 Max | HTTP 18910 → local MQTT TLS 8883 | State, job, progress, layers and time when reported; P1 Max needs separate hardware confirmation |
| Prusa SL1 / SL1S SPEED | PrusaLink HTTP 80, legacy SLA API | State, job, progress, layers and time when reported |
| Formlabs Form 4 / 4B, Form 3 / 3+ / 3L | Computer running PreForm Server, HTTP 44388 | Human-readable status, connectivity and available remaining time; no invented percentage |
| Phrozen via OctoPrint / Chituboard | Existing compatible external OctoPrint bridge, HTTP 80 | State, job, progress and time exposed by the bridge |
| Fiberpunk Node / Node Pro | Adapter API, HTTP 88 | State from `/find`; temperatures, layers and progress from `/status` when reported |

### Elegoo

For Saturn 4 Ultra / Mars 5 Ultra, enter the IP and **MainboardID**, or select a discovered device. MainboardID identifies the SDCP board; it is not an arbitrary name. Choose the separate legacy model for Saturn 3 Ultra / Mars 4 Ultra: only its IP and UDP port 3000 are needed. Gantry sends `M99999` status requests only, never `M66666` or MQTT-server redirection commands.

### Photon P1 / P1 Max

Enable **LAN mode** and enter the printer IP. Gantry obtains the local connection configuration through port 18910, then reads MQTT reports. Close **Photon Workshop**: the printer uses a single client identifier, so concurrent clients may disconnect each other. Sharing the P1 implementation does not establish P1 Max hardware compatibility. Gantry does not start its camera or send control commands.

### Prusa

Enable PrusaLink and API-key authentication and enter the key in Gantry. SL1 uses `/api/printer` and `/api/job`, not FDM `/api/v1/...`. Keys use the application's existing printer-secret storage.

### Formlabs

Run **PreForm Server** and add your printer in PreForm. In Gantry, enter the **server computer's address**, port 44388 and the **printer's PreForm ID** from `/v1/device/list/`. This is not an API at the printer's own IP. Add each printer separately using its ID. Gantry only reads the device list; it does not log in to the cloud, initiate discovery or start jobs. Devices marked `REMOTE` are excluded.

The API explicitly defines `status` as human-readable, so Gantry does not infer “printing” from its wording. This endpoint does not expose reliable percentage, layers or filename. Gantry displays the status and available remaining time, without a misleading “0%” or “Waiting for print”.

### Phrozen

This is **monitoring through an existing bridge**, not native Sonic Mighty 8K Wi-Fi support. Enter your OctoPrint host and API key. Chituboard lists **Sonic Mighty 4K and Sonic Mini 4K**, among other printers; check model and firmware compatibility with the bridge. Gantry does not install or configure bridge hardware. The direct Mighty 8K protocol still needs confirmation.

### Fiberpunk

Enter the **adapter's** address, not the printer's. It is not OctoPrint. Gantry reads `/find` and `/status` only: no SD mounting, G-code or USB reset. Unknown state and ETA remain unavailable.

## Scope and limitations

These types are monitors only: no Farm, uploads, controls, AMS/Spoolbase or automatic FDM costing. Gantry Vision's spaghetti detector does not analyse SLA. Built-in SLA cameras are outside this integration. State notification preferences remain shared; an unclassified Formlabs status string does not trigger print-completion notifications.

SDCP resin and PreForm time values are milliseconds, Mono X and Prusa use seconds, and Photon P1 uses minutes. Missing data does not mean zero.

## Protocol references

[SDCP v3](https://github.com/cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0), [legacy Saturn protocol](https://github.com/JacobZwang/elegoo-saturn-4-ultra), [Photon P1 LAN protocol](https://github.com/modrzew/hass-anycubic-photon-p1), [Mono X](https://github.com/adamoutler/anycubic-python), [PrusaLink SL1/SL1S](https://help.prusa3d.com/article/prusalink-sl1-sl1s_146094), [Formlabs Local API](https://developer.formlabs.com/api-reference/devices/), [OctoPrint / Chituboard hardware requirements](https://github.com/rudetrooper/Octoprint-Chituboard), [Fiberpunk API](https://github.com/fiberpunk1/NodeWebPage/blob/main/NodeWebAPI.md).
