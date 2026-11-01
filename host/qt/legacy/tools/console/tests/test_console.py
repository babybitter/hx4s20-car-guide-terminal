"""Retained non-GUI regression from the original Tk console test module."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_protocol import STATUS


class OptionalSerialTests(unittest.TestCase):
    def test_pyserial_loopback_framing(self):
        import serial
        from protocol import LineReceiver
        with serial.serial_for_url("loop://", baudrate=115200, timeout=.2) as port:
            message = b"ACK N\r\n" + (STATUS+"\r\n").encode()
            self.assertEqual(port.write(message), len(message))
            self.assertEqual(LineReceiver().feed(port.read(len(message))), ["ACK N", STATUS])


if __name__ == "__main__":
    unittest.main(verbosity=2)
