"""Offline preview/frame export by default; hardware requires explicit --port."""
import argparse
from pathlib import Path
from subtitle_bitmap import render_text, preview_image, upload_frames, SerialLink, UploadClient


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--text')
    source.add_argument('--text-file', type=Path, help='UTF-8 text, max40 chars/two lines')
    parser.add_argument('--font', help='Windows TTF/TTC/OTF, default Microsoft YaHei')
    parser.add_argument('--preview', type=Path, help='Write exact payload preview PNG')
    parser.add_argument('--frames', type=Path, help='Write ASCII upload frames, token1234; NOT an upload confirmation')
    parser.add_argument('--port', help='Explicit hardware upload, e.g. COM3; no automatic retry')
    args = parser.parse_args()
    text = args.text
    if args.text_file:
        # Preserve CR before validating: universal newline decoding would hide
        # unsupported lone-CR characters.
        text = args.text_file.read_bytes().decode('utf-8-sig')
    bitmap = render_text(text, args.font)
    if args.preview: preview_image(bitmap).save(args.preview)
    if args.frames: args.frames.write_bytes(b''.join(upload_frames(bitmap, 0x1234)))
    print(f'lengths={bitmap.lengths} bytes={len(bitmap.data)} CRC16={bitmap.crc:04X}')
    if args.port:
        with SerialLink(args.port) as link:
            state = UploadClient(link.exchange).upload(bitmap)
        print(f'APPLIED token={state.active_tag:04X} CRC={state.active_crc:04X} version={state.version:04X}')
    else:
        print('OFFLINE: no hardware opened; frames are not evidence of application')


if __name__ == '__main__': main()
