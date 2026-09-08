"""Which edition this install is.

LITE is the same code with the extras switched off: tray icon, printers, notifications and a short
settings dialog, and nothing else. Spoolbase, the detail window, maintenance, automations,
diagnostics, fleet statistics, Telegram, the LAN web dashboard, the floating window and the edge dock
belong to the full edition only.

The LITE package is built by rewriting ``EDITION`` below to ``"lite"`` (see
``linux/scripts/build-deb.sh``, which does it on the copy it installs — the source tree stays full).
``GANTRY_EDITION=lite`` in the environment does the same thing for a quick local run.
"""

from __future__ import annotations

import os

# Rewritten to "lite" when packaging Gantry LITE. Keep the literal on one line: the build script
# replaces exactly this assignment.
EDITION = "full"

IS_LITE = (os.environ.get("GANTRY_EDITION") or EDITION).strip().lower() == "lite"
HAS_EXTRAS = not IS_LITE
APP_NAME = "Gantry LITE" if IS_LITE else "Gantry"
