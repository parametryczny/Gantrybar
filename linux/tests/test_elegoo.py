import json
import unittest

from gantry.core import PrinterKind, PrinterState, Telemetry
from gantry.discovery import parse_elegoo_discovery
from gantry.elegoo import apply_canvas, deep_merge, parse_cc1_message, parse_cc2_status


class ElegooProtocolTests(unittest.TestCase):
    def test_cc2_discovery(self):
        payload = json.dumps({"id": 0, "result": {"host_name": "Warsztat", "machine_model":
            "Centauri Carbon 2", "sn": "CC2-123", "token_status": 1, "lan_status": 1}}).encode()
        printer = parse_elegoo_discovery(payload, "192.168.1.8", PrinterKind.ELEGOO_CC2)
        self.assertIsNotNone(printer)
        self.assertEqual(printer.serial, "CC2-123")
        self.assertEqual(printer.port, 1883)

    def test_cc2_delta_merge_and_telemetry(self):
        full = {"machine_status": {"status": 2, "sub_status": 2075, "progress": 45},
                "print_status": {"filename": "benchy.gcode", "current_layer": 10,
                                 "total_layer": 100, "remaining_time_sec": 600},
                "extruder": {"temperature": 215, "target": 220},
                "heater_bed": {"temperature": 58, "target": 60},
                "fans": {"fan": {"speed": 255}}, "gcode_move_inf": {"speed_mode": 2}}
        merged = deep_merge(full, {"machine_status": {"progress": 46},
                                   "extruder": {"temperature": 219.5}})
        tel = parse_cc2_status(merged)
        self.assertEqual(tel.state, PrinterState.PRINTING)
        self.assertEqual(tel.progress, 46)
        self.assertEqual(tel.nozzle_target, 220)
        self.assertEqual(tel.part_fan, 100)
        self.assertEqual(tel.speed_percent, 150)

    def test_canvas_does_not_invent_remaining_amount(self):
        result = {"canvas_info": {"active_canvas_id": 0, "active_tray_id": 1,
            "canvas_list": [{"canvas_id": 0, "connected": 1, "tray_list": [
                {"tray_id": 0, "filament_type": "PLA", "filament_color": "#FFFFFF", "status": 1},
                {"tray_id": 1, "filament_type": "PETG", "filament_color": "#112233", "status": 2},
            ]}]}}
        tel = apply_canvas(result, Telemetry())
        self.assertEqual(len(tel.filament_groups[0].slots), 4)
        self.assertTrue(tel.filament_groups[0].slots[1].active)
        self.assertIsNone(tel.filament_groups[0].slots[1].remaining)

    def test_cc1_sdcp_status(self):
        message = json.dumps({"Topic": "sdcp/status/ABC", "Data": {"Status": {
            "CurrentStatus": [13], "TempOfNozzle": 205, "TempTargetNozzle": 210,
            "TempOfHotbed": 55, "TempTargetHotbed": 60,
            "PrintInfo": {"Status": 13, "Progress": 25, "CurrentLayer": 5,
                          "TotalLayer": 20, "CurrentTicks": 60, "TotalTicks": 600,
                          "Filename": "cube.gcode"}}}})
        tel = parse_cc1_message(message)
        self.assertIsNotNone(tel)
        self.assertEqual(tel.state, PrinterState.PRINTING)
        self.assertEqual(tel.remaining_minutes, 9)
        self.assertEqual(tel.job_name, "cube.gcode")


if __name__ == "__main__":
    unittest.main()
