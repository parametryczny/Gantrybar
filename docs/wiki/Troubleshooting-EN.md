# Troubleshooting

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Troubleshooting-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

Before changing configuration, record the Gantry version, operating system, view and reproduction steps. Exclude passwords, access codes, bridge keys and images you do not want to share.

## Missing Spoolbase, statistics or Details

Check **LITE** in Advanced. For Spoolbase alone, also check its General switch. A standalone LITE installer does not contain full-edition tools. “Version 0.12” alone does not tell us whether a menu item or its data is missing.

Do not delete inventory files as a first step. Say whether the menu entry is absent or the window opens empty.

## Missing filament percentage or grams

Check that the slot has a printer reading or an assigned Spoolbase roll. Not every filament or module reports remaining quantity. Unknown is different from an empty roll.

If only EXT is missing, check its switch in **Edit printer** or **Details → Filaments / AMS**.

## Empty chart or energy data

Check the selected period and available records. Power metering requires a socket reporting watts and Gantry running. An empty chart immediately after launch is not proof of a fault; readings are needed. A print already in progress may only have a partial measurement.

For a missing card or final row, report window size, Basic/Modern and printer count. Do not alter history data to fix layout.

## Farm refuses a file or start

Check that the file is sliced, the printer type, nozzle, selected plate and every material source. **Check selection** shows unmet conditions. Choosing a colour does not turn PLA into PETG or convert one printer's profile into another's.

## Web works on Wi-Fi but not outside it

A local computer address works only on a reachable network. Access outside Wi-Fi needs own hosting and an enabled bridge. Check [Web dashboard](https://github.com/parametryczny/Gantrybar/wiki/Web-dashboard-EN), synchronisation status and computer sleep.

A “Sign in” JSON response after login at `api.php?action=login` can indicate older login files. Replace the complete current website files, preserve configuration and data, then sign in again. Do not generate a new key as an arbitrary cache-clearing step.

## Camera or Vision does not work

Check the camera in Details, lighting, connection and model message. ONNX requires compatible `model.json` and runtime. A custom model file must use a format supported by your Gantry installation. Label a false alarm based on visible evidence rather than assigning a failure to an obscured frame.

## Include in a report

- operating system and Gantry version; full edition or standalone LITE;
- template and window size;
- printer type, view and selected period;
- exact message and reproduction steps;
- a screenshot with private information removed.

## Incorrect checkbox, contrast or dock appearance

Close the old process and install the current 0.14.0 asset; replace the whole folder for a ZIP update. Checked Filaments / AMS and Progress should show the readings immediately. The corrected Windows build is identified as `windows.20261020-r3` in About. If a problem remains, include version, theme, template and display scale; do not delete history or stock.
