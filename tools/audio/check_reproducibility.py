"""Regenerate twice offline and compare exact audio/ROM/manifest bytes."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def snapshot():
    paths = [ROOT / name for name in ['AUDIO.BIN', 'audio_asset_rom.v', 'audio_asset_rom.hex',
                                      'package_manifest.json', 'mulaw_decode_16.hex']]
    for folder in ['raw_wav', 'pcm_wav', 'mulaw', 'decoded_wav', 'preview']:
        paths.extend(sorted((ROOT / folder).iterdir()))
    return {str(p.relative_to(ROOT)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file()}


def main():
    shell = shutil.which('powershell') or shutil.which('pwsh')
    if not shell:
        raise RuntimeError('A local PowerShell with System.Speech is required')
    env = os.environ.copy()
    env['PYTHONIOENCODING'] = 'utf-8'
    snapshots = []
    for number in [1, 2]:
        logs = []
        commands = [[shell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(ROOT / 'generate_tts.ps1')],
                    [sys.executable, '-B', str(ROOT / 'build_assets.py'), 'build']]
        for command in commands:
            run = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=60)
            logs.append(run.stdout.decode('utf-8', errors='replace') + run.stderr.decode('utf-8', errors='replace'))
            if run.returncode:
                raise RuntimeError(f'Rebuild failed: {command}\n{logs[-1]}')
        (ROOT / 'reports' / f'rebuild_{number}.log').write_text('\n'.join(logs), encoding='utf-8')
        snapshots.append(snapshot())
        print(f'Offline rebuild {number}: {len(snapshots[-1])} files hashed', flush=True)
    changed = [name for name in sorted(set(snapshots[0]) | set(snapshots[1]))
               if snapshots[0].get(name) != snapshots[1].get(name)]
    report = {'method': 'Two complete offline System.Speech + Python rebuilds on this machine',
              'powershell': shell, 'python': sys.version, 'files_compared': len(snapshots[1]),
              'identical': not changed, 'changed': changed, 'sha256': snapshots[1],
              'scope': 'Same installed voice/runtime; other voice versions may change output'}
    (ROOT / 'reports' / 'reproducibility.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    if changed:
        raise RuntimeError(f'Non-reproducible files: {changed}')
    print('PASS: exact bytes match for TTS, WAV, mu-law, AUDIO.BIN, ROM and package manifest')


if __name__ == '__main__':
    main()
