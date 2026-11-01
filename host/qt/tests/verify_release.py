"""Relocate the complete EXE folder and smoke-test without hardware."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist-dir', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    source = args.dist_dir.resolve() / 'HX4S20_Studio'
    exe = source / 'HX4S20_Studio.exe'
    sha = hashlib.sha256(exe.read_bytes()).hexdigest()
    destination = ROOT / 'evidence' / '移机验证 空格路径' / f'Studio-{time.time_ns()}'
    shutil.copytree(source, destination)
    cwd = destination.parent / 'unrelated-cwd'
    cwd.mkdir(exist_ok=True)
    screenshot = ROOT / 'evidence/packaged-exe-offline.png'
    env = os.environ.copy()
    env['QT_QPA_PLATFORM'] = 'offscreen'
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    result = subprocess.run([str(destination / exe.name), '--demo', '--smoke-screenshot', str(screenshot)],
        cwd=cwd, env=env, timeout=45, capture_output=True,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
    # Restart the real frozen app with each saved theme in its relocated local
    # config. Never change Windows appearance or the user's source preferences.
    theme_runs = []
    from PIL import Image
    config = destination / 'config/ui_preferences.json'
    config.parent.mkdir(exist_ok=True)
    for theme in ('light', 'dark'):
        config.write_text(json.dumps({'theme':theme}), encoding='utf-8')
        capture = ROOT / 'evidence' / f'packaged-native-{theme}.png'
        native_env = env.copy()
        native_env['QT_QPA_PLATFORM'] = 'windows' if os.name == 'nt' else 'offscreen'
        run = subprocess.run([str(destination / exe.name),'--demo','--smoke-screenshot',str(capture)],
            cwd=cwd, env=native_env, timeout=45, capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        with Image.open(capture) as bitmap:
            sidebar_pixel = bitmap.convert('RGB').getpixel((5,5))
        expected = (234,240,247) if theme=='light' else (16,22,33)
        theme_runs.append(dict(saved_theme=theme,exit_code=run.returncode,screenshot=str(capture),
                               sidebar_pixel=sidebar_pixel,expected_pixel=expected,
                               restored_correct_theme=sidebar_pixel==expected))
    native = dict(platform='native Windows Qt platform' if os.name=='nt' else 'offscreen',
                  exe_sha256=sha, theme_runs=theme_runs, physical_serial=False, demo=True)
    (ROOT/'evidence/native-smoke.json').write_text(json.dumps(native,ensure_ascii=False,indent=2),encoding='utf-8')
    # Validate the relocated data using the same frozen core. These are local
    # fixture statuses, never presented as hardware replies or GUI board state.
    sys.path.insert(0, str(ROOT / 'legacy/tools/console'))
    from protocol import BoardStatus
    from local_preview import LocalPreview
    resources = destination / '_internal'
    loader = LocalPreview(resources / 'legacy/tools/bmp/output_bmp/catalog', resources / 'legacy/assets/catalog_manifest.json')
    images = []
    for page in range(1, 9):
        preview = loader.load(BoardStatus(page,8,False,True,0,0,frozenset('Q')))
        images.append({'page':page, 'valid':preview.image is not None, 'message':preview.message})
    report = dict(scope='Same-machine relocation, Chinese/space path, unrelated cwd. No physical serial; not a clean-OS or hardware acceptance.',
        exe_sha256=sha, relocated_to=str(destination), cwd=str(cwd), exit_code=result.returncode,
        screenshot=str(screenshot), screenshot_created=screenshot.is_file(),
        stdout=result.stdout.decode('utf-8','replace'),stderr=result.stderr.decode('utf-8','replace'),assets=images,
        native_theme_restart_runs=theme_runs)
    (ROOT / 'evidence/release-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('assets','stdout','stderr')},ensure_ascii=False,indent=2))
    return int(result.returncode!=0 or not screenshot.is_file() or not all(i['valid'] for i in images)
               or not all(r['exit_code']==0 and r['restored_correct_theme'] for r in theme_runs))

if __name__=='__main__':
    raise SystemExit(main())
