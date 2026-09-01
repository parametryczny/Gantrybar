# Anycubic Kobra S1

Gantry supports the Anycubic Kobra S1 locally on macOS, Windows and GNU/Linux. It reads print
state, progress, remaining time, layers, nozzle/bed/chamber temperatures, fans and ACE Pro slots.
Pause, resume, stop and chamber-light controls are available through the same Gantry UI as for
other printers.

## Add the printer

1. On the Kobra S1 open **Settings → Network** and enable **LAN mode**.
2. In Gantry click `+`, choose **Anycubic**, enter a name and the printer IP.
3. Leave the bootstrap port at `18910`, unless the connection is deliberately forwarded through
   another port, and save.

No Anycubic account, cloud login or manually copied access code is required. Gantry requests a
short-lived local MQTT configuration from the printer and keeps it in memory only.

## Camera

The camera is read from `http://PRINTER_IP:18088/flv`. Gantry asks the printer to start capture
when the MQTT session connects. Windows release packages include `ffmpeg`; a macOS build bundles
it when it is present on the build Mac (development builds also use Homebrew `ffmpeg`). Linux uses
GStreamer. If video is blank, first confirm that camera view works in Anycubic Slicer and that TCP
port `18088` is reachable from the computer.

## Troubleshooting

- **Enable LAN mode** — the printer is still configured for cloud control.
- **No response on 18910** — check the IP, VLAN/firewall rules and that the computer is on the same
  local network.
- **Status works but camera does not** — allow port `18088` and reopen the camera after the printer
  has completed its MQTT connection.

The LAN protocol is community-documented and may change with printer firmware. The implementation
was based on the community projects [Anycubic S1 MQTT Bridge](https://github.com/metheos/anycubic-s1-mqtt-bridge)
and [Anycubic/Snapmaker Remote Cam LAN](https://github.com/PrintsNCode/Anycubic-Snapmaker-remote-cam-lan).
