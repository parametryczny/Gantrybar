# Energy, costs and print exports

[Polski](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Energy-and-reports-PL.md) · [Contents](https://github.com/parametryczny/Gantrybar/blob/main/docs/wiki/Home.md)

## Enable background metering

1. Assign a power-metering socket to the printer: supported Tasmota or Shelly.
2. Check that Gantry reads watts. Switching a socket does not imply power-metering support.
3. Set the electricity price per kWh and other costs in **Settings → Pricing**.
4. Keep Gantry running during the print cycle. Details need not remain open.

Readings occur about every 5 seconds. Energy is integrated from power samples and their time intervals, not taken as the difference between the socket's cumulative counters. Pauses and preparation reported as an active job are included.

## Read the result

| Result | Interpretation |
| --- | --- |
| measured | readings cover the cycle to the required extent |
| partial measurement | measured intervals plus an estimate for missing time |
| estimated | calculated from the configured average wattage |

Gaps longer than 30 seconds are not connected as measured intervals. A restart or joining a print midway produces a partial result. A sleeping computer records no readings; earlier gaps are not recovered.

Check the history energy column and its source description. Double-click a metered entry to view its saved trace where available.

## Export data

- Use the download icon beside a print in statistics for its TXT report.
- Use history CSV export for a list of prints.
- Reports include job name, printer, result, duration, filament, energy and costs where available.

A report contains neither original geometry nor G-code toolpaths. Unknown filament usage is not 0 g, and estimated selling prices depend on the pricing parameters you entered.

In CSV, `kWh` is the total result, `meter_kWh` the measured part, `energy_source` its origin and `meter_coverage` the coverage. These distinguish measurements from estimates outside the app.
