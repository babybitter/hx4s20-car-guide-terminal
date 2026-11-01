"""16-bit PCM <-> unsigned G.711 mu-law bytes, Python standard library only."""
import array
import math
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 16000


def encode_sample(sample):
    if not -32768 <= sample <= 32767:
        raise ValueError('PCM must be signed 16 bit')
    # Arithmetic shift, 14-bit G.711 reference quantization (including negatives).
    value = sample >> 2
    mask = 0xFF if value >= 0 else 0x7F
    value = min(abs(value), 8159) + 33
    segment = max(0, value.bit_length() - 6)
    if segment >= 8:
        return 0x7F ^ mask
    return ((segment << 4) | ((value >> (segment + 1)) & 15)) ^ mask


def decode_sample(code):
    if not 0 <= code <= 255:
        raise ValueError('mu-law code must be an unsigned byte')
    value = code ^ 0xFF
    magnitude = (((value & 15) << 3) + 132) << ((value >> 4) & 7)
    return 132 - magnitude if value & 128 else magnitude - 132


DECODE_TABLE = tuple(decode_sample(i) for i in range(256))


def encode(samples):
    return bytes(encode_sample(int(s)) for s in samples)


def decode(data):
    return array.array('h', (DECODE_TABLE[b] for b in data))


def pcm_bytes(samples):
    values = array.array('h', samples)
    if sys.byteorder != 'little':
        values.byteswap()
    return values.tobytes()


def read_wav(path):
    with wave.open(str(path), 'rb') as src:
        if (src.getnchannels(), src.getsampwidth(), src.getframerate(), src.getcomptype()) != (1, 2, SAMPLE_RATE, 'NONE'):
            raise ValueError(f'Expected 16kHz / 16bit / mono PCM WAV: {path}')
        raw = src.readframes(src.getnframes())
        if len(raw) != src.getnframes() * 2:
            raise ValueError('Truncated WAV')
    samples = array.array('h')
    samples.frombytes(raw)
    if sys.byteorder != 'little':
        samples.byteswap()
    return samples


def write_wav(path, samples):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as dst:
        dst.setnchannels(1)
        dst.setsampwidth(2)
        dst.setframerate(SAMPLE_RATE)
        dst.writeframes(pcm_bytes(samples))


def dbfs(value):
    return 20 * math.log10(value / 32768) if value else -120.0


def statistics(samples):
    if not samples:
        raise ValueError('Empty audio')
    peak = max(abs(s) for s in samples)
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    return {'sample_count': len(samples), 'seconds': round(len(samples) / SAMPLE_RATE, 6),
            'peak': peak, 'peak_dbfs': round(dbfs(peak), 3), 'rms_dbfs': round(dbfs(rms), 3),
            'dc_mean': round(sum(samples) / len(samples), 4),
            'clip_count': sum(s <= -32768 or s >= 32767 for s in samples)}
