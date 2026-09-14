"""Telegram bot replies on Linux, in both languages (audit 2026-09-14: A23).

Several replies passed a Polish and an English text to a lookup that takes one, so /help, /status,
/spools, /mute, /watch, the photo request and the stop confirmation raised TypeError and ended the
poll thread. Others were Polish whatever the language setting."""
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

try:
    from gantry import telegram
except Exception as error:  # pragma: no cover - GLib bindings missing on this host
    raise unittest.SkipTest(f"gantry.telegram needs the GLib bindings: {error}")

from gantry import i18n
from gantry.core import Printer, PrinterKind, PrinterState, Telemetry


class TelegramRepliesTests(unittest.TestCase):
    def setUp(self):
        self.sent = []

        def post(token, method, params, timeout=20):
            self.sent.append(params.get("text", ""))
            return {"ok": True}

        patcher = mock.patch.object(telegram, "_post", side_effect=post)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(i18n.set_language, "en")
        printing = Telemetry(state=PrinterState.PRINTING, progress=42, current_layer=3, total_layers=10,
                             nozzle=210.0, nozzle_target=215.0, bed=60.0, bed_target=60.0, chamber=31.0,
                             job_name="benchy")
        app = SimpleNamespace(printers=[Printer("X1", "Bench", "10.0.0.5", kind=PrinterKind.BAMBU)],
                              telemetry={"X1": printing},
                              config=SimpleNamespace(data={"telegram-bot-token": "token", "telegram-chat-id": "1"},
                                                     save=lambda: None))
        self.bot = telegram.TelegramBot(app)
        self.bot._control = lambda serial, action: None

    def replies(self, language: str) -> str:
        i18n.set_language(language)
        self.sent.clear()
        bot = self.bot
        bot._send_help()
        bot._send_spools()
        self.sent.append(bot._status_text("X1"))
        bot._handle_mute("2h")
        with mock.patch.object(telegram.threading, "Thread"):
            bot._handle_watch("10m")
        with mock.patch.dict(sys.modules, {"gantry.snapshot": SimpleNamespace(capture=lambda app, serial: None)}):
            bot._handle_photo("X1")
        bot._run_action("stopask", "X1", "cb", 7)
        with mock.patch.object(telegram.time, "sleep"):
            bot._run_action("lighton", "X1", "cb", 7)
        bot._handle({"callback_query": {"id": "cb", "message": {"chat": {"id": "999"}}}})
        return "\n".join(self.sent)

    def test_english_replies(self):
        text = self.replies("en")
        for expected in ("Gantry — commands:", "No spools running low", "Progress: 42%", "layer 3/10",
                         "Nozzle 210°/215°", "bed 60°/60°", "chamber 31°", "Alerts muted until",
                         "photos of printing machines every 10m", "Grabbing a camera snapshot from Bench",
                         "Cancel the print on Bench?", "💡 Light on", "Access denied"):
            self.assertIn(expected, text)

    def test_polish_replies(self):
        text = self.replies("pl")
        for expected in ("Gantry — komendy:", "Żadna rolka", "Postęp: 42%", "warstwa 3/10", "Dysza 210°/215°",
                         "stół 60°/60°", "komora 31°", "Alerty wyciszone do", "zdjęcia drukujących drukarek co 10m",
                         "Robię zdjęcie z kamery Bench", "Zatrzymać wydruk na Bench?", "💡 Włączono", "Brak dostępu"):
            self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
