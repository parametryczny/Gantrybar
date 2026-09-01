import json
import unittest

from gantry.anycubic import parse_anycubic_message
from gantry.core import PrinterState


class AnycubicProtocolTests(unittest.TestCase):
    def test_info_and_print_reports_merge(self):
        info = {"type": "info", "data": {"state": "printing", "temp": {
            "curr_nozzle_temp": 221.5, "target_nozzle_temp": 220,
            "curr_hotbed_temp": 61, "target_hotbed_temp": 60}, "project": {
            "filename": "gear.gcode", "progress": 42, "curr_layer": 21,
            "total_layers": 50, "remain_time": 30}}}
        tel = parse_anycubic_message(json.dumps(info))
        self.assertIsNotNone(tel)
        self.assertEqual(tel.state, PrinterState.PRINTING)
        self.assertEqual(tel.progress, 42)
        self.assertEqual(tel.remaining_minutes, 30)
        self.assertEqual(tel.nozzle, 221.5)
        self.assertEqual(tel.current_layer, 21)

        paused = parse_anycubic_message(json.dumps({"type": "print", "state": "paused",
            "data": {"filename": "gear.gcode", "progress": 45}}), tel)
        self.assertEqual(paused.state, PrinterState.PAUSED)
        self.assertEqual(paused.nozzle, 221.5)
        self.assertEqual(paused.current_layer, 21)
        self.assertEqual(paused.total_layers, 50)

    def test_ace_slots(self):
        payload = {"type": "multiColorBox", "data": {"multi_color_box": [{
            "temp": 31, "loaded_slot": 1, "slots": [
                {"index": 0, "status": 1, "type": "PLA", "color": [255, 0, 64]},
                {"index": 1, "status": 1, "type": "PETG", "color": [0, 120, 255]}]}]}}
        tel = parse_anycubic_message(json.dumps(payload))
        self.assertEqual(len(tel.filament_groups), 1)
        self.assertEqual(len(tel.filament_groups[0].slots), 4)
        self.assertEqual(tel.filament_groups[0].slots[1].material, "PETG")
        self.assertTrue(tel.filament_groups[0].slots[1].active)
        self.assertEqual(tel.filament_groups[0].slots[0].color, "FF0040FF")


if __name__ == "__main__": unittest.main()
