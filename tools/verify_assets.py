"""Read-only verification of the fixed BMP profile used by this project."""

import argparse
import hashlib
from pathlib import Path
import struct
import sys


WIDTH = 640
HEIGHT = 480
PIXEL_BYTES = WIDTH * HEIGHT * 3
FILE_BYTES = 54 + PIXEL_BYTES


def validate_bmp(path: Path) -> dict[str, str | int]:
    length = path.stat().st_size
    if length != FILE_BYTES:
        raise ValueError(f"length {length} != {FILE_BYTES}")

    with path.open("rb") as stream:
        header = stream.read(54)
        if len(header) != 54:
            raise ValueError("truncated BMP header")
        magic, file_size, reserved1, reserved2, offset = struct.unpack_from(
            "<2sIHHI", header
        )
        dib_size, width, height, planes, bpp, compression, image_size = (
            struct.unpack_from("<IiiHHII", header, 14)
        )
        checks = (
            (magic == b"BM", "signature"),
            (file_size == length, "declared file size"),
            (reserved1 == 0 and reserved2 == 0, "reserved fields"),
            (dib_size == 40, "DIB header size"),
            (width == WIDTH and height == HEIGHT, "dimensions/bottom-up order"),
            (planes == 1, "planes"),
            (bpp == 24, "bit depth"),
            (compression == 0, "compression"),
            (offset == 54, "pixel offset"),
            (image_size in (0, PIXEL_BYTES), "declared image size"),
        )
        for condition, field in checks:
            if not condition:
                raise ValueError(f"invalid {field}")
        if offset + PIXEL_BYTES != length:
            raise ValueError("pixel data extent")
        digest = hashlib.sha256()
        digest.update(header)
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)

    return {
        "width": width,
        "height": height,
        "bpp": bpp,
        "pixel_offset": offset,
        "file_size": length,
        "file_sha256": digest.hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    failed = False
    for path in args.files:
        try:
            details = validate_bmp(path)
            print(f"PASS {path}: {details['file_sha256']}")
        except (OSError, ValueError) as error:
            failed = True
            print(f"FAIL {path}: {error}", file=sys.stderr)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
