# Printer network

In the macOS version, open **Settings → Advanced → Printer network**. The standalone LITE build places this section in General.

**Separate printer network** is off by default. Enable it to reveal the adapter selection and connection options. Turning it off immediately restores system routes and retains the last saved adapter and strict setting. Re-enabling restores the saved configuration. The options below the switch still require Save.

- **Automatic** — existing behavior, using system routes.
- **Wi-Fi / Ethernet** — pick an available adapter of that type. The list below selects an exact adapter, including VPN interfaces. Its identifier is saved rather than its changing IP address.
- **Only the selected network** — on by default. If the adapter disappears, Gantry waits for it. Turning this off permits system routes when the selected adapter is unavailable.

The tiles edit a draft. **Save** persists the selection and renews printer and camera connections. Changes to the selected adapter are monitored in the background.

**Test connection** checks saved printers' TCP ports through the draft adapter. It sends no credentials or printer commands and does not validate login or camera images. Older UDP-only devices are excluded from this test.

## Example: printer Wi-Fi and phone internet

Keep the computer connected to the printer Wi-Fi. Attach a phone over USB and configure its internet connection in the operating system. Select Wi-Fi in Gantry and save. The system still controls other apps' internet; Gantry binds its device connections to the chosen adapter. This does not change service order, system routes or browser settings.

A normal single Wi-Fi adapter cannot join the printer Wi-Fi and a phone hotspot simultaneously. Two independent interfaces are needed, such as Wi-Fi + phone USB, Wi-Fi + Ethernet, or a second Wi-Fi adapter. This selection does not create a VPN or expose printers to the internet.

## HTTPS IP address limitation

In manual mode, HTTPS through Foundation requires the device hostname, such as `printer.local`. The system may bypass a proxy for a numeric HTTPS URL, so Gantry blocks that URL while a real adapter is available and pinned. Use a hostname or Automatic mode. Explicitly allowed system fallback with an unavailable adapter is exempt.

Native Bambu MQTT/TLS and JPEG/RTSP cameras use direct Network.framework binding and are unaffected. Existing HTTPS certificate validation is neither weakened nor replaced.

## Scope

Selection covers native printer connections, HTTP and WebSocket, cameras, transfers, local tools and smart plugs, SSDP/Elegoo discovery and subnet scanning. Telegram, updates and the hosting bridge retain system routes. The web server still listens according to its own configuration.

Changing networks interrupts existing device sessions. Gantry renews monitoring; an interrupted transfer may need a manual retry. Saving never starts a print or replays control commands.

Automated transport coverage is in `scripts/check_printer_network.py`. A physical Wi-Fi/USB switch test requires a computer with both connections active.
