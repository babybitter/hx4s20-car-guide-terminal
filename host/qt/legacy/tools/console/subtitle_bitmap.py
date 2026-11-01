"""Host-rendered 40-cell subtitles and verified O-family upload.

No serial devices are opened on import. Pillow and fontTools are only required
for render_text(); pyserial is only required by SerialLink's explicit open.
"""
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
import binascii
import re
import time
import unicodedata

from protocol import line_command, parse_status

CELL = 16
DISPLAY_CELL = 21
VIEW_WIDTH = 608
SCROLL_GAP = 32
FOREGROUND = (0xE5, 0xE7, 0xEB)
UNDERLINE = (0x36, 0xD5, 0xE3)
CELLS = 40
PAYLOAD_BYTES = 1280
CHUNK_BYTES = 16
CHUNKS = 80
ERRORS = {1: 'busy', 2: 'no begin', 3: 'chunk order', 4: 'CRC',
          5: 'chunk count', 6: 'token', 7: 'range'}


def normalize_text(text):
    if not isinstance(text, str):
        raise ValueError('字幕必须是文本')
    text = text.replace('\r\n', ' ').replace('\r', ' ').replace('\n', ' ').replace('\t', ' ')
    for ch in text:
        if (unicodedata.category(ch).startswith('C') or
                unicodedata.category(ch) in ('Zl', 'Zp')):
            raise ValueError(f'拒绝未定义控制/格式字符 U+{ord(ch):04X}')
    if len(text) > CELLS:
        raise ValueError('单行字幕最多40个字符（空格及换行转换的空格均计数）')
    return text


def crc16(data):
    return binascii.crc_hqx(data, 0xffff)


@dataclass(frozen=True)
class Bitmap:
    text: str
    lengths: tuple
    data: bytes

    def __post_init__(self):
        if (len(self.lengths) != 2 or any(type(n) is not int or not 0 <= n <= 40 for n in self.lengths)
                or self.lengths[1] != 0 or not isinstance(self.data, bytes)
                or len(self.data) != PAYLOAD_BYTES):
            raise ValueError('位图必须为40格/1280字节，单行最多40字符，len1必须为0')
        if any(self.data[sum(self.lengths) * 32:]):
            raise ValueError('未使用的字格必须全零')

    @property
    def crc(self):
        return crc16(bytes(self.lengths) + self.data)


def default_font():
    for name in ('C:/Windows/Fonts/msyh.ttc', 'C:/Windows/Fonts/simsun.ttc',
                 'C:/Windows/Fonts/simhei.ttf'):
        if Path(name).is_file():
            return name
    raise ValueError('找不到Windows中文字体，请显式选择TTF/TTC/OTF字体文件')


@lru_cache(maxsize=8)
def font_coverage(path, index):
    from fontTools.ttLib import TTFont
    with TTFont(path, fontNumber=index, lazy=True) as font:
        return frozenset(font.getBestCmap() or {})


