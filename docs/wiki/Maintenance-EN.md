# Fleet maintenance and service

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Maintenance-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

The module is available in full Gantry: Gantry menu → **Maintenance & service…**, the Maintenance sidebar item, or a printer card’s maintenance indicator. It is hidden in LITE mode. The new service forms are not exposed in the web dashboard.

- **In service** is a manual per-printer status. Farm excludes the printer and blocks new uploads, copy assignments and starts. Entering service disarms automatic queue starts; leaving service does not re-arm them. An existing print is not stopped.
- **Tasks and templates** support custom titles, checklists, one-off or recurring work, and optional assignment to all printers. Save a template when creating a task. Every checklist step must be checked before completing it. Archived tasks can be restored.
- **Schedules** accept print hours and/or calendar days; the earlier deadline applies. Completion resets both recurrence anchors. Existing hour-based tasks, history and seven-day snoozing remain available.
- **Problems** have a title, notes, priority, photo and open/in-progress/resolved status. A Vision warning creates a problem only after a person confirms the defect; model predictions alone do not create reports.
- **History** merges old and new entries chronologically. New entries can include notes, operating hours, a checklist, cost and consumed parts. Historical part names and prices remain unchanged when inventory is edited later.
- **Parts** track quantity, minimum stock and unit cost. Completion currently supports one selected inventory item and its quantity, plus an additional cost. Stock consumption and the history entry are saved together; insufficient stock blocks completion.

Wide layouts show tasks and history side by side; narrow layouts stack them. Use printer selection, search and the needs-attention filter to navigate the fleet. Open parts and templates from service management.

Service data is stored locally and separately from existing maintenance data and telemetry. Photos are copied to the local Gantry data directory. The module does not automatically relabel or retrain Vision, or upload photos.

## Counters and earlier data

Operating hours come from data observed by Gantry. An app that was closed or disconnected cannot reconstruct a printer’s complete lifetime history. Snoozing a reminder does not record maintenance completion.

Earlier maintenance history is preserved alongside new checklists, problems and parts. Web Farm compatibility considers service status, but the new service forms are not available there.
