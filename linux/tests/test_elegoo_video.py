"""Centauri Carbon camera: the Cmd 386 handshake, one shared stream slot, and frames without Huffman tables.
The same cases as macOS ElegooVideoTests and the Windows presentation tests."""
import threading
import time
import unittest

from gantry.elegoo import ElegooVideoGate, parse_cc1_video_reply
from gantry.jpegstream import STANDARD_HUFFMAN_TABLES, ensure_huffman_tables


class Wire:
    def __init__(self):
        self.sent: list[tuple[bool, str]] = []
        self._lock = threading.Lock()

    def __call__(self, enable, request_id):
        with self._lock:
            self.sent.append((enable, request_id))

    def wait_for(self, count, seconds=2.0):
        deadline = time.monotonic() + seconds
        while len(self.sent) < count and time.monotonic() < deadline:
            time.sleep(0.01)
        with self._lock:
            return list(self.sent)


def acquire_in_background(gate):
    result = {}
    thread = threading.Thread(target=lambda: result.setdefault("ack", gate.acquire()))
    thread.start()
    return thread, result


class ElegooVideoTests(unittest.TestCase):
    def test_reply_is_read_only_from_cmd_386(self):
        reply = parse_cc1_video_reply('{"Data":{"Cmd":386,"Data":{"Ack":1,"VideoUrl":""},"RequestID":"abc"},'
                                      '"Topic":"sdcp/response/M"}')
        self.assertEqual(reply, ("abc", 1))
        self.assertIsNone(parse_cc1_video_reply('{"Data":{"Cmd":403,"Data":{"Ack":0}}}'))
        self.assertIsNone(parse_cc1_video_reply('{"Data":{"Status":{"TempOfNozzle":200}}}'))
        self.assertIsNone(parse_cc1_video_reply("not json"))

    def test_first_viewer_waits_for_ack_others_share_and_last_one_disables(self):
        wire = Wire()
        gate = ElegooVideoGate(wire, reply_timeout=2, resend_interval=5, release_grace=0.1)
        thread, result = acquire_in_background(gate)
        sent = wire.wait_for(1)
        self.assertTrue(sent[0][0])
        gate.handle_reply("somebody-else", 1)
        gate.handle_reply(sent[0][1], 0)
        thread.join(2)
        self.assertEqual(result["ack"], 0)
        self.assertEqual(gate.acquire(), 0)
        self.assertEqual(len(wire.sent), 1, "a second viewer enabled the stream again")
        gate.release()
        time.sleep(0.3)
        self.assertEqual(len(wire.sent), 1, "the stream was disabled while a viewer still watched")
        gate.release()
        after = wire.wait_for(2)
        self.assertEqual(len(after), 2)
        self.assertFalse(after[1][0])

    def test_restart_within_grace_keeps_the_stream(self):
        wire = Wire()
        gate = ElegooVideoGate(wire, reply_timeout=2, resend_interval=5, release_grace=0.2)
        thread, _ = acquire_in_background(gate)
        gate.handle_reply(wire.wait_for(1)[0][1], 0)
        thread.join(2)
        gate.release()
        self.assertEqual(gate.acquire(), 0)
        time.sleep(0.4)
        self.assertEqual(len(wire.sent), 1)
        gate.release()

    def test_silent_printer_is_retried_then_reported_as_no_answer(self):
        wire = Wire()
        gate = ElegooVideoGate(wire, reply_timeout=0.35, resend_interval=0.1, release_grace=0.05)
        self.assertIsNone(gate.acquire())
        self.assertGreaterEqual(len(wire.sent), 3)
        gate.release()

    def test_ack_arriving_after_every_viewer_left_still_disables(self):
        wire = Wire()
        gate = ElegooVideoGate(wire, reply_timeout=2, resend_interval=5, release_grace=0.05)
        thread, _ = acquire_in_background(gate)
        request_id = wire.wait_for(1)[0][1]
        gate.release()
        gate.handle_reply(request_id, 0)
        thread.join(2)
        after = wire.wait_for(2)
        self.assertEqual(len(after), 2)
        self.assertFalse(after[1][0])

    def test_standard_tables_are_one_well_formed_segment(self):
        tables = STANDARD_HUFFMAN_TABLES
        offset, classes = 4, 0
        while offset < len(tables):
            offset += 17 + sum(tables[offset + 1:offset + 17])
            classes += 1
        self.assertEqual((len(tables), tables[1], offset, classes), (420, 0xC4, 420, 4))

    def test_missing_tables_are_put_in_front_of_the_scan(self):
        bare = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x04, 0x01, 0x02,
                      0xFF, 0xDA, 0x00, 0x04, 0x03, 0x04, 0x11, 0x22, 0xFF, 0xD9])
        repaired = ensure_huffman_tables(bare)
        self.assertEqual(len(repaired), len(bare) + 420)
        self.assertEqual(repaired[14:16], b"\xff\xc4")
        self.assertEqual(repaired[14 + 420:14 + 422], b"\xff\xda")
        self.assertIs(ensure_huffman_tables(repaired), repaired)
        self.assertEqual(ensure_huffman_tables(b"\x01\x02\x03"), b"\x01\x02\x03")


if __name__ == "__main__":
    unittest.main()
