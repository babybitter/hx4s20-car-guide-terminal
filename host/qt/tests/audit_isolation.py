"""Audit the portable source inventory without requiring its original workspace."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    records = json.loads((ROOT / "source-manifest.json").read_text(encoding="utf-8"))
    rows = []
    for item in records["files"]:
        relative = Path(item["path"])
        target = (ROOT / relative).resolve()
        if relative.is_absolute() or not target.is_relative_to(ROOT):
            raise ValueError(f"Source inventory path escapes host: {relative}")
        # Local documents are intentionally absent from GitHub candidates.
        if "docs" in relative.parts and not target.exists():
            continue
        actual = hashlib.sha256(target.read_bytes()).hexdigest() if target.is_file() else None
        rows.append(dict(path=item["path"], expected=item["sha256"],
                         actual=actual, matches=actual == item["sha256"]))
    failed = [r["path"] for r in rows if not r["matches"]]
    report = dict(checked_files=len(rows), failures=failed, files=rows)
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    (evidence / "isolation-audit.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Checked {len(rows)} portable source files; mismatches: {len(failed)}")
    for path in failed:
        print(f"  CHANGED_OR_MISSING: {path}")
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
