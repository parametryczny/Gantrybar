"""Gantry Workshop (the Raspberry Pi kiosk) must be possible to leave on a regular desktop, and must not
show up in desktop menus next to Gantry (Linux Mint feedback, 2026-09-16)."""
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from gantry import kiosk
    from gi.repository import Gdk
except Exception as error:  # pragma: no cover - GTK bindings missing on this host
    raise unittest.SkipTest(f"gantry.kiosk needs the GTK bindings: {error}")

PACKAGING = Path(__file__).resolve().parents[1] / "packaging"


class KioskQuitShortcutTests(unittest.TestCase):
    def test_ctrl_q_quits_with_or_without_caps_lock(self):
        control = Gdk.ModifierType.CONTROL_MASK
        self.assertTrue(kiosk.is_quit_shortcut(Gdk.KEY_q, control))
        self.assertTrue(kiosk.is_quit_shortcut(Gdk.KEY_Q, control | Gdk.ModifierType.LOCK_MASK))

    def test_plain_q_and_other_shortcuts_do_not_quit(self):
        self.assertFalse(kiosk.is_quit_shortcut(Gdk.KEY_q, 0))
        self.assertFalse(kiosk.is_quit_shortcut(Gdk.KEY_w, Gdk.ModifierType.CONTROL_MASK))


class KioskLauncherTests(unittest.TestCase):
    def test_menu_entry_is_hidden_on_desktops(self):
        entry = (PACKAGING / "gantry-kiosk.desktop").read_text(encoding="utf-8")
        self.assertIn("\nNoDisplay=true\n", entry)

    def test_autostart_copy_drops_the_hidden_flag(self):
        entry = PACKAGING / "gantry-kiosk.desktop"
        setup = (PACKAGING / "gantry-kiosk-setup").read_text(encoding="utf-8")
        self.assertIn("sed '/^NoDisplay=/d' /usr/share/applications/gantry-kiosk.desktop", setup)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "gantry-kiosk.desktop"
            with target.open("w", encoding="utf-8") as output:
                subprocess.run(["sed", "/^NoDisplay=/d", str(entry)], stdout=output, check=True)
            copied = target.read_text(encoding="utf-8")
        self.assertNotIn("NoDisplay", copied)
        self.assertIn("Exec=gantry-kiosk", copied)

    def test_wrapper_restores_screen_blanking_on_exit(self):
        wrapper = (PACKAGING / "gantry-kiosk").read_text(encoding="utf-8")
        self.assertNotIn("exec ", wrapper)  # exec would skip the restore trap
        self.assertIn("trap restore_screen EXIT", wrapper)
        self.assertIn("xset +dpms", wrapper)
        subprocess.run(["sh", "-n", str(PACKAGING / "gantry-kiosk")], check=True)
        subprocess.run(["sh", "-n", str(PACKAGING / "gantry-kiosk-setup")], check=True)


if __name__ == "__main__":
    unittest.main()
