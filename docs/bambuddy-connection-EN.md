# Bambuddy — monitoring in Gantry

Open **Settings → Integrations → Bambuddy connection**. Available on macOS, Windows and Linux, in Polish and English.

1. Enter the server address, e.g. `http://bambuddy.local:8000`. An `/api/v1` suffix is optional; reverse-proxy prefixes are preserved.
2. Create a Bambuddy API key with **Read Status** permission. Paste it into Gantry’s masked field. A blank field keeps the key saved for the same server.
3. **Test API** reads the list without saving. **Save** starts refreshing the printer list and status every 10 seconds.
4. Printers appear in Gantry’s main list and menu-bar/tray panel with a **Bambuddy** label. Inactive and disconnected devices appear offline, without fabricated progress or temperatures.

Readings include state, progress, job name, layers, remaining time and available temperatures. Gantry uses Bambuddy’s API, without opening separate MQTT connections to these devices. AMS appears on cards and in **AMS / Filaments**: materials, colours, levels, active slots, module humidity and temperature, including AMS HT and EXT. Empty slots keep their positions; missing measurements stay unknown. The API does not expose nominal spool mass, so Gantry does not invent remaining grams. Cameras and Bambuddy inventory import remain outside this integration’s current scope. Existing direct printers take priority when their physical serial number matches; the same device does not receive a duplicate card.

**Remove connection** removes the local address and key, cancels reads, and removes Bambuddy-owned cards. Directly configured Gantry printers remain. The server, its database and its server-side API key are not deleted.

**Demo without server** shows sample data inside the configuration panel only; it does not add synthetic printers to the main list. Source cards are recreated from the server when Gantry starts and are excluded from the saved list of direct connections.

Bambuddy printers display an API `{}` icon: green while connected and grey when the printer or API is unavailable. The colour describes the connection, not the print result: a pause or print error does not imply an API outage. The indicator appears on cards, compact rows and in Gantry CLI.

## Consumption and security

Gantry sends GET requests only, uses the `X-API-Key` header and rejects redirects. Compact status uses `remaining_seconds` without guessing units. Bambuddy cards do not issue controls or report consumption. The active inventory and accounting for direct printers remain governed by their existing settings.

List reads and authentication were verified with local Bambuddy 1.2.5.7. The five local TEST printers run as active simulations with print status and AMS. The test overlay opens no MQTT connections and emits no consumption events. Reads were verified through the real API and Gantry UI; physical-printer verification remains pending.

Sources: [Bambuddy API](https://wiki.bambuddy.cool/reference/api/), [permissions](https://wiki.bambuddy.cool/features/api-keys/).
