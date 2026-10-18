# Spoolbase: inventory, rolls and labels

[Polski](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Spoolbase-PL.md) · [Contents](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Two different records

| Item | Stores |
| --- | --- |
| filament definition | brand, series, material, colour and product code |
| physical roll | identity, weight, remaining filament, price and location of one spool |

Grams belong to the roll. When moving it to another printer, assign the same roll to the new slot instead of creating a duplicate.

## Add and assign

1. Open Spoolbase from Gantry's menu and choose **＋**.
2. Select a catalogue product or enter your own.
3. Enter roll count, weight and price where known.
4. Click a printer slot and assign the physical roll.

An RFID tag reading and an assigned inventory roll are not always the same measurement. Missing percentage or grams can mean no available reading. Unknown quantity should not become 0 g.

## Import an order

Choose **Import order…**, paste text or read an image, then recognise items. Review material, colour, quantity, weight and **price per roll** before adding. Recognition alone does not write inventory.

OCR runs locally and needs text-recognition dependencies. Order text can also be pasted manually. Do not automatically treat a line-total price as a per-spool price.

## Palettes and profiles

The editor's palette uses manufacturer catalogue colours, with a standard fallback for unknown brands. Picking a colour fills its name and hex value.

Reading a slicer's `profiles` folder on request suggests product-series names. It does not invent colours absent from those profiles or replace Gantry's catalogue.

## QR labels

Choose **Print label…** from the filament menu. The 62 × 37 mm label identifies a **filament definition**, not one physical roll. It contains no printer access code.

Labels can be printed or saved as PDF. Scanning a Gantry code opens the saved filament definition if it exists in your inventory.

If Spoolbase disappears from the menu, check **LITE** and the Spoolbase switch in **Settings → General**. Do not delete inventory.

## Dedicated AMS / Filaments view

Open **AMS / Filaments** from the Gantry menu or sidebar, select a printer and click a slot. Colour tiles show material, percentage and grams when available, with an arrow marking the active slot. Modules may also report temperature and humidity.

Slot details show the linked physical roll. With Spoolbase enabled, use **Assign spool…** or **Change assignment…**. The EXT switch hides that printer’s external sources in the web dashboard too.

A manually assigned roll with no reported material is not returned to stock merely because a reading is missing. Automatic removal detection requires first seeing filament under that assignment and then a sustained empty-slot reading.

## AMS balance and print accounting

Spool accounting no longer deducts both the AMS remaining-quantity update and slicer grams from the same balance. A recognised roll with a valid AMS quantity retains its balance source across restarts; slicer usage still enters history and cost reports. Rolls without such readings use normal subtraction. An AMS reading of 0 g now marks the roll empty. Gantry automatically assigns exactly one matching untagged roll; multiple candidates require manual selection. If AMS readings stop, the last known quantity is retained.
