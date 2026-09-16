"""Gantry Workshop (the full-screen kiosk) is a mode of the regular app: the app opens by default, a
button in Settings switches to the kiosk, and the kiosk can always switch back or close (Linux Mint
feedback, 2026-09-16)."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from gantry import workshop

PACKAGING = Path(__file__).resolve().parents[1] / "packaging"


class WorkshopSwitchTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        patch = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.folder.name})
        patch.start(); self.addCleanup(patch.stop)
        self.autostart = Path(self.folder.name) / "autostart"
        self.popen = mock.patch.object(workshop.subprocess, "Popen").start()
        self.addCleanup(mock.patch.stopall)

    def test_kiosk_autostart_file_follows_xdg_config_home(self):
        self.assertEqual(workshop.kiosk_autostart_file(), self.autostart / "gantry-kiosk.desktop")

    def test_commands_prefer_installed_launchers(self):
        with mock.patch.object(workshop.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"):
            self.assertEqual(workshop.kiosk_command(), ["/usr/bin/gantry-kiosk"])
            self.assertEqual(workshop.desktop_app_command(), ["/usr/bin/gantry"])
        with mock.patch.object(workshop.shutil, "which", return_value=None):
            self.assertIsNone(workshop.kiosk_command())  # AppImage: no switch offered
            self.assertEqual(workshop.desktop_app_command(), [sys.executable, "-m", "gantry"])

    def test_entering_moves_login_start_to_the_kiosk(self):
        workshop.set_autostart(True)
        with mock.patch.object(workshop, "kiosk_command", return_value=["gantry-kiosk"]):
            workshop.enter_workshop()
        self.assertEqual(self.popen.call_args.args[0], ["gantry-kiosk"])
        self.assertTrue(self.popen.call_args.kwargs["start_new_session"])
        self.assertFalse(workshop.autostart_enabled())
        entry = workshop.kiosk_autostart_file().read_text(encoding="utf-8")
        self.assertIn("Exec=gantry-kiosk", entry)
        self.assertNotIn("NoDisplay", entry)

    def test_entering_without_login_start_adds_none(self):
        with mock.patch.object(workshop, "kiosk_command", return_value=["gantry-kiosk"]):
            workshop.enter_workshop()
        self.assertFalse(workshop.kiosk_autostart_file().exists())
        self.assertFalse(workshop.autostart_enabled())

    def test_entering_fails_cleanly_without_the_kiosk_launcher(self):
        workshop.set_autostart(True)
        with mock.patch.object(workshop, "kiosk_command", return_value=None):
            with self.assertRaises(OSError):
                workshop.enter_workshop()
        self.popen.assert_not_called()
        self.assertTrue(workshop.autostart_enabled())

    def test_leaving_moves_login_start_back_to_the_app(self):
        entry = workshop.kiosk_autostart_file()
        entry.parent.mkdir(parents=True)
        entry.write_text(workshop.KIOSK_AUTOSTART, encoding="utf-8")
        with mock.patch.object(workshop, "desktop_app_command", return_value=["gantry"]):
            workshop.leave_workshop()
        self.assertEqual(self.popen.call_args.args[0], ["gantry"])
        self.assertFalse(entry.exists())
        self.assertTrue(workshop.autostart_enabled())

    def test_leaving_keeps_login_start_off_when_the_kiosk_had_none(self):
        workshop.leave_workshop()
        self.assertFalse(workshop.autostart_enabled())

    def test_a_failed_start_changes_nothing(self):
        entry = workshop.kiosk_autostart_file()
        entry.parent.mkdir(parents=True)
        entry.write_text(workshop.KIOSK_AUTOSTART, encoding="utf-8")
        self.popen.side_effect = FileNotFoundError("gantry")
        with self.assertRaises(OSError):
            workshop.leave_workshop()
        self.assertTrue(entry.exists())
        self.assertFalse(workshop.autostart_enabled())


class KioskWindowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from gantry import kiosk
            from gi.repository import Gdk
        except Exception as error:  # pragma: no cover - GTK bindings missing on this host
            raise unittest.SkipTest(f"gantry.kiosk needs the GTK bindings: {error}")
        cls.kiosk, cls.Gdk = kiosk, Gdk

    def test_ctrl_q_quits_with_or_without_caps_lock(self):
        Gdk, control = self.Gdk, self.Gdk.ModifierType.CONTROL_MASK
        self.assertTrue(self.kiosk.is_quit_shortcut(Gdk.KEY_q, control))
        self.assertTrue(self.kiosk.is_quit_shortcut(Gdk.KEY_Q, control | Gdk.ModifierType.LOCK_MASK))
        self.assertFalse(self.kiosk.is_quit_shortcut(Gdk.KEY_q, 0))
        self.assertFalse(self.kiosk.is_quit_shortcut(Gdk.KEY_w, control))

    def test_switch_back_quits_the_kiosk_only_when_the_app_started(self):
        app = self.kiosk.KioskGantry.__new__(self.kiosk.KioskGantry)
        app.quit, app._message, app.window = mock.Mock(), mock.Mock(), mock.Mock()
        with mock.patch.object(self.kiosk.workshop, "leave_workshop"):
            app.switch_to_desktop_app()
        app.quit.assert_called_once()
        app.quit.reset_mock()
        with mock.patch.object(self.kiosk.workshop, "leave_workshop", side_effect=FileNotFoundError("gantry")):
            app.switch_to_desktop_app()
        app._message.assert_called_once()
        app.quit.assert_not_called()


class KioskLauncherTests(unittest.TestCase):
    def test_menu_entry_is_hidden_on_desktops(self):
        entry = (PACKAGING / "gantry-kiosk.desktop").read_text(encoding="utf-8")
        self.assertIn("\nNoDisplay=true\n", entry)

    def test_setup_script_autostart_copy_drops_the_hidden_flag(self):
        entry = PACKAGING / "gantry-kiosk.desktop"
        setup = (PACKAGING / "gantry-kiosk-setup").read_text(encoding="utf-8")
        self.assertIn("sed '/^NoDisplay=/d' /usr/share/applications/gantry-kiosk.desktop", setup)
        copied = subprocess.run(["sed", "/^NoDisplay=/d", str(entry)], capture_output=True, text=True,
                                check=True).stdout
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
