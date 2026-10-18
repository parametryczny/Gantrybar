# Basic, Modern and LITE mode

[Polski](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Appearance-and-LITE-PL.md) · [Contents](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Basic or Modern?

Select the card template in **Settings → Appearance**. Basic keeps the familiar layout; Modern emphasises the file, progress, finish time and filament. Changing the template changes presentation, not printer data.

You can reduce cards to the readings you need. Web appearance follows the app by default; a browser-specific preference can override it.

## LITE mode inside the full app

Enable **LITE** in **Settings → Advanced**. Gantry restarts when the mode changes.

| Full mode | LITE |
| --- | --- |
| printer cards and details | status in the menu bar/tray |
| Farm, statistics, pricing and maintenance | tools hidden |
| Spoolbase, web and other full-edition integrations | unavailable in this mode |
| full preferences | basic preferences and a return to full mode |

LITE does not erase saved printers, history or inventory. Switching it off in the full app restores access. Running fewer features does not reduce the size of the same app binary.

A **standalone Gantry LITE package** is a different installation variant. Its switch cannot unlock the full edition; install the full app instead.

## Hide EXT

Open **Edit printer** and clear **Show external spool (EXT)**. The same option is in **Details → Filaments / AMS**.

This is per printer and affects all of its external sources. It does not disable feeding, delete rolls or change AMS/HT mapping.

## Edge dock, header and lighting

In **Settings → Windows & strip**, enable **Expand the strip only after clicking** to prevent accidental hover expansion. Hover remains the default. Pinning keeps the strip expanded.

Header icons have refined spacing and first-click handling in inactive windows. The header light button switches lighting on or off across connected printers with a supported LED command.

The new **AMS / Filaments** view also has an EXT switch. Hiding is respected in both the app and the web dashboard and does not shift AMS/HT roll assignments.

## Window, AMS and edge dock

Full desktop mode has a navigation rail with modules in the main content area. In AMS / Filaments, select a printer and colour slot to see its details or assign a roll. Windows and strip settings offer click-to-expand instead of hover expansion; pinned strips remain expanded. The header bulb controls lighting across supported connected printers.
