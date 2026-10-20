# Printer settings and tools

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Printer-tools-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

In full Gantry, open **sidebar → Printer settings** (the icon above Settings), then select a printer. In menu-bar/tray mode, choose **Printer settings** directly from the application menu. **Save printer settings** applies changes; switching printers keeps separate form drafts.

## External camera and notification photos

**External JPEG / MJPEG camera** takes a full HTTP/HTTPS still-image or MJPEG URL for any brand, including Prusa and Snapmaker. RTSP and HTML player pages are not supported by this override. Blank restores the standard printer camera and its orientation settings; the older camera-host override is retained separately. The source is shared by details, monitoring and the edge strip. Existing web/hosting camera access uses it too, subject to enabled access settings. Printer credentials are never sent to this URL. This override is for cameras without separate authentication; credentials in URLs are rejected.

**Photos in notifications** can be disabled per printer. A photo comes from the camera or the latest available preview frame; unavailable images do not block text notifications. Vision uses the exact alarm frame. Image presentation follows desktop notification settings. LITE does not open notification cameras.

## Web panel and custom button

**Web panel URL** opens a browser shortcut. PrusaLink/OctoPrint default to the printer address; Klipper defaults to web port 80, rather than Moonraker API port 7125. Other brands need an explicit URL if they expose a panel.

For a **Custom HTTP button**, enter a name, URL, GET/POST and optional JSON POST body. An optional Bearer token uses existing access-key storage. Other fields, including JSON, are ordinary preferences; use the token field for credentials. Blank token removes it; clear both name and URL to remove the button.

The button is available in printer details. A click sends one request and disables the button until it completes. Saving never executes it. Requests have a 10-second timeout and up to 64 KiB of JSON. Gantry does not follow redirects or automatically replay commands. Success appears as an HTTP status tooltip; errors are displayed. This is a manual action, not an automatic print-finished trigger.

## Alternate API address and polling

PrusaLink, Klipper/Moonraker and OctoPrint support an alternate HTTP/HTTPS API origin, without path/query, and separate printing/paused versus idle polling intervals. Configure another address of the same printer, e.g. a VPN endpoint. Its existing API key is used at that explicitly configured address.

A transport failure selects the other address for reconnection. API reads, controls and file transfers share the selection; mutating requests/uploads are not replayed at another address. Authentication and certificate-validation failures do not cause failover. Camera and the separate Creality CFS port remain separately configured. Polling: 1–300 seconds; blank retains 2 seconds. Existing disconnection retry/backoff remains in place. These settings do not alter MQTT, SDCP or other non-HTTP connections.

## Visibility, energy and filament

Per-printer settings also include external EXT spool visibility, menu-bar or tray progress, edge-strip visibility, strip camera, average power and machine wear. Open connection editing and socket configuration from this page. Klipper also exposes Moonraker object names, while supported printers offer custom light commands.

Blank average power uses the fleet default. A metering socket supplies real energy readings; [Energy and reports](https://github.com/parametryczny/Gantrybar/wiki/Energy-and-reports-EN) explains measurement, gaps and exports.
