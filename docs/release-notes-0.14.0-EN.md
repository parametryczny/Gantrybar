# Gantry 0.14.0 — Modern, AMS, fleet maintenance and energy for every print

Gantry 0.14.0 brings together the compact Modern interface, a redesigned Farm, clearer AMS and Spoolbase handling, fleet maintenance, and energy and costs for every print. New printer tools include an external camera, notification photos, a web-panel shortcut, a custom HTTP button and an alternate API address.

The app requires no account or Gantry-operated cloud. It connects to printers locally; the optional internet dashboard runs on your own hosting.

## Highlights

- **Gantry Basic and Gantry Modern.** Two card templates, compact readings and consistent application headers.
- **New Maintenance & service.** In-service status, custom tasks and checklists, templates, hour-based and calendar schedules, problems with photos, cost history and spare-parts inventory.
- **Dedicated AMS / Filaments view.** Printer selection, colour slots, active feeder, percentage and grams, and Spoolbase roll assignments.
- **Farm: file → printers → materials.** Printer-family folders, a file list, AMS matching, preflight checks, queue and history.
- **Energy across the whole cycle.** Background readings from supported metering sockets, a power trace, kWh and costs in history.
- **Compact statistics and exports.** A report beside each print name and CSV export of the full history.
- **Spoolbase: orders, palettes and labels.** Editable imports, local OCR, manufacturer colours and QR labels.
- **Easier fleet operation.** Lighting across supported printers, improved header clicks and an option to expand the edge dock only after clicking.
- **Web access on desktop and phone.** App-style layouts, a hosting package generator, hidden-EXT preferences and a 30-day remembered login.
- **Printer tools.** External camera, notification photos, web panel, custom GET/POST, alternate API address and polling intervals.
- **LITE inside the full app.** Switch back to status-only monitoring in the menu bar or tray while preserving full-edition data.

## Release refinements — October 20

- **Settings update the view immediately.** The checked state of Show AMS, progress and other readings matches their visibility. Preference persistence, live card refresh and checkbox marks have been corrected.
- **More readable controls.** Stronger field/hint contrast, shared menus, selectors and scrolling, vector icons, and retained styles when settings open inside the main window.
- **Rounded edge dock.** Transparency is preserved outside its silhouette; a closed dock no longer tries to reopen after printer settings change.
- **Compact and expanded Spoolbase.** Remaining grams, locations of opened rolls, responsive columns and TXT/CSV stock export.
- **Printer colour takes priority.** A valid loaded AMS/EXT colour takes precedence over Spoolbase's fallback colour. A mismatch calls for checking the assigned physical roll; it does not automatically rewrite its definition or price.
- **Farm is optional and off by default.** Enable it in Settings → General. Hiding the module retains files, queue and orders; statistics and Spoolbase remain separate.
- **Fleet chart.** The fill closes to a horizontal baseline rather than diagonally between its first and last points. It does not increase tile height or obscure More.
- **History and exports.** Correct dialog ownership when opened from embedded panels, initial scroll at the start of history and the visible owner for report saving.
- **Per-printer camera correction.** Rotation by 0/90/180/270° and horizontal/vertical flips, in addition to orientation from Moonraker.
- **PL/EN installer and MIT.** The Windows installer offers language selection, installation notes and complete licence terms. Publisher: `/parametryczny`. Gantry remains MIT-licensed.

Windows fixes passed 473 UI checks across Basic/Modern, light/dark and PL/EN, plus installation, autostart and uninstall-with-data-retention tests. These ran under Wine; they do not certify every physical computer or guarantee device compatibility.

## Appearance and everyday use

**Printer settings** appears above application Settings. Select a printer at the top to configure connection details, EXT and strip visibility, camera, custom lighting commands, socket, power and machine wear. The form keeps separate drafts for each printer. In menu-bar or tray mode, open it directly from the application menu. Pinning the full window preserves its position on the current display.

- Edge dock settings: compact printer and camera selection chips replace vertical lists; a new screen preview provides six position anchors, a readable caption and keyboard access.

Settings use a shared type scale: headings 14, labels and options 13, descriptions 12. Longer option names wrap to complete lines. Spacing and description widths are consistent; crowded camera-limit and Vision model rows have been separated.

Choose Gantry Basic or Gantry Modern in **Settings → Appearance**. Modern presents the printer name and connection type, state, file, progress, remaining time, finish time, layers, temperatures and filament in a compact layout. Available readings and their visibility depend on the printer and card settings.

Farm, Monitoring, Diagnostics, Spoolbase, Statistics and other views share Gantry's header style. Window mode removes unnecessary nested window frames. Control receives more consistent headings, buttons and spacing. Statistics places the file list beside the summary when space permits; narrower windows stack the content.

