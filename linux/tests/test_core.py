import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gantry.core import PrinterKind, PrinterState, expand_scan_targets, parse_telemetry, studio_devices_from_content
from gantry.csvimport import parse_printer_csv, template_csv
from gantry.discovery import parse_ssdp
from gantry.desktop import installed_slicers
from gantry.http_clients import parse_cfs, parse_moonraker, parse_prusalink
from gantry.mqtt import connect_packet, publish_packet, publish_payload, subscribe_packet
from gantry.webconfig import config_page, pairing_code, validate_printer_form


class CoreTests(unittest.TestCase):
    def test_scan_targets(self):
        self.assertEqual(expand_scan_targets("192.168.1.5"), ["192.168.1.5"])
        self.assertEqual(len(expand_scan_targets("192.168.1.0/30")), 2)
        self.assertEqual(len(expand_scan_targets("192.168.1.5-192.168.1.7")), 3)
        self.assertEqual(len(expand_scan_targets("192.168.1.5, 192.168.1.5")), 1)
        with self.assertRaises(ValueError):
            expand_scan_targets("100.64.0.0/10")

    def test_status_and_ams(self):
        payload = {"print": {"gcode_state": "RUNNING", "mc_percent": 42,
                              "mc_remaining_time": 81, "subtask_name": "część%20v2",
                              "layer_num": 20, "total_layer_num": 100, "stg_cur": 13,
                              "ams": {"tray_now": "0", "ams": [{"id": "0", "humidity": "3",
                              "tray": [{"id": "0", "tray_type": "PLA", "tray_color": "FF0000FF"}]}]}}}
        value = parse_telemetry(json.dumps(payload, ensure_ascii=False))
        self.assertIsNotNone(value)
        self.assertEqual(value.state, PrinterState.PRINTING)
        self.assertEqual(value.job_name, "część v2")
        self.assertEqual(value.stage, 13)
        self.assertEqual(len(value.ams_slots), 4)
        self.assertTrue(value.ams_slots[0].active)

    def test_legacy_chamber_and_hms_are_kept_with_device_payload(self):
        payload = {"print": {"device": {}, "chamber_temper": 37.5,
                              "hms": [{"attr": 1, "code": 2}], "print_error": "FF"}}
        value = parse_telemetry(payload)
        self.assertEqual(value.chamber, 37.5)
        self.assertEqual(value.hms_codes, ["0000000100000002"])
        self.assertEqual(value.error_code, 255)
        self.assertEqual(value.state, PrinterState.ERROR)

    def test_studio_json_with_checksum(self):
        content = '{"access_code":{"S1":"old"},"user_access_code":{"S1":"new"},"ip_address":{"S1":"192.168.1.2"}}\n012345'
        self.assertEqual(studio_devices_from_content(content), [("S1", "new", "192.168.1.2")])

    def test_ssdp(self):
        data = (b"HTTP/1.1 200 OK\r\nUSN: uuid:01S00A123456789::upnp:rootdevice\r\n"
                b"DevName.bambu.com: Workshop\r\nDevModel.bambu.com: X1C\r\n\r\n")
        value = parse_ssdp(data, "192.168.1.20")
        self.assertIsNotNone(value)
        self.assertEqual(value.serial, "01S00A123456789")
        self.assertEqual(value.name, "Workshop")

    def test_mqtt_packets(self):
        self.assertEqual(connect_packet("bblp", "12345678")[0], 0x10)
        self.assertEqual(subscribe_packet("device/x/report")[0], 0x82)
        packet = publish_packet("topic", b"hello")
        length = packet[2] << 8 | packet[3]
        self.assertEqual(publish_payload(0x30, packet[2:]), b"hello")
        self.assertEqual(length, 5)

    def test_csv_template_and_import(self):
        self.assertEqual(template_csv().strip(), "kind,name,host,serial,access_code,port")
        values = parse_printer_csv(
            template_csv() + "bambu,Drukarka warsztatowa,192.168.1.50,NUMER_SERYJNY,KOD_DOSTEPU,8883\n"
        )
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0]["port"], 8883)
        self.assertEqual(values[0]["name"], "Drukarka warsztatowa")
        self.assertEqual(values[0]["kind"], PrinterKind.BAMBU.value)

    def test_csv_supports_klipper_and_prusa(self):
        content = ("kind,name,host,serial,access_code,port\n"
                   "klipper,Voron,192.168.1.30,,,7125\n"
                   "prusa,MK4,192.168.1.31,,APIKEY,80\n")
        values = parse_printer_csv(content)
        self.assertEqual(values[0]["serial"], "klipper-192.168.1.30-7125")
        self.assertEqual(values[1]["kind"], "prusa")

    def test_moonraker_prusalink_and_filament_parsers(self):
        moonraker = parse_moonraker({"result": {"status": {
            "print_stats": {"state": "printing", "filename": "jobs/demo.gcode",
                            "print_duration": 600, "info": {"current_layer": 4, "total_layer": 20}},
            "display_status": {"progress": .25}, "extruder": {"temperature": 220, "target": 225},
            "heater_bed": {"temperature": 60, "target": 60},
            "mmu": {"enabled": True, "num_gates": 2, "gate": 1,
                    "gate_material": ["PLA", "PETG"], "gate_color": ["ff0000", "00ff00"],
                    "gate_status": [1, 1]},
        }}})
        self.assertEqual(moonraker.state, PrinterState.PRINTING)
        self.assertEqual(moonraker.progress, 25)
        self.assertEqual(len(moonraker.ams_slots), 2)
        self.assertTrue(moonraker.ams_slots[1].active)
        # Happy Hare forms one dynamic MMU module with num_gates gates, not split into fours.
        self.assertEqual(len(moonraker.filament_groups), 1)
        self.assertEqual(moonraker.filament_groups[0].source_type, "mmu")
        self.assertEqual(moonraker.filament_groups[0].declared_capacity, 2)
        self.assertEqual([s.label for s in moonraker.filament_groups[0].slots], ["T0", "T1"])
        self.assertTrue(moonraker.filament_groups[0].slots[1].active)
        prusa = parse_prusalink(
            {"printer": {"state": "PRINTING", "temp_nozzle": 214, "target_nozzle": 215,
                         "temp_bed": 59, "target_bed": 60},
             "job": {"progress": 40, "time_remaining": 1800}},
            {"file": {"display_name": "demo_prusa.gcode"}},
        )
        self.assertEqual(prusa.remaining_minutes, 30)
        self.assertEqual(prusa.job_name, "demo_prusa.gcode")
        cfs = parse_cfs({"boxsInfo": {"materialBoxs": [
            {"type": 0, "materials": [{"type": "PLA", "color": "0fa7c0c", "percent": 82, "selected": 1}]},
            {"type": 1, "materials": [{"type": "ABS", "color": "0000ff", "percent": 30}]},
        ]}})
        # Each box is a separate module; the spool holder (type 1) becomes EXT, keeping four fixed CFS slots.
        self.assertEqual([g.display_name for g in cfs], ["CFS 1", "EXT"])
        self.assertEqual(cfs[0].declared_capacity, 4)
        self.assertEqual(cfs[0].slots[0].color, "FA7C0CFF")
        self.assertEqual(cfs[0].slots[0].remaining, 82)
        self.assertTrue(cfs[0].slots[0].active)
        self.assertFalse(cfs[0].slots[3].present)
        self.assertTrue(cfs[1].external)

    def test_csv_rejects_duplicate_serial(self):
        content = "name,host,serial,access_code,port\nA,192.168.1.2,S1,C1,8883\nB,192.168.1.3,S1,C2,8883\n"
        with self.assertRaises(ValueError):
            parse_printer_csv(content)

    def test_web_config_validation_and_pairing(self):
        code = pairing_code()
        self.assertEqual(len(code), 6)
        self.assertTrue(code.isdigit())
        value, error = validate_printer_form({
            "name": "X1", "host": "192.168.1.8", "serial": "SERIAL1",
            "code": "12345678", "port": "8883",
        })
        self.assertFalse(error)
        self.assertEqual(value["port"], 8883)
        klipper, error = validate_printer_form({
            "kind": "klipper", "name": "Voron", "host": "192.168.1.30", "port": "7125"
        })
        self.assertFalse(error)
        self.assertEqual(klipper["serial"], "klipper-192.168.1.30-7125")
        page = config_page({"printers": []}, "csrf-token")
        self.assertIn("Pobierz szablon CSV", page)
        self.assertIn('action="/import"', page)
        self.assertIn("Klipper / Moonraker", page)

    def test_web_dashboard_contains_live_telemetry(self):
        page = config_page({"printers": [{
            "serial": "S1", "name": "X1C", "host": "192.168.1.8", "kind": "bambu",
            "state": "printing", "progress": 42, "job": "demo_1.3mf", "remaining": 73,
            "layer": 50, "layers": 120, "nozzle": 245, "nozzle_target": 245,
            "bed": 70, "bed_target": 70,
            "ams": [{"label": "A1", "color": "ff0000", "active": True}],
        }]}, "csrf-token")
        for expected in ("GANTRY", "demo_1.3mf", "42%", "A1", "printer-grid", "location.reload"):
            self.assertIn(expected, page)

    def test_native_slicer_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "orca-slicer"
            executable.touch(mode=0o755)
            with patch("gantry.desktop.shutil.which", side_effect=lambda name: str(executable) if name == "orca-slicer" else None):
                values = installed_slicers()
        self.assertEqual([(value.name, value.command) for value in values],
                         [("OrcaSlicer", (str(executable),))])


if __name__ == "__main__":
    unittest.main()
