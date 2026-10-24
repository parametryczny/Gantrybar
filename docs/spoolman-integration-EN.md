# Spoolman in Gantry

Local development integration added after release 0.14.0. This describes the new code, not an update to the published installers.

## Setup

1. Open **Settings → General → Inventory: Spoolbase / Spoolman…**.
2. Select **Spoolman** and enter the server address, e.g. `http://spoolman.local:7912`. A trailing `/api/v1` is optional.
3. Enter a Bearer token only if your reverse proxy requires one. Standard Spoolman does not require this token. A blank field retains the previously saved secret for this address.
4. Click **Test connection**, then **Save and restart**. Alternatively, use **Save** and restart Gantry manually. Changing the source, address or reporting mode requires a restart.

Spoolman replaces local inventory in views, AMS/EXT assignments, cost calculation from the assigned spool and the web dashboard. Local Spoolbase data is retained and is never silently used as fallback inventory when the server is unavailable.

Inventory refreshes approximately every 15 seconds. Offline, Gantry shows the last saved snapshot with an availability message. Basic creation and editing are available directly in Gantry; deletion and advanced features remain available through **Edit in Spoolman**. A Gantry slot assignment is a local binding; it does not change the server's location field.

## Rolls, AMS and tags

- A filament/product and a physical roll have different identifiers. Two identical rolls remain separate.
- Each server address has a separate cache. Keep its address stable: changing an alias creates a distinct source.
- Automatic assignment requires one exact tag match stored in Spoolman (`tags[].uid` or the additional `tag` field). Gantry compares the identifier supplied by the printer; this is not a phone NFC reader.
- Colour and material type cannot identify a physical roll. Select an AMS/EXT roll manually if no matching tag is available.
- You can manually assign a different roll or unassign the current one even when the slot reports RFID. Manual choices survive printer telemetry, inventory refresh and restart. Unassignment does not delete the roll or change its weight in Spoolman. Automatic matching resumes for that slot only after a different, nonempty tag is observed.
- A different observed tag clears a binding made for the previous tag. An absent tag cannot reliably prove removal of a roll without RFID; correct those bindings manually.
- Finishing a print does not delete its spool. Unknown weight is shown as missing data, not zero. Empty and archived rolls are retained.

## Create and edit in Gantry

The active **Spoolman** window offers:

- **Add filament…**: product definition: name, material, an existing Spoolman vendor (or no vendor), a colour picker or HEX, density, diameter, full net weight and an optional price.
- **Add spool…**: a new physical roll of an existing filament, including a filament with no rolls yet. Set initial and remaining net weight, tare, price and location. Each roll gets its own ID.
- **Edit filament…** beside a roll: edits its shared filament definition. Name, material and colour apply to every roll of that filament. Renaming does not remove multicolour settings; explicitly changing colour replaces them with one colour.
- **Correct weight…** beside a roll: sets the remaining grams of that physical roll only. Enter **filament weight without the empty spool**. If initial weight is unknown, enter it in the form; remaining weight cannot exceed it.

Price uses the currency configured in Spoolman; Gantry does not convert it. An empty optional price means no price, not zero.

**Save to Spoolman** writes to the server and refreshes inventory. Manual editing works with automatic usage reporting off. It does not modify RFID data or colour on the printer. Updates contain only edited fields: other metadata, tags, history and settings are retained. Adjusting initial or remaining weight may recalculate the aggregate used weight in Spoolman.

The server or proxy must allow writes. Failed writes never create a local replacement. If acknowledgement is lost, Gantry does not retry and disables further submission in that form: close it, refresh and check server data before trying again.

## Who reports usage?

**Gantry reports usage to Spoolman** defaults to off.

| Situation | Setting |
| --- | --- |
| Moonraker, Bambuddy, HaspelSync or another Gantry already reports usage | Off: Gantry reads inventory and keeps its own print history |
| This Gantry instance should report consumption of assigned rolls | On in one Gantry instance only |

Reporting uses Gantry's existing print accounting and physical spool assignment. It does not invent consumption when data or assignments are missing. This integration does not introduce automatic weighing or a 0.1 g accuracy claim.

Gantry persists an intent before sending a usage request and blocks repeat reports of the same print. If the reply is lost, the outcome is marked uncertain and **is not automatically retried**. Check Spoolman and make any necessary correction there. Do not run another tool that subtracts the same consumption.

Prices use Gantry's selected currency without exchange-rate conversion. Match the currency and net/gross cost basis in both systems.

## Move data into Spoolbase

Import is available without selecting Spoolman as the active source:

1. Enter the address in inventory configuration and choose **Import into Spoolbase…**.
2. Review the count of new rolls and confirm.
3. To use Gantry alone afterwards, select **Spoolbase**, save and restart.

This is a one-way, additive import. It retains weights, prices, tags, dates, location text, archive status and source metadata. It does not convert currencies or reconstruct historical prints. Select AMS/EXT assignments again. Repeated imports from the same address neither duplicate records nor overwrite local corrections.

Before import, Gantry backs up products, rolls and local usage events into `Spoolman-import-backups` under its application data. The Spoolman server is not modified.

## Scope and validation

The implementation covers macOS, Windows, Linux and the web data projection. Validation uses an isolated Spoolman 0.27.0 installation and fictional rolls. Physical farm operation and coexistence with external usage reporters still require user-side validation.

HaspelSync and bambulab-spoolman were behavioural references; their source code was not copied. A separate Bambuddy API connection is outside this integration.
