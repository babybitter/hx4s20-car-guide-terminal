"""Build a self-contained Windows folder; never writes into the original project."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parent

def sanitize_runtime(release):
    """Avoid PATH-sourced ICU and old Python CRT shadowing Qt's dependencies."""
    import hashlib
    import json
    import shutil
    import PySide6
    import pefile
    internal = release / '_internal'
    qt = Path(PySide6.__file__).parent
    changes = []
    for name in ('vcruntime140.dll', 'vcruntime140_1.dll'):
        source = qt / name
        if source.is_file():
            shutil.copy2(source, internal / name)
            changes.append({'file':name,'source':str(source),'action':'use matching Qt runtime'})
    icu = internal / 'icuuc.dll'
    if icu.is_file():
        image = pefile.PE(str(icu))
        exported = {s.name for s in image.DIRECTORY_ENTRY_EXPORT.symbols}
        image.close()
        if b'ucnv_open' not in exported:
            # Qt on Windows imports the OS's unversioned ICU entry points.
            # Preserve any incompatible PATH-collected files outside delivery.
            quarantine = ROOT / 'evidence/packaging-quarantine'
            quarantine.mkdir(exist_ok=True)
            for unwanted in (icu, internal / 'icudt78.dll'):
                if unwanted.is_file():
                    digest = hashlib.sha256(unwanted.read_bytes()).hexdigest()
                    destination = quarantine / (digest[:12]+'-'+unwanted.name)
                    assert unwanted.resolve().is_relative_to(ROOT.resolve())
                    assert destination.resolve().is_relative_to(ROOT.resolve())
                    if destination.exists():
                        # Only generated bundle files inside this isolated root.
                        unwanted.unlink()
                    else:
                        shutil.move(str(unwanted),str(destination))
                    changes.append({'file':unwanted.name,'action':'quarantine incompatible PATH dependency','sha256':digest})
    (ROOT / 'evidence/runtime-packaging.json').write_text(json.dumps(changes,ensure_ascii=False,indent=2),encoding='utf-8')

def stage_documents(release):
    import shutil
    import importlib.metadata
    # Distribution instructions and notices live at the root. Local docs are
    # optional and deliberately excluded from both GitHub and the EXE package.
    for source in ("README.md", "requirements-lock.txt", "第三方组件说明.md"):
        shutil.copy2(ROOT / source, release / source)
    # pyserial 3.5's installed wheel omits LICENSE.txt from its metadata.
    # Keep the upstream license in source so builds do not require a download.
    serial_licenses = release / "LICENSES/pyserial"
    serial_licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "pyserial-LICENSE.txt", serial_licenses / "LICENSE.txt")
    (release / '预览界面.bat').write_text(
        '@echo off\nstart "" "%~dp0HX4S20_Studio.exe" --demo\n', encoding='utf-8')
    for package in ('PySide6', 'PySide6_Essentials', 'PySide6_Addons', 'shiboken6',
                    'pyserial', 'Pillow', 'fonttools', 'PyInstaller'):
        dist = importlib.metadata.distribution(package)
        for item in dist.files or ():
            if any('license' in part.lower() for part in item.parts) or item.name.lower().startswith(('copying','copyright')):
                source = Path(dist.locate_file(item))
                if source.is_file() and source.suffix not in ('.py','.pyc','.pyd'):
                    target = release / 'LICENSES' / package / item
                    target.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(source,target)
    python_license = Path(sys.base_prefix) / 'LICENSE.txt'
    if python_license.is_file():
        target = release / 'LICENSES/Python'
        target.mkdir(parents=True,exist_ok=True)
        shutil.copy2(python_license,target / 'LICENSE.txt')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist-dir", type=Path, default=ROOT / "dist",
                        help="Output parent directory (default: host/qt/dist)")
    options = parser.parse_args()
    dist_dir = options.dist_dir.resolve()
    # A clean source checkout has no generated evidence directory yet.
    (ROOT / "evidence").mkdir(exist_ok=True)
    args = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
            "--onedir", "--windowed", "--name", "HX4S20_Studio",
            "--distpath", str(dist_dir), "--workpath", str(ROOT / "build"),
            "--specpath", str(ROOT / "build"),
            "--icon", str(ROOT / "assets/app.ico"),
            "--paths", str(ROOT / "legacy/tools/console")]
    for source, destination in (
        ("assets", "assets"),
        ("legacy/assets", "legacy/assets"),
        ("legacy/tools/bmp/output_bmp/catalog", "legacy/tools/bmp/output_bmp/catalog"),
        ("legacy/tools/console/examples", "legacy/tools/console/examples"),
        ("legacy/tools/console/sequence.schema.json", "legacy/tools/console"),
    ):
        if not (ROOT / source).exists():
            raise FileNotFoundError(f"Required packaging asset is missing: {ROOT / source}")
        args.extend(["--add-data", f"{ROOT / source}:{destination}"])
    for module in ("protocol", "sequence", "subtitle_bitmap", "local_preview",
                   "serial.tools.list_ports", "PIL.ImageQt", "fontTools.ttLib"):
        args.extend(["--hidden-import", module])
    args.append(str(ROOT / "main.py"))
    env = os.environ.copy()
    env['PYINSTALLER_CONFIG_DIR'] = str(ROOT / '.cache/pyinstaller')
    # Build subprocess only; never modify the user's PATH or installed tools.
    import PySide6
    windows = Path(os.environ.get('SystemRoot', 'C:/Windows'))
    env['PATH'] = os.pathsep.join(map(str, [Path(sys.executable).parent,
        Path(sys.base_prefix), Path(PySide6.__file__).parent,
        Path(PySide6.__file__).parent.parent / 'shiboken6', windows / 'System32', windows]))
    result = subprocess.run(args, cwd=ROOT, env=env, check=False)
    if result.returncode:
        return result.returncode
    release = dist_dir / "HX4S20_Studio"
    sanitize_runtime(release)
    stage_documents(release)
    print(f"Build complete: {release / 'HX4S20_Studio.exe'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