Separate pause and light shortcuts have been removed from the main Modern cards to leave more room for printer status. Controls remain available in their dedicated panel.

Header icon spacing and first-click handling have been refined: buttons respond even when the window was inactive. **Settings → Windows & strip** adds **“Expand the strip only after clicking.”** Hover expansion remains the default; a pinned strip stays expanded.

The application header's light button can send **lights on or off** to all connected printers with a supported lighting command or configured custom LED command. Fleet lighting is also available on the hosted dashboard when remote control is enabled; the read-only LAN dashboard does not send commands.

Fixes include opening history at the start, populating the Edit printer form, keeping the last card row visible—including MINI and fleet statistics—and correcting the fleet chart's size and fill. An idle printer now shows **“Waiting for print.”**

## Printer tools and photo notifications

- Per-printer external HTTP/HTTPS JPEG or MJPEG camera for any brand, shared by details, monitoring, edge strip and existing web access.
- Notification photos with a per-printer switch; Vision attaches the alarm frame. Presentation follows desktop notification settings.
- Web-panel shortcut and a manual GET/POST button with optional JSON and Bearer token in access-key storage. Saving does not execute it.
- Alternate API origin and separate printing/idle polling intervals for PrusaLink, Moonraker and OctoPrint. Controls and file transfers share the selected endpoint; commands are not automatically replayed at another address.
- Configuration guide: [Printer settings and tools](https://github.com/parametryczny/Gantrybar/wiki/Printer-tools-EN).

## AMS / Filaments and hiding EXT

Gantry gains a dedicated **AMS / Filaments** view in the Gantry menu and sidebar. Select a printer to see its modules and colour tiles. Slots show material, remaining percentage and grams when available; an arrow marks the printing slot. Module temperature and humidity appear when reported by the printer.

Clicking a slot opens colour, remaining-quantity and roll-assignment details. With Spoolbase enabled, assign or change a roll directly from this view. The layout adapts its columns to the available width and displays reported AMS/HT modules and external sources.

**EXT can be hidden per printer** in Edit printer, Details → Filaments / AMS, or the EXT switch in the new view. The preference applies to all external sources on that printer and is also respected by both the LAN and hosted web dashboards. Hiding changes presentation while preserving physical slot indices, assignments and filament consumption.

## Farm: file → printers → materials

The farm folder gets **X2D, X1, P1, P2, MINI and A1** subfolders. The library displays files as a refreshable list. Removing a library entry can also move its recorded original to the system trash; this operation refuses files used by active jobs or the queue.

Selecting a file shows its preview, plate, time, materials and printer compatibility. **Match AMS** proposes compatible slots; sources can also be selected manually. **Check selection** reports missing material, insufficient filament, nozzle mismatches and bed preparation before starting.

Material mapping and plate selection are concentrated in the workspace rather than expanded inside each printer card. Up to six printers use a compact 2 × 3 grid; a small window may still require scrolling. Refreshing AMS preserves selections and assignments that are still available.

The Farm supports sliced 3MF for Bambu Lab and G-code for supported Klipper, PrusaLink and OctoPrint printers. Tool-order changes are applied to a working copy of text G-code. The original is preserved; BG-code and checksummed files requiring such changes must be exported again.

**Uploading alone does not start a print.** A separate start requires confirmation. The queue may start a copy after you explicitly allow a prepared printer to take it.

### Farm: preparation, production and quality

- New layout with a compact file list, printers in the middle and a separate materials inspector. Six printers fit without scrolling at the standard wide window size.
- File search in the app and web panel, combining multiple words, case and Polish diacritic handling with the folder filter.
- Separate preparation, queue, pickup/quality, orders and history views.
- Batch plans account for queued workload and filament reservations. Adding a batch does not start printing; empty-bed approval permits one start.
- Separate pickup and quality confirmations; a rejected copy creates a held reprint with its recorded reason.
- Manual orders with SKU, sliced file, plate, quantity and deadline; fulfilment counts accepted copies and avoids duplicate planning. WooCommerce and Etsy remain planned integrations.
- Compact production history with CSV export; materials inspectors respect hidden EXT spools.

## Energy, costs and history

Tasmota and supported Shelly sockets with power metering are polled approximately every **5 seconds**. A cycle includes preparation reported as an active job, printing and pauses, through completion or interruption.

Reports distinguish:

| Energy source | Meaning |
| --- | --- |
| Measured | energy calculated from socket readings |
| Partial measurement | measured intervals plus an estimate for missing time |
| Estimated | a result based on the printer's configured average wattage |

Computer sleep, closing the app or missing readings leave a gap instead of inventing a measurement. Missing filament usage is shown as unknown, not as 0 g.

Individual TXT reports and CSV history include duration, filament, energy, measurement source and cost breakdowns. These are job-data reports, **not downloads of the original 3MF/G-code**. The Files and prints list uses rows instead of separate cards. A download icon beside the name saves that job’s report, and the history window also offers a full export. Wide windows keep cost and time summaries on the left and the print list on the right.

## Spoolbase

Order import recognises material, product, colour, quantity, weight and price. Review the items and the **price per roll** before adding them. Image recognition runs locally through OCR; recognised items can be edited before saving.

The editor's palette suggests colours from the brand catalogue. Slicer profiles can be read on request to suggest product-series names; they do not replace the colour catalogue.

**62 × 37 mm** labels contain a QR code identifying a filament definition in your inventory. Labels can be printed or saved as PDF. The label code is not a printer access code.

Manually assigned rolls are no longer returned to stock merely because the printer reports no material for that slot. Removal detection first needs to have seen filament under that assignment, followed by a sustained empty-slot reading. Hidden EXT sources do not shift AMS/HT assignments.

Spool accounting no longer deducts both the AMS remaining-quantity update and slicer grams from the same balance. A recognised roll with a valid AMS quantity retains its balance source across restarts; slicer usage still enters history and cost reports. Rolls without such readings use normal subtraction. An AMS reading of 0 g now marks the roll empty. Gantry automatically assigns exactly one matching untagged roll; multiple candidates require manual selection. If AMS readings stop, the last known quantity is retained.

## Web access on a phone and your own server

A generic web ZIP is not attached to the release. Generate your own website package in Gantry, with your hosting address and configuration.

Desktop uses side navigation; phones use bottom navigation with vertically stacked printer cards. Viewing also includes monitoring and, when sharing is enabled, the Farm, history, costs, Spoolbase and maintenance.

**Generate website package…** prepares a ZIP with the current dashboard, hosting address, bridge key and password hash. The key is not included in JavaScript. Generating the ZIP neither enables synchronisation nor publishes the site.

After uploading the files to PHP hosting with HTTPS, enable the bridge in Gantry. The app initiates the connection to hosting, so this mode needs no router port forwarding. The local dashboard and own-hosting bridge are distinct access methods.

Form login and redirection from the older `api.php?action=login` address have been fixed; that flow could previously end on the “Please log in” JSON response. The session is saved before redirecting to the dashboard.

**“Remember me for 30 days”** retains login in that browser. Without it, the session has a 12-hour limit. Logging out or changing the password invalidates access. A phone home-screen shortcut may have its own cookie storage and need a separate first login; the same remembered-session mechanism then applies.

The browser still shows the domain in its address bar. “Gantry” is the page or shortcut name and does not replace Safari’s address display. Website changes require updating the hosted files; updating the desktop app alone does not replace a remote installation.

## Gantry Vision and monitoring

Dark-camera notices apply only during active printing after layers begin. They clear on pause, completion, interruption, job change or visibility recovery without removing unrelated warnings.

Monitoring gains an adaptive camera grid. Details, monitoring and the edge strip share the same printer feed, so opening another view does not take the picture away from existing viewers. Closing a view releases its own camera viewers.

Optional frame-rate limiting for larger fleets reduces camera-wall overhead. The limit applies to Monitoring; Details and the strip keep their normal preview. H.264 feeds receive special handling for keyframes.

**Gantry Vision Fast** is the bundled default model, with `ok`, `spaghetti` and `detached` classes. A different compatible model file can be selected. Its displayed name and recommended sensitivity threshold come from metadata. The detached class also uses synthetic examples; performance on real failures needs further validation.

Vision supports manual frame labelling, observation archives, responses to alarms and ZIP export. A user-confirmed defect can create a service problem with its photo; a model alarm alone does not create a report.

The archive can keep first-layer, 25%, 50%, 75% and closing images. The closing image uses the latest available frame. A manual label remains separate from a prediction; saving or exporting data does not automatically retrain network weights.

Local weight trials, including the Infill variant intended to reduce warnings on regular infill, are separate experiments. They are not a universal accuracy result and do not automatically replace installer models. Model choice, sensitivity and automatic pausing remain user settings.

Bambu file-tunnel replies on a port being tried as a camera are now recognised instead of treated as a valid image stream. This case receives an appropriate diagnostic rather than waiting for a frame that will never arrive.

Gantry now respects 0°/90°/180°/270° rotation and horizontal/vertical flips from Moonraker webcam configuration. Orientation is applied before the frame is shared with other previews and still-image consumers, including web viewing and camera-based tools. This fixes ignored configuration that could show printers such as Artillery upside down; without configured metadata, the app does not guess rotation by brand.

Fixed double normalization of Vision model input. Metadata `input.normalization: embedded` selects RGB / 255; older custom models retain ImageNet normalization unless specified otherwise. Updating does not silently replace a user-selected model.

## Maintenance & service — new desktop workspace

Open the fleet workspace from **Gantry → Maintenance & service…**, the sidebar or a printer card’s maintenance indicator. Its summary shows due tasks, printers in service, open problems and low-stock parts. Printer selection, search and a needs-attention filter help locate the relevant machine.

- **In-service status.** Farm excludes the printer and blocks new uploads, copy assignments and starts. Entering service disarms previously allowed queue starts; leaving service does not re-arm them. An existing print continues unchanged.
- **Custom tasks and checklists.** A title, steps, progress, and one-off or recurring work. Completing a task requires all steps to be checked. Tasks can be edited, archived and restored.
- **Templates.** Save a checklist and intervals for reuse; assign a new task to all printers at once if needed.
- **Hour-based and calendar schedules.** Set print hours, days or both—the earlier deadline applies. Completion starts the next cycle. Existing tasks retain seven-day reminder snoozing.
- **Problem register.** A title, note, priority, photo and open / in-progress / resolved status. A user-confirmed Vision defect can create a problem with its photo; a model prediction alone does not create a report.
- **Detailed history.** Date, operating hours, notes, completed checklist, consumed part and cost. Old and new entries share one chronological history.
- **Spare-parts inventory.** Quantity, minimum stock and unit price. Completion supports one selected inventory item with a quantity, plus additional costs. History and stock consumption are saved together; insufficient stock blocks completion. Later price changes do not recalculate historical costs.

The workspace adapts to its window: tasks and history sit side by side at wider sizes and stack at narrower sizes. Service data and photos stay local; existing counters and history are preserved.

The service workspace is part of full Gantry. The web dashboard considers service status when displaying Farm compatibility; task, problem and parts forms are opened in the app.

## LITE mode

The LITE switch in **Settings → Advanced** enables a simplified mode with printer status in the menu bar or system tray. Details, control, statistics, pricing, Farm, the standalone AMS module, Spoolbase, service, cameras and full-edition integrations are hidden. Settings retain basic options and the way back to full mode. Changing mode restarts the app.

Saved printers, history and inventory are preserved. The switch in the full app does not reduce its file size; a separate LITE installer is a reduced build and requires installing the full app to regain its tools.

## Updating the app and website

When updating your hosting, preserve the existing `config.php` and `data/`, and update website files together. A new key or password from a newly generated package changes the website configuration. Preserving existing data does not enable new sharing scopes.

📚 [Wiki / guides](https://github.com/parametryczny/Gantrybar/wiki) · ☕ [Support Gantry](https://buycoffee.to/parametryczny)

## Experimental SLA and Fiberpunk monitoring

Local LAN/Wi-Fi monitoring for Elegoo Saturn 4 Ultra 12K/16K, Mars 5 Ultra, Anycubic Photon Mono X 6K and Prusa SL1/SL1S SPEED. A separate Fiberpunk Node/Node Pro monitor reads the adapter’s local API. State, progress, job, layers and remaining time are displayed when reported by the device. No controls, Farm, uploads or SLA spaghetti detection. Parsers and simulated connections have been tested; physical printer compatibility still needs validation. See [SLA monitoring](wiki/SLA-monitoring-EN.md).

Extended monitoring: Saturn 3 Ultra / Mars 4 Ultra via UDP, Photon P1 / P1 Max via local MQTT, and Formlabs via PreForm Server. Phrozen can be monitored through a compatible OctoPrint/Chituboard bridge; direct Mighty 8K support remains unverified. Formlabs shows its actual status and available remaining time without an invented percentage.

The compact printer list now follows Obsidian: one header per expanded printer, clear expand/collapse arrows, consistent surfaces and aligned cards.

Add printer: wrapping tile buttons select the printer type. Edit and advanced actions open the selected printer’s full settings from the top bar as well; connection credentials keep a separate form. Per-printer camera correction supports 0/90/180/270° rotation and horizontal/vertical flips after Moonraker orientation. Previews and snapshots share the correction; the Vision detection area follows rotation.

### Consistent Obsidian forms

- Shared buttons, text fields, control heights and typography across settings, automations, smart socket configuration, filament editing and supporting Vision dialogs.
- Settings follow the selected template palette, including auxiliary windows and forms.
- More readable long descriptions and labels. The filament catalogue separates spool values and actions into rows instead of squeezing every control into one line.
- Native secure fields, editing, number formatters, keyboard shortcuts and Basic appearance are preserved. OS file pickers and confirmation dialogs remain native.
