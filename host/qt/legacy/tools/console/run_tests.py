"""Offline regression runner: no real Serial/comports; all temp writes local."""
import argparse
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
LEGACY = ("test_console", "test_local_preview", "test_protocol",
          "test_sequence", "test_subtitle_bitmap", "test_v2_protocol")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy", action="store_true", help="只运行保留的非音频基础回归（不含已退役的Tk界面）")
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    scratch = ROOT / ".test-tmp"
    scratch.mkdir(exist_ok=True)
    tempfile.tempdir = str(scratch)
    os.environ["TMP"] = os.environ["TEMP"] = str(scratch)
    os.environ["UART_RTL_TRACE"] = str(ROOT / "fixtures/uart-replies.log")
    os.environ["UART_V2_RTL_TRACE"] = str(ROOT / "fixtures/uart-v2-replies.log")
    # Reuse the local installed dependency if this Python lacks pyserial.
    try:
        import serial
    except ImportError:
        sys.path.insert(0, str(ROOT.parents[1] / ".tooling" / "uart-python-deps"))
        import serial
    from serial.tools import list_ports
    real_url = serial.serial_for_url

    def loop_only(url, *args, **kwargs):
        if url != "loop://":
            raise AssertionError("离线测试只允许内存loop://，禁止真实串口")
        return real_url(url, *args, **kwargs)

    sys.path.insert(0, str(ROOT / "tests"))
    with patch.object(serial, "Serial", side_effect=AssertionError("禁止真实串口")), \
         patch.object(serial, "serial_for_url", side_effect=loop_only), \
         patch.object(list_ports, "comports", return_value=[]):
        loader = unittest.TestLoader()
        suite = (loader.loadTestsFromNames(LEGACY) if args.legacy else
                 loader.discover(str(ROOT / "tests")))
        print(f"Offline suite: {suite.countTestCases()} tests; temp/trace paths bound to {ROOT}", flush=True)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__ == "__main__":
    raise SystemExit(main())
