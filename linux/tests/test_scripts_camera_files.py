"""Scripts that honour their interpreter and can be stopped, the P1/A1 camera protocol, the shared 3MF path
fixture and colour matching between rolls (audit 2026-09-14: A09, A10, A13, A14)."""
import json
import os
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

from gantry.automation import AutomationEngine, start_script
from gantry.consumption import bambu_charges, candidate_paths
from gantry.core import FilamentGroup, FilamentSlot
from gantry.jpegstream import BAMBU_JPEG_PORT, bambu_auth_packet, bambu_jpeg_frames

FIXTURE = Path(__file__).resolve().parents[2] / "design" / "fixtures" / "bambu-3mf-candidates.json"


def _wait(condition, seconds=5.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


class ScriptTests(unittest.TestCase):
    def test_a_shebang_picks_the_interpreter(self):
        process, temporary = start_script("#!/usr/bin/env python3\nimport sys\nsys.exit(3)\n")
        self.assertEqual(process.wait(timeout=10), 3)
        self.assertIsNotNone(temporary)
        os.unlink(temporary)
        process, temporary = start_script("exit 4")
        self.assertEqual(process.wait(timeout=10), 4)
        self.assertIsNone(temporary)

    def _engine(self):
        notes = []
        app = SimpleNamespace(config=SimpleNamespace(data={"automations": {}}), language="en",
                              notify=lambda title, body: notes.append(body), printers=[])
        return AutomationEngine(app), notes

    def test_a_failing_script_says_so(self):
        engine, notes = self._engine()
        engine._run_script("Printer", {"id": "r1", "name": "Cleanup"}, "exit 5")
        self.assertTrue(_wait(lambda: any("5" in note for note in notes[1:])), notes)

    def test_a_replaced_run_does_not_unregister_its_replacement_and_stop_is_silent(self):
        engine, notes = self._engine()
        # The first run ignores the stop signal and ends a second later, so its end always arrives after
        # the run that replaced it is registered: the case where it used to remove the wrong entry.
        engine._run_script("Printer", {"id": "r1", "name": "Watch"}, "trap '' TERM; sleep 1")
        time.sleep(0.2)
        engine._run_script("Printer", {"id": "r1", "name": "Watch"}, "sleep 5")
        time.sleep(1.6)
        self.assertTrue(engine.is_script_running("r1"))
        engine.stop_script("r1")
        self.assertFalse(engine.is_script_running("r1"))
        time.sleep(0.5)
        self.assertFalse(any("failed" in note for note in notes), notes)


class BambuJpegCameraTests(unittest.TestCase):
    def test_the_login_packet(self):
        packet = bambu_auth_packet("12345678")
        self.assertEqual(len(packet), 80)
        self.assertEqual(packet[0], 0x40)
        self.assertEqual(packet[4:6], b"\x00\x30")
        self.assertEqual(packet[16:20], b"bblp")
        self.assertEqual(packet[48:56], b"12345678")

    def test_frames_are_cut_out_of_the_stream(self):
        chunks = [b"junk\xff\xd8one\xff\xd9\xff\xd8tw", b"o\xff\xd9", b""]

        class Stream:
            sent = b""
            def sendall(self, data): Stream.sent += data
            def recv(self, size): return chunks.pop(0)
            def close(self): pass

        seen = {}
        def connect(host, port, timeout):
            seen["port"] = port
            return Stream()

        frames = []
        self.assertTrue(bambu_jpeg_frames("10.0.0.5", "12345678", threading.Event(), frames.append, connect=connect))
        self.assertEqual(frames, [b"\xff\xd8one\xff\xd9", b"\xff\xd8two\xff\xd9"])
        self.assertEqual(seen["port"], BAMBU_JPEG_PORT)
        self.assertEqual(Stream.sent, bambu_auth_packet("12345678"))


class PathFixtureTests(unittest.TestCase):
    def test_candidate_paths_match_the_shared_fixture(self):
        cases = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.assertTrue(cases)
        for case in cases:
            self.assertEqual(candidate_paths(case["file"]), case["paths"], case["file"])


def _group(slots):
    return FilamentGroup(group_id="ams", source_type="ams", display_name="AMS", declared_capacity=len(slots),
                         external=False, slots=slots)


class ColourMatchingTests(unittest.TestCase):
    def test_two_rolls_of_one_colour_are_told_apart_by_material(self):
        groups = [_group([FilamentSlot(slot_id="a1", label="A1", material="PLA", color="000000FF"),
                          FilamentSlot(slot_id="a2", label="A2", material="PETG", color="000000FF")])]
        filaments = [{"id": 1, "used_g": 4.0, "color": "000000", "type": "PETG"},
                     {"id": 2, "used_g": 2.0, "color": "000000", "type": "PLA"}]
        charges = bambu_charges("X1", groups, filaments, {(0, 0): "SP-PLA", (0, 1): "SP-PETG"})
        self.assertEqual([charge[0] for charge in charges], ["SP-PETG", "SP-PLA"])

    def test_two_identical_rolls_are_not_charged_as_one(self):
        groups = [_group([FilamentSlot(slot_id="a1", label="A1", material="PLA", color="000000FF"),
                          FilamentSlot(slot_id="a2", label="A2", material="PLA", color="000000FF")])]
        filaments = [{"id": 1, "used_g": 4.0, "color": "000000", "type": "PLA"},
                     {"id": 2, "used_g": 3.0, "color": "FFFFFF", "type": "PLA"}]
        self.assertEqual(bambu_charges("X1", groups, filaments, {(0, 0): "SP-1", (0, 1): "SP-2"}), [])


if __name__ == "__main__":
    unittest.main()
