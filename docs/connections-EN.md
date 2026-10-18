# Printer connections

[Polski](connections-PL.md) · [Gantry](../README.md)

This page describes the current 0.14 development tree. For a public package, also check its release notes. Protocol support does not guarantee every function on every firmware version.

| Printer / service | Connection | What you need |
| --- | --- | --- |
| Bambu Lab | MQTT over TLS, normally port 8883 | IP, serial number and LAN access code. Use discovery or explicitly import Bambu Studio configuration. |
| Anycubic Kobra S1 | LAN MQTT/TLS; FLV camera | IP and enabled LAN mode; camera normally on port 18088. |
| Elegoo Centauri Carbon | SDCP / WebSocket 3030; MJPEG 3031 | IP and detected device identity; no access code. |
| Elegoo Centauri Carbon 2 | MQTT 1883; MJPEG 8080 | IP, serial number, access code and LAN-only mode. |
| Klipper / Moonraker | HTTP API, normally 7125 | Host, port and API key if authentication requires one. Includes compatible Creality, Qidi and Snapmaker U1 setups. |
| PrusaLink | HTTP API, normally 80 | IP, port and PrusaLink API key. |
| Snapmaker 2.0 / Artisan | Local HTTP API, normally 8080 | IP and approval on the printer touchscreen. Reauthorisation may be needed after a power cycle. |
| OctoPrint — 0.14 preview | HTTP API at the configured server address | Server URL and API key. |

## Network and credentials

Keep the computer and printers on a reachable LAN or VPN. Discovery broadcasts may not cross VLANs or a VPN; add the address manually when needed. Bambu discovery can scan additional individual addresses, ranges or CIDRs configured in the app.

Ports above are defaults, not instructions to forward them to the internet. For outside access use a VPN or Gantry’s [own-hosting bridge](wiki/Web-dashboard-EN.md).

Leaving the access-code field empty while editing preserves the saved code. Importing credentials from a slicer requires an explicit action. Never include access codes, API keys or real printer identifiers in an issue or screenshot.

## Cameras and materials

Built-in camera formats depend on the printer: Bambu RTSP/RTSPS, Kobra S1 FLV and supported HTTP JPEG/MJPEG webcams. A separate JPEG/MJPEG source can be configured in [Printer tools](wiki/Printer-tools-EN.md). A web page containing a video player is not a camera stream URL.

Moonraker camera rotation and mirror settings are respected. AMS, AMS HT, ACE Pro, Canvas, Happy Hare MMU and Creality CFS readings depend on available telemetry. A slot colour is not confirmation of a physical roll’s identity; use the [Spoolbase workflow](wiki/Spoolbase-EN.md).

Control commands and Farm uploads require support from the printer API and firmware. A working status card alone does not confirm command support.
