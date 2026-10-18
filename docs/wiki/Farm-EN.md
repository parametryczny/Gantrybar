# Farm: from file to print

[Polski](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Farm-PL.md) · [Contents](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Prepare the library

1. Choose **Select folder…** in the Farm, for example `Downloads/farma`.
2. Gantry creates `X2D`, `X1`, `P1`, `P2`, `MINI` and `A1` subfolders.
3. Place files in the appropriate folder and **Refresh** the file list. Files in the root folder can remain unassigned to a family.
4. Select a file to view its plate, preview and slicer data in the middle column.

A folder does not change the sliced profile. Moving a 3MF into X2D does not automatically prepare it for X2D.

## Choose printers and materials

1. Select compatible printers.
2. Choose a plate and open the selected printer's material mapping.
3. Use **Match AMS** or choose a source for each material manually.
4. Check material, colour and remaining weight. Missing weight does not prove that a roll has enough filament.
5. Use **Check selection** and resolve reported issues.

Explicit AMS matching does not silently choose an external spool. Setting one printer's sources does not automatically configure every other printer.

## Upload, start and queue

**Send file** uploads the file; the transfer alone does not start printing. Start separately after confirming the bed and profile.

The queue is different: you allow a prepared printer to take one copy, then Gantry transfers a matching job and may start it. Confirm the empty bed again after removing the print.

| File | Destination |
| --- | --- |
| sliced 3MF | supported Bambu Lab printers |
| text G-code | supported Klipper, PrusaLink, OctoPrint printers |
| BG-code | supported PrusaLink; no text tool rewriting |

G-code remapping changes supported `T<n>`, `M104` and `M109` commands in a working copy. It is not a printer-profile converter. Re-export a checksummed file if tool changes are required.

## Remove a file and its original

Removal can move the recorded original to trash and remove its library entry. Active jobs, queued files or an original changed since import cause refusal. Older imports without a recorded source path need to be imported again first.

## Production workspace

Farm has five views: **Preparation**, **Queue**, **Pickup & quality**, **Orders** and **History**. Preparation places the searchable file list and folder filter on the left, printers in the middle, and the selected printer's materials on the right. Six printers fit in two columns without scrolling their list at the standard wide window size. Narrower windows stack sections.

File search updates immediately, combines multiple words and ignores case and Polish diacritics. It works together with the selected folder and is also available in the web panel.

**Add to queue** creates a batch plan and material reservations. Adding a batch neither uploads a file nor starts printing. The plan allocates copies to selected compatible printers and accounts for current workload and earlier reservations. Unknown spool weight stays unknown and requires a manual check. Reservations do not deduct Spoolbase stock. Gantry does not reslice files or assume compatibility with a different printer model.

In **Queue**, move, hold, resume or remove waiting batches. Explicit approval of an empty, prepared bed permits **one** start and is not retained after an application restart. Uploading a file separately still does not start printing. Held batches reserve material but do not have a reliable completion time.

After a print finishes:

1. Confirm removal of the print and an empty bed.
2. Accept its quality, or provide a reason for reprinting.
3. A rejected copy does not fulfil its order; its replacement enters the queue on hold. Neither pickup nor quality assessment permits another start automatically.

A manual order links a reference, SKU, sliced file, plate, quantity and optional deadline. **Quantity means copies of the plate, not individual objects on that plate.** Only accepted copies fulfil an order. Preparing remaining copies accounts for queued, running and uninspected production, preventing duplicate allocation. WooCommerce and Etsy are planned integrations; no live store connection is included.

Production history uses compact rows and exports job and quality data as CSV. “Slicer filament” is predicted consumption, not a measurement. Complete energy and cost reports remain in fleet statistics.
