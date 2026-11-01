import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from protocol import COMMANDS, LIMITS, LineReceiver, Session, line_command, parse_status, subtitle_command

STATUS = "Q P=003 C=004 A=1 READY=1 ERR=0 R=2 VER=1 CAP=NAMPIBCFTVWRESQ"


class ProtocolTests(unittest.TestCase):
    def test_all_command_ranges(self):
        for command in "NAMPQ":
            self.assertEqual(line_command(command), (command+"\r\n").encode())
        for code, limit in LIMITS.items():
            for value in range(limit+1):
                self.assertEqual(line_command(f"{code}{value}"), f"{code}{value}\r\n".encode())
            with self.assertRaises(ValueError):
                line_command(f"{code}{limit+1}")
        for page in (1, 4, 128):
            self.assertEqual(line_command(f"I{page:03d}"), f"I{page:03d}\r\n".encode())

    def test_invalid_commands(self):
        for command in ("", "n", "N\nA", "N\r", " B3", "B3x", "B", "I1", "I000", "I129", "I９９９", "Z", "D", "E", "中文", "S:\t"):
            with self.subTest(command=command), self.assertRaises(ValueError):
                line_command(command)

    def test_subtitle_preserves_exact_ascii(self):
        self.assertEqual(subtitle_command("aZ !~ "), b"S:aZ !~ \r\n")
        self.assertEqual(subtitle_command(""), b"S:\r\n")
        self.assertEqual(len(subtitle_command("A"*40)), 44)
        for text in ("A"*41, "中", "a\x7f", "a\nN"):
            with self.assertRaises(ValueError):
                subtitle_command(text)

    def test_status_and_missing_effect_readback(self):
        status = parse_status(STATUS+"\r\n")
        self.assertEqual((status.page, status.count, status.auto, status.ready, status.error, status.period), (3,4,True,True,0,2))
        self.assertEqual(status.capabilities, COMMANDS)
        self.assertFalse(hasattr(status, "brightness"))
        self.assertIsNone(parse_status("OK"))
        self.assertIsNone(parse_status("Q:I1 L4 V1"))
        for bad in (STATUS.replace("003", "129"), STATUS.replace("004", "256"), STATUS.replace("VER=1", "VER=2"), STATUS+" B=3", STATUS.replace("CAP=", "CAP=Q")):
            self.assertIsNone(parse_status(bad))
        self.assertEqual(parse_status(STATUS.replace("C=004", "C=000")).count, 0)

    def ready_session(self, profile="control", status=STATUS):
        session = Session(profile)
        self.assertFalse(session.allowed("N"))
        session.begin("Q", 0)
        self.assertEqual(session.receive(status), "status")
        return session

    def test_profiles_and_capability_intersection(self):
        session = self.ready_session()
        for code in "NAMPIRQ":
            self.assertTrue(session.allowed(code))
        for code in "BCFTVWESZ":
            self.assertFalse(session.allowed(code))
        session = self.ready_session("effects")
        for code in COMMANDS:
            self.assertTrue(session.allowed(code))
        session = self.ready_session("effects", STATUS.replace("NAMPIBCFTVWRESQ", "NQ"))
        self.assertFalse(session.allowed("B"))

    def test_page_count_and_stop_and_wait(self):
        session = self.ready_session()
        with self.assertRaises(ValueError): session.begin("I005", 0)
        session.begin("I004", 0)
        with self.assertRaises(ValueError): session.begin("N", 0)
        self.assertFalse(session.timed_out(.999))
        self.assertTrue(session.timed_out(1.0))
        self.assertEqual(session.receive("ACK I"), "ack")
        self.assertEqual(session.status.page, 3)  # ACK cannot fabricate page=4.
        session.begin("A", 2)
        session.receive("ACK A")
        self.assertTrue(session.status.auto)  # ACK cannot toggle the readback.

    def test_errors_reconnect_and_mismatched_ack(self):
        session = self.ready_session()
        for error in ("SYNTAX", "RANGE", "LENGTH", "FRAME", "TIMEOUT", "BUSY"):
            session.begin("N", 0)
            self.assertEqual(session.receive("ERR "+error), "error")
        session.begin("N", 0)
        with self.assertRaises(ValueError): session.receive("ACK A")
        self.assertEqual(session.pending, "N")
        session.reset()
        self.assertIsNone(session.status)
        self.assertFalse(session.allowed("N"))
        with self.assertRaises(ValueError): session.receive("ACK N")

    def test_split_lines_and_bad_input(self):
        reader = LineReceiver()
        self.assertEqual(reader.feed(b"ACK "), [])
        self.assertEqual(reader.feed(b"N\r"), ["ACK N"])
        self.assertEqual(reader.feed(b"\nERR BUSY\r\n"), ["ERR BUSY"])
        for bad in (b"\xff", b"x"*161, b"\x00"):
            with self.assertRaises(ValueError): LineReceiver().feed(bad)

    def test_real_rtl_trace(self):
        trace = Path(os.environ.get("UART_RTL_TRACE", Path(__file__).resolve().parents[3]/".tooling/uart-replies.log"))
        if not trace.exists(): self.skipTest("Icarus trace not generated")
        lines = trace.read_text().splitlines()
        statuses = [parse_status(line) for line in lines if line.startswith("Q ")]
        self.assertGreaterEqual(len(statuses), 13)
        self.assertTrue(all(status is not None for status in statuses))
        self.assertEqual((statuses[0].page, statuses[0].count, statuses[1].page, statuses[1].count), (3,4,128,128))
        self.assertIn("ERR BUSY", lines)
        self.assertIn("ERR FRAME", lines)
        self.assertIn("ERR TIMEOUT", lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