def render_text(text, font_path=None, font_index=0):
    from PIL import Image, ImageDraw, ImageFont
    text = normalize_text(text)
    lines = (text, '')
    font_path = str(Path(font_path or default_font()).resolve())
    coverage = font_coverage(font_path, font_index)
    missing = sorted({ch for ch in ''.join(lines) if ord(ch) not in coverage})
    if missing:
        raise ValueError('字体缺字，拒绝替换为方框：' + ' '.join(f'{ch}(U+{ord(ch):04X})' for ch in missing))
    font = ImageFont.truetype(font_path, CELL, index=font_index)
    data = bytearray(PAYLOAD_BYTES)
    slot = 0
    for line in lines:
        for char in line:
            left, top, right, bottom = font.getbbox(char)
            width, height = right - left, bottom - top
            glyph = Image.new('L', (max(1, width), max(1, height)))
            ImageDraw.Draw(glyph).text((-left, -top), char, font=font, fill=255)
            if width > CELL or height > CELL:
                glyph.thumbnail((CELL, CELL), Image.Resampling.LANCZOS)
            cell = Image.new('L', (CELL, CELL))
            cell.paste(glyph, ((CELL-glyph.width)//2, (CELL-glyph.height)//2))
            for y in range(CELL):
                word = 0
                for x in range(CELL):
                    word = (word << 1) | (cell.getpixel((x, y)) >= 96)
                data[slot * 32 + y * 2:slot * 32 + y * 2 + 2] = word.to_bytes(2, 'big')
            slot += 1
    return Bitmap(text, tuple(map(len, lines)), bytes(data))


def preview_image(bitmap, scroll_pixels=None, background=(32, 40, 52)):
    """640x36 subtitle band (screen y399..434), matching RTL pixel for pixel.

    Screen glyph y406..426, shadow y408..428, cyan underline y433..434.

    The wire bitmap remains 16x16; floor(p*16/21) expands each display cell.
    Default is a static frame with the first cell at x16. Explicit scroll
    starts offscreen right at 0 and wraps only after the complete text exits.
    """
    from PIL import Image
    image = Image.new('RGB', (640, 36), background)
    width = bitmap.lengths[0] * DISPLAY_CELL
    scroll = (VIEW_WIDTH if scroll_pixels is None else scroll_pixels) % (VIEW_WIDTH + width + SCROLL_GAP)
    words = [int.from_bytes(bitmap.data[i:i+2], 'big') for i in range(0, PAYLOAD_BYTES, 2)]

    def ink(sx, sy):
        if not 0 <= sx < width or not 0 <= sy < DISPLAY_CELL:
            return False
        cell, col = divmod(sx, DISPLAY_CELL)
        row, bit = sy * CELL // DISPLAY_CELL, col * CELL // DISPLAY_CELL
        return bool(words[cell*CELL+row] & (1 << (15-bit)))

    shadow = tuple(c >> 1 for c in background)
    for y in range(7, 30):
        for x in range(16, 624):
            sx = x + scroll - 624
            if ink(sx-2, y-9):
                image.putpixel((x, y), shadow)
            if ink(sx, y-7):
                image.putpixel((x, y), FOREGROUND)
    for y in (34, 35):
        for x in range(16, 624):
            image.putpixel((x, y), UNDERLINE)
    return image


def upload_frames(bitmap, token):
    if type(token) is not int or not 0 <= token <= 0xffff:
        raise ValueError('token必须为16位无符号整数')
    a, b = bitmap.lengths
    frames = [f'OB{token:04X}{a:02X}{b:02X}{bitmap.crc:04X}']
    frames.extend(f'OD{i:02X}' + bitmap.data[i*16:i*16+16].hex().upper() for i in range(CHUNKS))
    frames.append(f'OC{token:04X}')
    return [frame.encode('ascii') + b'\r\n' for frame in frames]


@dataclass(frozen=True)
class SubtitleStatus:
    active_tag: int
    active_crc: int
    upload_tag: int
    version: int
    count: int
    flags: int
    error: int

    @property
    def upload_open(self): return bool(self.flags & 1)
    @property
    def pending(self): return bool(self.flags & 2)
    @property
    def active(self): return bool(self.flags & 4)
    @property
    def busy(self): return bool(self.flags & 8)


def parse_subtitle_status(line):
    match = re.fullmatch(r'O SB=([0-9A-F]{20})', line.removesuffix('\r\n'))
    if not match:
        raise ValueError('字幕状态回复无效（ACK不代表已应用）')
    h = match[1]
    values = [int(h[a:b], 16) for a, b in ((0, 4), (4, 8), (8, 12), (12, 16), (16, 18), (18, 19), (19, 20))]
    if values[4] > 80 or values[6] > 7:
        raise ValueError('字幕状态字段超出定义范围')
    return SubtitleStatus(*values)


class UploadError(RuntimeError):
    pass


class UploadClient:
    """exchange(bytes)->one reply str; one outstanding request, no auto-replay."""
    def __init__(self, exchange, timeout=3.0, clock=time.monotonic, sleep=time.sleep):
        self.exchange, self.timeout, self.clock, self.sleep = exchange, timeout, clock, sleep

    def status(self):
        return parse_subtitle_status(self.exchange(b'OQ\r\n'))

    def ack(self, frame):
        line = self.exchange(frame).removesuffix('\r\n')
        if line != 'ACK O':
            raise UploadError(f'上传命令被拒绝：{line}')

    @staticmethod
    def check(status):
        if status.error:
            raise UploadError(f'板端拒绝字幕：{ERRORS[status.error]}')

    def upload(self, bitmap, progress=lambda value: None):
        caps = parse_status(self.exchange(b'Q\r\n'))
        if caps is None or 'O' not in caps.capabilities:
            raise UploadError('板端未声明O位图字幕能力；旧S:仅支持可打印ASCII')
        before = self.status()
        if before.pending or before.busy:
            raise UploadError('板端仍在处理上一字幕，请等待或显式终止')
        token = (before.active_tag + 1) & 0xffff
        frames = upload_frames(bitmap, token)
        self.ack(frames[0])
        started = self.status()
        self.check(started)
        if (started.upload_tag != token or started.count or not started.upload_open
                or started.pending or started.busy or started.version != before.version):
            raise UploadError('OB仅获ACK，板端未确认新上传事务')
        for i, frame in enumerate(frames[1:-1]):
            self.ack(frame)
            progress(i + 1)
        received = self.status()
        self.check(received)
        if (received.upload_tag != token or received.count != CHUNKS or received.busy
                or received.pending or not received.upload_open):
            raise UploadError('板端未确认全部80块；不提交')
        self.ack(frames[-1])
        deadline = self.clock() + self.timeout
        while self.clock() < deadline:
            applied = self.status()
            self.check(applied)
            if (applied.active and not applied.pending and not applied.busy and not applied.upload_open
                    and applied.active_tag == token and applied.active_crc == bitmap.crc
                    and applied.version == ((before.version + 1) & 0xffff) and applied.count == CHUNKS):
                return applied
            self.sleep(0.02)
        raise UploadError('已发送提交，但未确认blank应用；请查询状态，不自动重发')

    def abort(self):
        self.ack(b'OX\r\n')
        state = self.status()
        self.check(state)
        if state.busy or state.pending or state.upload_open or state.count:
            raise UploadError('终止尚未确认')
        return state


class SerialLink:
    def __init__(self, port):
        import serial
        self.port = serial.Serial(port, 115200, timeout=1.5, write_timeout=1.5)

    def __enter__(self):
        # Let any stale partial line expire before issuing a delimiter. Never
        # finish a previous user's partial command by appending the initial Q.
        saved_timeout = self.port.timeout
        self.port.timeout = 0
        try:
            for delimiter in (False, True):
                if delimiter and self.port.write(b'\r\n') != 2:
                    raise UploadError('同步分隔符写入不完整')
                deadline, quiet = time.monotonic()+3.0, time.monotonic()+0.2
                while time.monotonic() < quiet:
                    if time.monotonic() >= deadline:
                        raise UploadError('串口持续有旧数据，无法同步')
                    if self.port.read(512):
                        quiet = time.monotonic()+0.2
                    time.sleep(0.01)
        except Exception:
            self.port.close()
            raise
        finally:
            if self.port.is_open:
                self.port.timeout = saved_timeout
        return self
    def __exit__(self, *args): self.port.close()

    def exchange(self, frame):
        if not frame.endswith(b'\r\n') or any(b < 32 or b > 126 for b in frame[:-2]) or len(frame) > 44:
            raise ValueError('拒绝非ASCII、内部控制字符或超长串口帧')
        if self.port.write(frame) != len(frame):
            raise UploadError('串口未完整写入')
        self.port.flush()
        data = self.port.read_until(b'\n', 161)
        if not data.endswith(b'\r\n') or len(data) > 160:
            raise UploadError('串口回复超时或帧无效；不自动重发')
        try:
            return data[:-2].decode('ascii')
        except UnicodeDecodeError as exc:
            raise UploadError('串口回复不是ASCII') from exc
