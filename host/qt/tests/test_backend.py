"""Deterministic fake-wire tests; never enumerate or open physical ports."""
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from app.backend import BackendWorker
from app.presets import PRESETS
from protocol import parse_status, parse_hardware

CAPS = "NAMPIBCFTVWRESQHXZDGUJKOY"


class FakePort:
    def __init__(self, caps=CAPS, *, ignore_settings=False, bad_ack=None, short=None):
        self.caps, self.ignore_settings, self.bad_ack, self.short = caps, ignore_settings, bad_ack, short
        self.rx = bytearray()
        self.commands = []
        self.config = 0
        self.version, self.bank, self.count = 0, 0, 8
        self.opened = False
        self.closed = False
        self.page = 1
        self.on_write = None
        self.subtitle_board = None
        self.audio_line = None

    def status(self):
        return f"Q P={self.page:03d} C=008 A=0 READY=1 ERR=0 R=1 VER=1 CAP={self.caps}"

    def hardware(self):
        sq = (self.version << 16) | (self.count << 3) | (self.bank << 2) | (int(self.opened) << 1)
        return f"H CFG={self.config:08X} EV=0000 SI=FFFFFFFF DM=00000000 LD=00000001 FF=00000002 CL=00000000 SQ={sq:08X}"

    def write(self, frame):
        text = frame.decode("ascii").removesuffix("\r\n")
        if not text:
            return len(frame)
        self.commands.append(text)
        if self.on_write:
            self.on_write(text)
        if text == self.short:
            return len(frame)-1
        if text == "Q": reply = self.status()
        elif text == "H": reply = self.hardware()
        elif text == "AQ": reply = self.audio_line or "ERR SYNTAX"
        elif text.startswith("O") and self.subtitle_board:
            reply = self.subtitle_board.exchange(frame)
        else:
            if text == "U": self.opened = True
            if text.startswith("K"):
                self.count = int(text[1:]); self.version = (self.version+1) & 65535
                self.bank ^= 1; self.opened = False
            if text == "N": self.page = self.page % 8 + 1
            if not self.ignore_settings and text[:1] in {"X", "E", "T"}:
                shift, mask = {"X": (16, 3), "E": (12, 1), "T": (7, 3)}[text[0]]
                self.config = (self.config & ~(mask << shift)) | (int(text[1]) << shift)
            reply = "ACK ?" if text == self.bad_ack else "ACK " + text[0]
        self.rx.extend((reply + "\r\n").encode("ascii"))
        return len(frame)

    def read(self, size):
        # Deliberately fragment every reply, including its terminator.
        data = bytes(self.rx[:7]); del self.rx[:7]
        return data

    def close(self): self.closed = True


def document(count=2):
    return json.dumps({"schema": 1, "entries": [dict(source_id=1, title_id=1,
        dwell_ms=1000, transition=0, cue=4, prompt=False) for _ in range(count)]})


