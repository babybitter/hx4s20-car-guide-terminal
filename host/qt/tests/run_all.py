"""Run copied legacy and Qt regressions with physical serial access forbidden."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "evidence"


def run_qt():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "legacy/tools/console"))
    scratch = EVIDENCE / ".test-tmp"
    scratch.mkdir(exist_ok=True)
    tempfile.tempdir = str(scratch)
    import serial
    from serial.tools import list_ports
    original_url = serial.serial_for_url

    def loop_only(url, *args, **kwargs):
        if url != "loop://":
            raise AssertionError("Offline regression forbids physical ports")
        return original_url(url, *args, **kwargs)

    with patch.object(serial, "Serial", side_effect=AssertionError("Physical serial disabled")), \
         patch.object(serial, "serial_for_url", side_effect=loop_only), \
         patch.object(list_ports, "comports", return_value=[]):
        suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_*.py")
        print(f"Qt offline suite: {suite.countTestCases()} tests; physical ports disabled", flush=True)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    summary = {"tests": result.testsRun, "failures": len(result.failures),
               "errors": len(result.errors), "skipped": len(result.skipped)}
    (EVIDENCE / "qt-test-summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 0 if result.wasSuccessful() and not result.skipped else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qt", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    EVIDENCE.mkdir(exist_ok=True)
    if args.qt:
        return run_qt()
    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    scratch = EVIDENCE / ".test-tmp"
    scratch.mkdir(exist_ok=True)
    env["TEMP"] = env["TMP"] = str(scratch)
    commands = [
        ("legacy-regression", [sys.executable, "-B", str(ROOT / "legacy/tools/console/run_tests.py")]),
        ("qt-regression", [sys.executable, "-B", str(Path(__file__).resolve()), "--qt"]),
        ("isolation-audit", [sys.executable, "-B", str(ROOT / "tests/audit_isolation.py")]),
    ]
    results = []
    for name, command in commands:
        start = time.monotonic()
        log_path = EVIDENCE / f"{name}.log"
        with log_path.open("w", encoding="utf-8") as stream:
            process = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
        result = {"name": name, "exit_code": process.returncode,
                  "seconds": round(time.monotonic() - start, 3), "log": log_path.name}
        results.append(result)
        print(f"{name}: exit={process.returncode}; {result['seconds']}s; {log_path}", flush=True)
        if process.returncode:
            print("\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-35:]))
    (EVIDENCE / "test-run-summary.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    return int(any(row["exit_code"] != 0 for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
