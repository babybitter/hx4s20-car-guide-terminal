"""Flat audio data only. Offsets and CRC live in trusted build-side metadata/ROM."""
import hashlib
import struct
import zlib

ALIGNMENT = 512
LIMIT = 2 * 1024 * 1024  # Exclusive, every address fits 21 bits.
SLOTS = 32


def aligned(length):
    return (length + ALIGNMENT - 1) & -ALIGNMENT


def crc32(data):
    return f'{zlib.crc32(data) & 0xFFFFFFFF:08X}'


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def pack(clips):
    """clips is {id: nonempty bytes}; missing ID is (0, 0), including offset zero validity."""
    if not clips or any(type(i) is not int or not 0 <= i < SLOTS for i in clips):
        raise ValueError('Expected 1..32 clips with IDs 0..31')
    out = bytearray()
    slots = [{'id': i, 'byte_offset': 0, 'sample_count': 0, 'storage_bytes': 0} for i in range(SLOTS)]
    for clip_id, clip in sorted(clips.items()):
        if not isinstance(clip, bytes) or not clip:
            raise ValueError('Clip must be nonempty bytes')
        span = aligned(len(clip))
        if len(out) + span >= LIMIT:
            raise ValueError('AUDIO.BIN must be strictly smaller than 2MiB')
        slots[clip_id] = {'id': clip_id, 'byte_offset': len(out), 'sample_count': len(clip),
                          'storage_bytes': span, 'crc32': crc32(clip)}
        out.extend(clip)
        out.extend(b'\xff' * (span - len(clip)))
    payload = bytes(out)
    info = {'format': 's19-flat-mulaw-v1', 'filename': 'AUDIO.BIN', 'sample_rate': 16000,
            'channels': 1, 'bits_per_code': 8, 'codec': 'g711-mulaw', 'alignment': ALIGNMENT,
            'byte_count': len(payload), 'crc32': crc32(payload), 'sha256': sha256(payload),
            'active_mask': f'{sum(1 << i for i in clips):08X}', 'slots': slots}
    validate(payload, info)
    return payload, info


def validate(payload, info):
    if (info.get('format'), info.get('sample_rate'), info.get('channels'), info.get('bits_per_code'),
        info.get('codec'), info.get('alignment')) != ('s19-flat-mulaw-v1', 16000, 1, 8, 'g711-mulaw', ALIGNMENT):
        raise ValueError('Unsupported format')
    count = len(payload)
    if not 0 < count < LIMIT or count % ALIGNMENT or info.get('byte_count') != count:
        raise ValueError('Wrong precise file size or alignment')
    if info.get('crc32') != crc32(payload) or info.get('sha256') != sha256(payload):
        raise ValueError('Whole-file checksum mismatch')
    slots = info.get('slots')
    if not isinstance(slots, list) or len(slots) != SLOTS:
        raise ValueError('Exactly 32 ROM slots are required')
    cursor = 0
    mask = 0
    for i, slot in enumerate(slots):
        if slot.get('id') != i:
            raise ValueError('Slot ID/order mismatch')
        offset, length, span = (slot.get(k) for k in ('byte_offset', 'sample_count', 'storage_bytes'))
        if any(type(v) is not int or v < 0 or v >= LIMIT for v in (offset, length, span)):
            raise ValueError('Invalid offset/count/span')
        if length == 0:
            if offset or span:
                raise ValueError('Unused slot must be all-zero')
            continue
        if offset != cursor or offset % ALIGNMENT or span != aligned(length) or offset + span > count:
            raise ValueError('Out of bounds, overlapping, gapped or unaligned clip')
        if slot.get('crc32') != crc32(payload[offset:offset + length]):
            raise ValueError('Clip CRC mismatch')
        if payload[offset + length:offset + span] != b'\xff' * (span - length):
            raise ValueError('Padding must be mu-law silence 0xFF')
        mask |= 1 << i
        cursor = offset + span
    if cursor != count or info.get('active_mask') != f'{mask:08X}':
        raise ValueError('Trailing data or active mask mismatch')
    return True


def extract(payload, info, clip_id):
    validate(payload, info)
    if type(clip_id) is not int or not 0 <= clip_id < SLOTS:
        raise ValueError('ID outside 0..31')
    slot = info['slots'][clip_id]
    if not slot['sample_count']:
        raise ValueError('Reserved/empty ID')
    start = slot['byte_offset']
    return payload[start:start + slot['sample_count']]


def rom_words(info):
    return [value for slot in info['slots'] for value in (slot['byte_offset'], slot['sample_count'])]


def render_rom(info):
    words = rom_words(info)
    lines = [
        '// Generated from AUDIO.BIN; data only, no event logic. Do not edit.',
        '// Logical 64 x 32 = 2048 bits, stored as 128 x 16 with ONE read port.',
        '// addr={clip_id[4:0],field[1:0]}: offset lo/hi, sample count lo/hi.',
        '// q updates after the rising edge; caller must account for registered latency.',
        '// Narrow storage avoids two underfilled wide RAMs on the EG4 mapper.',
        'module audio_asset_rom (',
        '    input wire clk,',
        '    input wire [6:0] addr,',
        '    output reg [15:0] q,',
        '    output wire [31:0] package_bytes,',
        '    output wire [31:0] package_crc32,',
        '    output wire [31:0] active_mask',
        ');',
        f"    localparam [31:0] AUDIO_BYTES = 32'd{info['byte_count']};",
        f"    localparam [31:0] AUDIO_CRC32 = 32'h{info['crc32']};",
        f"    localparam [31:0] AUDIO_ACTIVE_MASK = 32'h{info['active_mask']};",
        '    assign package_bytes = AUDIO_BYTES;',
        '    assign package_crc32 = AUDIO_CRC32;',
        '    assign active_mask = AUDIO_ACTIVE_MASK;',
        '    (* ram_style = "block" *) reg [15:0] rom [0:127];',
        '    initial begin',
    ]
    for address, value in enumerate(words):
        lines.append(f"        rom[{address*2:3d}] = 16'h{value & 65535:04X}; // low half")
        lines.append(f"        rom[{address*2+1:3d}] = 16'h{value >> 16:04X}; // ID {address // 2:02d} {'count' if address & 1 else 'byte offset'}")
    lines += ['    end', '    always @(posedge clk) q <= rom[addr];', 'endmodule', '']
    return '\n'.join(lines)


def rom_bytes(info):
    return struct.pack('<64I', *rom_words(info))