class BackendTests(unittest.TestCase):
    def make(self, port=None, profile="effects"):
        port = port or FakePort()
        worker = BackendWorker()
        worker.port = port
        worker.session.profile = profile
        worker.session.status = parse_status(port.status())
        worker.session.hardware = parse_hardware(port.hardware())
        worker.session.audio_supported = False
        events = []
        worker.event.connect(events.append)
        return worker, port, events

    def test_all_presets_ack_each_command_then_confirm_actual(self):
        for name, preset in PRESETS.items():
            with self.subTest(name=name):
                worker, port, events = self.make()
                worker.execute({"action": "preset", "name": name})
                self.assertEqual(port.commands[:len(preset["commands"])], list(preset["commands"]))
                self.assertEqual(port.commands[len(preset["commands"])], "H")
                self.assertTrue(all(worker.session.hardware.settings[k] == v for k,v in preset["expected"].items()))
                self.assertTrue(any(e.get("level") == "success" for e in events))
                self.assertNotIn("N", port.commands)

    def test_optional_next_happens_after_confirming_h(self):
        worker, port, _ = self.make()
        worker.execute({"action": "preset", "name": "横擦", "next_page": True})
        self.assertEqual(port.commands[:5], ["X0", "E1", "T1", "H", "N"])

    def test_missing_late_capability_causes_zero_writes(self):
        worker, port, events = self.make(FakePort(caps=CAPS.replace("T", "")))
        worker.execute({"action": "preset", "name": "横擦"})
        self.assertEqual(port.commands, [])
        self.assertFalse(any(e["kind"] == "requested" for e in events))

    def test_control_profile_cannot_send_presets(self):
        worker, port, _ = self.make(profile="control")
        worker.execute({"action": "preset", "name": "横擦"})
        self.assertEqual(port.commands, [])

    def test_ack_is_not_preset_application_and_does_not_next(self):
        worker, port, events = self.make(FakePort(ignore_settings=True))
        with patch("app.backend.time.monotonic", side_effect=(x*.2 for x in range(1000))):
            worker.execute({"action": "preset", "name": "横擦", "next_page": True})
        self.assertNotIn("N", port.commands)
        self.assertFalse(any(e.get("level") == "success" for e in events))
        self.assertEqual(port.commands.count("T1"), 1)

    def test_wrong_ack_disconnects_and_does_not_send_later_commands(self):
        worker, port, _ = self.make(FakePort(bad_ack="E1"))
        worker.execute({"action": "preset", "name": "竖擦"})
        self.assertEqual(port.commands, ["X0", "E1"])
        self.assertTrue(port.closed)
        self.assertIsNone(worker.session.status)

    def test_short_write_disconnects_without_replaying_toggle(self):
        worker, port, _ = self.make(FakePort(short="A"))
        worker.execute({"action": "command", "command": "A"})
        self.assertEqual(port.commands, ["A"])
        self.assertTrue(port.closed)

    def test_cancel_during_reply_stops_remaining_preset(self):
        worker, port, _ = self.make()
        port.on_write = lambda command: worker.cancel_event.set()
        worker.execute({"action": "preset", "name": "棋盘遮罩"})
        self.assertEqual(port.commands, ["X0"])
        self.assertTrue(port.closed)

    def test_sequence_whole_validation_before_first_write(self):
        worker, port, _ = self.make()
        data = json.loads(document()); data["entries"][-1]["source_id"] = 9
        worker.execute({"action": "sequence", "text": json.dumps(data)})
        self.assertEqual(port.commands, [])

    def test_sequence_confirms_version_bank_count_without_auto_play(self):
        worker, port, events = self.make()
        port.version = 65535
        worker.execute({"action": "sequence", "text": document()})
        self.assertEqual(port.version, 0)
        self.assertEqual(port.bank, 1)
        self.assertEqual(port.count, 2)
        self.assertNotIn("G1", port.commands)
        self.assertTrue(any(e.get("level") == "success" and "已应用" in e["text"] for e in events))

    def test_legacy_aq_rejected_then_poll_preserves_q_h(self):
        worker, port, _ = self.make()
        worker.execute({"action": "refresh"})
        self.assertFalse(worker.session.audio_supported)
        port.commands.clear()
        worker.poll()
        self.assertEqual(port.commands, ["Q", "H"])
        self.assertIsNotNone(worker.session.status)

    def test_unsupported_z2_is_rejected_before_write(self):
        worker, port, _ = self.make()
        worker.execute({"action": "command", "command": "Z2"})
        self.assertEqual(port.commands, [])

    def test_stale_reply_cannot_match_next_command(self):
        worker, port, _ = self.make()
        port.rx.extend(b"ACK A\r\n")
        worker.execute({"action": "command", "command": "A"})
        self.assertEqual(port.commands, [])
        self.assertTrue(port.closed)

    def test_subtitle_reuses_only_existing_port_and_verifies_apply(self):
        spec = importlib.util.spec_from_file_location("legacy_bitmap_fixture", ROOT / "legacy/tools/console/tests/test_subtitle_bitmap.py")
        fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
        worker, port, events = self.make()
        port.subtitle_board = fixture.FakeBoard()
        worker.execute({"action": "subtitle", "text": "欢迎乘车\n下一站", "font": ""})
        self.assertEqual(sum(c.startswith("OD") for c in port.commands), 80)
        self.assertTrue(any(e.get("level") == "success" and "blank应用" in e["text"] for e in events))
        self.assertFalse(port.closed)
        self.assertIs(worker.port, port)

    def test_invalid_subtitle_has_zero_writes(self):
        worker, port, _ = self.make()
        worker.execute({"action": "subtitle", "text": "bad\x00", "font": ""})
        self.assertEqual(port.commands, [])

    def test_timeout_never_replays_toggle(self):
        worker, port, _ = self.make()
        port.read = lambda size: b""
        with patch("app.backend.time.monotonic", side_effect=(x*.1 for x in range(1000))):
            worker.execute({"action": "command", "command": "A"})
        self.assertEqual(port.commands, ["A"])
        self.assertTrue(port.closed)
        self.assertIsNone(worker.session.status)

    def test_subtitle_wrong_status_disconnects(self):
        worker, port, events = self.make()
        worker.execute({"action": "subtitle", "text": "中文"})
        # FakePort without a subtitle model returns ACK O to OQ: it cannot
        # masquerade as an application status and must invalidate the link.
        self.assertTrue(port.closed)
        self.assertFalse(any(e.get("level") == "success" for e in events))

    def test_disconnect_releases_ui_busy_and_allows_reconnect(self):
        worker, port, events = self.make()
        worker.execute({"action": "disconnect"})
        self.assertTrue(port.closed)
        self.assertEqual(events[-1], {"kind": "busy", "busy": False})
        replacement = FakePort()
        worker.serial_factory = lambda **kwargs: replacement
        with patch.object(worker, "_quiet"):
            worker.execute({"action": "connect", "port": "FAKE", "profile": "effects"})
        self.assertIs(worker.port, replacement)
        self.assertIsNotNone(worker.session.status)

    def test_background_poll_cannot_unlock_queued_ui_action(self):
        worker, port, events = self.make()
        worker.poll()
        self.assertFalse(any(e["kind"] == "busy" for e in events))
        self.assertFalse(worker.busy)

    def test_pre_cancelled_connect_never_opens_port(self):
        worker = BackendWorker(serial_factory=lambda **kwargs: self.fail("cancelled connect opened a port"))
        worker.cancel_event.set()
        worker.execute({"action": "connect", "port": "FAKE", "profile": "effects"})
        self.assertIsNone(worker.port)
        self.assertFalse(worker.cancel_event.is_set())

    def test_consumed_cancellation_does_not_require_two_reconnects(self):
        worker, port, _ = self.make()
        port.on_write = lambda command: worker.cancel_event.set()
        worker.execute({"action": "preset", "name": "横擦"})
        self.assertFalse(worker.cancel_event.is_set())
        replacement = FakePort()
        worker.serial_factory = lambda **kwargs: replacement
        with patch.object(worker, "_quiet"):
            worker.execute({"action": "connect", "port": "FAKE"})
        self.assertIsNotNone(worker.session.status)

    def test_stop_closes_before_signalling_and_rejects_queued_work(self):
        worker, port, _ = self.make()
        closed_when_stopped = []
        worker.stopped.connect(lambda: closed_when_stopped.append(port.closed))
        worker.stop()
        self.assertEqual(closed_when_stopped, [True])
        worker.execute({"action": "connect", "port": "FAKE"})
        worker.poll()
        self.assertEqual(port.commands, [])

    def test_cancel_during_poll_is_consumed_before_reconnect(self):
        worker, port, _ = self.make()
        port.on_write = lambda command: worker.cancel_event.set()
        worker.poll()
        self.assertTrue(port.closed)
        self.assertFalse(worker.cancel_event.is_set())
        replacement = FakePort()
        worker.serial_factory = lambda **kwargs: replacement
        with patch.object(worker, "_quiet"):
            worker.execute({"action": "connect", "port": "FAKE"})
        self.assertIs(worker.port, replacement)
        self.assertIsNotNone(worker.session.status)

    def test_real_qthread_opens_and_closes_port_on_worker_thread(self):
        from PySide6.QtCore import QObject, Signal, QThread, Qt
        from PySide6.QtWidgets import QApplication
        global _qt_application
        _qt_application = QApplication.instance() or QApplication([])

        class Relay(QObject):
            command = Signal(dict)
            shutdown = Signal()

        opened, closed = [], []
        port = FakePort()
        original_close = port.close
        def close():
            closed.append(threading.get_ident())
            original_close()
        port.close = close
        def factory(**kwargs):
            opened.append(threading.get_ident())
            return port
        worker = BackendWorker(serial_factory=factory)
        thread = QThread()
        relay = Relay()
        worker.moveToThread(thread)
        relay.command.connect(worker.execute)
        relay.shutdown.connect(worker.stop)
        worker.stopped.connect(thread.quit, Qt.DirectConnection)
        thread.started.connect(worker.start)
        thread.finished.connect(worker.deleteLater)
        events = []
        worker.event.connect(events.append)
        thread.start()
        try:
            relay.command.emit({"action": "connect", "port": "FAKE"})
            deadline = time.monotonic() + 3
            while not any(e.get("kind") == "connection" and e.get("connected") for e in events):
                _qt_application.processEvents()
                if time.monotonic() > deadline:
                    self.fail("worker did not connect")
                time.sleep(.005)
            worker.cancel_event.set()
            relay.shutdown.emit()
            self.assertTrue(thread.wait(1800), "worker must close and quit without main-thread events")
            self.assertEqual(len(opened), 1)
            self.assertEqual(closed, opened)
            self.assertNotEqual(opened[0], threading.get_ident())
        finally:
            if thread.isRunning():
                worker.cancel_event.set()
                relay.shutdown.emit()
                thread.wait(3000)


if __name__ == "__main__":
    unittest.main()
