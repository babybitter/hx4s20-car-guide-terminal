"""Create negative-test copies on the PC only. Never accesses TF or Flash."""
from pathlib import Path
import hashlib,json

ROOT=Path(__file__).resolve().parent

def make():
    data=(ROOT/'AUDIO.BIN').read_bytes()
    meta=json.loads((ROOT/'package_manifest.json').read_text(encoding='utf-8'))
    if hashlib.sha256(data).hexdigest()!=meta['sha256']:
        raise ValueError('Source AUDIO.BIN differs from the package manifest')
    variants={'length':data[:-512], 'crc':bytes([data[0]^1])+data[1:]}
    for kind,content in variants.items():
        dest=ROOT/'test_variants'/kind/'AUDIO.BIN'
        dest.parent.mkdir(parents=True,exist_ok=True)
        if dest.exists() and dest.read_bytes()!=content:
            raise FileExistsError('Refusing to replace a different existing test file: '+str(dest))
        dest.write_bytes(content)
        print(kind,len(content),hashlib.sha256(content).hexdigest(),dest)
    print('PC copies only; original AUDIO.BIN untouched. Restore the correct pack after each hardware test.')

if __name__=='__main__':make()
