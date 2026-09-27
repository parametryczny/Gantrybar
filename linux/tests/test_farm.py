import io
import json
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace

from gantry.core import AmsSlot, PrinterKind, PrinterState, Telemetry
from gantry.farm import FarmError, FarmStore, auto_mapping, command, next_queue_item, read_plates, read_preview, slot_index

CONFIG = (b'<config><plate><metadata key="index" value="1"/><filament id="1" type="PLA" color="#000000" used_g="8.2"/></plate>'
          b'<plate><metadata key="index" value="2"/><metadata key="prediction" value="7200"/>'
          b'<metadata key="nozzle_diameters" value="0.4"/><filament id="3" type="PETG" color="#FFFFFF" used_g="12"/></plate></config>')


def _archive(entries):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        for name, payload in entries.items():
            archive.writestr(name, payload)
    data.seek(0)
    return zipfile.ZipFile(data)


class ArchiveTests(unittest.TestCase):
    def test_plates_metadata_and_preview(self):
        archive = _archive({"Metadata/plate_1.gcode": b"G28", "Metadata/plate_2.gcode": b"G28",
                            "Metadata/slice_info.config": CONFIG, "Metadata/plate_2.png": b"\x01\x02"})
        plates = read_plates(archive)
        self.assertEqual([p["index"] for p in plates], [1, 2])
        self.assertEqual(plates[0]["filaments"][0]["material"], "PLA")
        self.assertEqual(plates[1]["seconds"], 7200)
        self.assertEqual(plates[1]["nozzle"], 0.4)
        self.assertEqual(read_preview(archive, 2), b"\x01\x02")
        self.assertIsNone(read_preview(archive, 1))

    def test_unsliced_file_is_refused(self):
        with self.assertRaises(FarmError):
            read_plates(_archive({"3D/3dmodel.model": b"model"}))


def _slot(unit, tray, material, color, grams=None, external=False):
    return AmsSlot(slot_id=f"ams-{unit}-{tray}" if not external else "external-254", label=f"A{tray + 1}",
                   material=material, color=color, external=external, remaining_weight_g=grams)


class RuleTests(unittest.TestCase):
    def test_slot_ids(self):
        self.assertEqual(slot_index("ams-1-2"), 6)
        self.assertIsNone(slot_index("external-254"))
        self.assertIsNone(slot_index("ams-128-0"))

    def test_auto_mapping_same_as_macos(self):
        plate = {"filaments": [{"id": 1, "material": "PLA", "color": "#FF0000", "grams": 10},
                               {"id": 2, "material": "PETG", "color": "#FFFFFF", "grams": 5}]}
        slots = [_slot(0, 0, "PLA", "0000FFFF"), _slot(0, 1, "PLA", "F01010FF"), _slot(0, 2, "PETG", "FAFAFAFF"),
                 _slot(0, 3, "PLA", "FF0000FF", grams=3)]
        self.assertEqual(auto_mapping(plate, slots), [1, 2])
        self.assertIsNone(auto_mapping({"filaments": [{"id": 1, "material": "ABS", "color": "#000000", "grams": 1}]},
                                       [_slot(0, 0, "PLA", "000000FF")]))
        self.assertEqual(auto_mapping({"filaments": [{"id": 1, "material": "PLA", "color": "#000000", "grams": 1}]},
                                      [_slot(0, 0, "PLA", "000000FF", external=True)]), [])

    def test_queue_respects_printer_and_nozzle(self):
        f = [{"id": 1, "material": "PLA", "color": "#000000", "grams": 1}]
        t = Telemetry(nozzle_diameter=0.4, ams_slots=[_slot(0, 0, "PLA", "000000FF")])
        queue = [{"copies": 1, "printers": ["OTHER"], "plate": {"filaments": f}},
                 {"copies": 1, "printers": [], "plate": {"filaments": f, "nozzle": 0.6}},
                 {"copies": 2, "printers": ["TEST"], "plate": {"filaments": f}}]
        self.assertEqual(next_queue_item(queue, "TEST", t), (2, [0]))

    def test_sparse_filament_ids_keep_their_positions(self):
        payload = json.loads(command({"remoteName": "gantry-1.3mf", "plate": {"index": 2}, "mapping": [-1, -1, 6]}))
        self.assertEqual(payload["print"]["ams_mapping"], [-1, -1, 6])
        self.assertEqual(payload["print"]["param"], "Metadata/plate_2.gcode")


class _Secrets:
    def get(self, key):
        return "12345678"


class StoreTests(unittest.TestCase):
    def _setup(self, state=PrinterState.IDLE):
        root = Path(tempfile.mkdtemp())
        sent, uploads = [], []
        telemetry = Telemetry(state=state, ams_slots=[_slot(0, 0, "PLA", "000000FF")])
        app = SimpleNamespace(printers=[SimpleNamespace(serial="TEST", name="Test", host="127.0.0.1", kind=PrinterKind.BAMBU)],
                              telemetry={"TEST": telemetry}, telemetry_seen={"TEST": time.time()}, secrets=_Secrets(),
                              send_command=lambda serial, payload: sent.append(payload) or True,
                              requires_signed_commands=lambda serial: False)

        def uploader(host, code, local, remote, progress, cancelled):
            uploads.append(remote)
            progress(1.0)
        store = FarmStore(app, root=root, uploader=uploader, run_async=lambda job: job())
        return store, app, sent, uploads

    def _file(self, store):
        plate = {"index": 1, "filaments": [{"id": 1, "material": "PLA", "color": "#000000", "grams": 8}]}
        entry = {"id": "f1", "name": "part.3mf", "bytes": 10, "plates": [plate], "importedAt": "2026-09-27T00:00:00+00:00"}
        store.files.append(entry)
        return entry, plate

    def test_upload_never_starts_and_start_is_sent_once(self):
        store, app, sent, uploads = self._setup()
        file, plate = self._file(store)
        store.upload_to(file, plate, app.printers[0], [])
        self.assertEqual(store.jobs[0]["state"], "uploaded")
        self.assertEqual(sent, [])
        with self.assertRaises(FarmError):
            store.start(store.jobs[0]["id"], False, True)
        store.start(store.jobs[0]["id"], True, True)
        self.assertEqual(len(sent), 1)
        with self.assertRaises(FarmError):
            store.start(store.jobs[0]["id"], True, True)
        app.telemetry["TEST"].state = PrinterState.PRINTING
        app.telemetry["TEST"].job_name = "another"
        app.telemetry_seen["TEST"] = time.time() + 1
        store.reconcile()
        self.assertEqual(store.jobs[0]["state"], "awaitingStart")
        app.telemetry["TEST"].job_name = store.jobs[0]["remoteName"][:-4]
        store.reconcile()
        self.assertEqual(store.jobs[0]["state"], "printing")

    def test_queue_waits_for_empty_bed_then_uploads_and_starts_one_copy(self):
        store, app, sent, uploads = self._setup()
        file, plate = self._file(store)
        store.enqueue(file, plate, 2, [])
        self.assertEqual(uploads, [])
        store.arm("TEST")
        self.assertEqual(len(uploads), 1)
        self.assertEqual(len(sent), 1)
        self.assertEqual(store.jobs[0]["state"], "awaitingStart")
        self.assertEqual(store.queue[0]["copies"], 1)
        self.assertNotIn("TEST", store.armed)
        store.reconcile()
        self.assertEqual(len(uploads), 1)

    def test_restart_never_replays_an_unconfirmed_start(self):
        store, app, sent, _ = self._setup()
        file, plate = self._file(store)
        store.upload_to(file, plate, app.printers[0], [])
        store.start(store.jobs[0]["id"], True, True)
        again = FarmStore(app, root=store.root, run_async=lambda job: job())
        self.assertEqual(again.jobs[0]["state"], "uncertain")
        self.assertEqual(len(sent), 1)

    def test_busy_or_stale_printer_cannot_start(self):
        store, app, sent, _ = self._setup(state=PrinterState.PRINTING)
        file, plate = self._file(store)
        store.upload_to(file, plate, app.printers[0], [])
        with self.assertRaises(FarmError):
            store.start(store.jobs[0]["id"], True, True)
        app.telemetry["TEST"].state = PrinterState.IDLE
        app.telemetry_seen["TEST"] = time.time() - 60
        with self.assertRaises(FarmError):
            store.start(store.jobs[0]["id"], True, True)
        self.assertEqual(sent, [])


if __name__ == "__main__":
    unittest.main()
