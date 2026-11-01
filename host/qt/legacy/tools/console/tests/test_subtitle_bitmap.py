from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from subtitle_bitmap import (Bitmap, normalize_text, render_text, preview_image,
    crc16, upload_frames, parse_subtitle_status, UploadClient, UploadError,
    default_font, SerialLink, FOREGROUND, UNDERLINE)
from protocol import line_command, parse_hardware, Session

CAP = 'Q P=001 C=004 A=0 READY=1 ERR=0 R=1 VER=1 CAP=NAMPIBCFTVWRESQHXZDGUJKOY'


class FakeBoard:
    def __init__(self, *, no_apply=False, bad_crc=False, stale_version=False, drop_chunk=False):
        self.active_tag = self.active_crc = self.tag = self.version = self.count = self.flags = self.error = 0
        self.data = bytearray()
        self.frames = []
        self.apply_polls = 0
        self.no_apply, self.bad_crc, self.stale_version, self.drop_chunk = no_apply, bad_crc, stale_version, drop_chunk

    def snapshot(self):
        return f'O SB={self.active_tag:04X}{self.active_crc:04X}{self.tag:04X}{self.version:04X}{self.count:02X}{self.flags:X}{self.error:X}'

    def exchange(self, frame):
        self.frames.append(frame)
        assert frame.endswith(b'\r\n') and all(32 <= b <= 126 for b in frame[:-2])
        text = frame[:-2].decode('ascii')
        if text == 'Q': return CAP
        if text == 'OQ':
            if self.flags & 2:
                self.apply_polls += 1
                if self.apply_polls >= 2 and not self.no_apply:
                    self.active_tag, self.active_crc = self.tag, self.expected_crc
                    if not self.stale_version: self.version = (self.version + 1) & 0xffff
                    self.flags = 4
            return self.snapshot()
        if text.startswith('OB'):
            self.tag = int(text[2:6], 16)
            self.expected_crc = int(text[10:14], 16)
            self.lengths = bytes.fromhex(text[6:10])
            self.data.clear()
            self.count, self.error, self.flags = 0, 0, (self.flags & 4) | 1
        elif text.startswith('OD'):
            if not (self.drop_chunk and int(text[2:4], 16) == 79):
                self.data.extend(bytes.fromhex(text[4:]))
                self.count += 1
        elif text.startswith('OC'):
            if self.count != 80: self.error = 5
            elif crc16(self.lengths + self.data) != self.expected_crc or self.bad_crc: self.error = 4
            else: self.flags = (self.flags & 4) | 2
        elif text == 'OX': self.count, self.error, self.flags = 0, 0, self.flags & 4
        else: raise AssertionError(text)
        return 'ACK O'


class TextTests(unittest.TestCase):
    def test_control_normalization_and_character_count(self):
        self.assertEqual(normalize_text('中文\tA\r\n下一站'), '中文 A 下一站')
        self.assertEqual(normalize_text('中'*20+'\n'+'文'*19), '中'*20+' '+'文'*19)
        self.assertEqual(normalize_text('\r\n\r\n\n\r'), '    ')
        self.assertEqual(normalize_text('a\nb\nc'), 'a b c')
        for bad in ('\x1b[2J', '\0', 'a\x7fb', '\x85', '\u2028', '\u200b',
                    '\u202e', '\ud800', '\ufeff', '中'*41, '中'*20+'\n'+'文'*20):
            with self.subTest(text=repr(bad)), self.assertRaises(ValueError): normalize_text(bad)

    def test_arbitrary_common_chinese_uses_windows_font(self):
        text = '龟鹤鹦鹉鹭鹰鳞鲸鲨鲤龚龛龠黛黔黯麓麟黎黏歡迎乘坐上海地鐵下一站人民廣場'
        bitmap = render_text(text)
        self.assertEqual(len(bitmap.data), 1280)
        self.assertEqual(bitmap.lengths, (35, 0))
        for index in range(sum(bitmap.lengths)):
            self.assertTrue(any(bitmap.data[index*32:index*32+32]), index)
        self.assertFalse(any(bitmap.data[sum(bitmap.lengths)*32:]))
        self.assertEqual(preview_image(bitmap).size, (640, 36))

    def test_missing_glyph_rejected_instead_of_tofu(self):
        with self.assertRaisesRegex(ValueError, '字体缺字'): render_text('中', 'C:/Windows/Fonts/arial.ttf')

    def test_bitmap_packing_and_padding(self):
        image = render_text('中 文')
        self.assertEqual(image, render_text('中\r\n文'))
        self.assertEqual(image, render_text('中\n文'))
        self.assertEqual(image, render_text('中\r文'))
        self.assertEqual(render_text('中\t文'), render_text('中 文'))
        preview = preview_image(image)
        for cell in range(3):
            for y in range(21):
                sy = y*16//21
                word = int.from_bytes(image.data[cell*32+sy*2:cell*32+sy*2+2], 'big')
                for x in range(21):
                    self.assertEqual(preview.getpixel((16+cell*21+x, 7+y)) == FOREGROUND,
                                     bool(word & (1 << (15-x*16//21))))
        self.assertEqual(render_text('').data, bytes(1280))
        with self.assertRaises(ValueError): Bitmap('', (0, 0), b'\xff'*1280)
        with self.assertRaises(ValueError): Bitmap('', (41, 0), bytes(1280))
        with self.assertRaisesRegex(ValueError, 'len1'): Bitmap('中\n文', (1, 1), bytes(1280))

    def test_style_clipping_empty_text_and_complete_scroll_cycle(self):
        bitmap = Bitmap('中', (1, 0), b'\xff'*32+bytes(1248))
        base, shadow = (103, 151, 207), (51, 75, 103)
        image = preview_image(bitmap, background=base)
        for y in range(36):
            for x in range(640):
                expected = base
                if 18 <= x < 39 and 9 <= y < 30: expected = shadow
                if 16 <= x < 37 and 7 <= y < 28: expected = FOREGROUND
                if 16 <= x < 624 and y >= 34: expected = UNDERLINE
                self.assertEqual(image.getpixel((x, y)), expected, (x, y))
        empty = preview_image(render_text(''), background=base)
        self.assertEqual(preview_image(bitmap, 0, base), empty)
        self.assertEqual(preview_image(bitmap, 661, base), empty)
        self.assertEqual(preview_image(bitmap, 1, base).getpixel((623, 7)), FOREGROUND)
        self.assertEqual(preview_image(bitmap, 629, base).getpixel((16, 9)), shadow)
        self.assertEqual(preview_image(bitmap, 631, base), empty)
        long = Bitmap('中'*40, (40, 0), b'\xff'*1280)
        self.assertEqual(preview_image(long, 1448, base).getpixel((16, 7)), base)
        self.assertEqual(preview_image(long, 1447, base).getpixel((16, 7)), FOREGROUND)
        self.assertEqual(preview_image(long, 1480, base), empty)
        self.assertEqual(len(upload_frames(long, 0)), 82)

    def test_crc_and_wire_never_contain_text_controls(self):
        self.assertEqual(crc16(b'123456789'), 0x29b1)
        bitmap = render_text('行一\r\n行二\t空格')
        frames = upload_frames(bitmap, 0xabcd)
        self.assertEqual(len(frames), 82)
        self.assertEqual(frames[0], f'OBABCD0800{bitmap.crc:04X}\r\n'.encode())
        self.assertEqual(frames[-1], b'OCABCD\r\n')
        for frame in frames:
            self.assertTrue(frame.endswith(b'\r\n'))
            self.assertLessEqual(len(frame)-2, 42)
            self.assertTrue(all(32 <= b <= 126 for b in frame[:-2]))
        assembled = b''.join(bytes.fromhex(f[4:-2].decode()) for f in frames[1:-1])
        self.assertEqual(assembled, bitmap.data)

    def test_crc_covers_length_not_only_bitmap(self):
        data = bytes(1280)
        one = Bitmap('', (0, 0), data)
        two = Bitmap(' ', (1, 0), data)
        self.assertNotEqual(one.crc, two.crc)

    def test_legacy_ascii_unchanged(self):
        self.assertEqual(line_command('S:Hello'), b'S:Hello\r\n')
        for bad in ('S:中文', 'S:a\nb', 'S:a\tb', 'S:a\r\nb', 'S:a\x00b'):
            with self.assertRaises(ValueError): line_command(bad)


class UploadTests(unittest.TestCase):
    def client(self, board):
        self.ticks = 0.0
        def clock():
            self.ticks += .01
            return self.ticks
        return UploadClient(board.exchange, timeout=.15, clock=clock, sleep=lambda _: None)

    def test_only_applied_state_confirms_success(self):
        board = FakeBoard()
        result = self.client(board).upload(render_text('中文'))
        self.assertEqual(result.version, 1)
        self.assertEqual(result.count, 80)
        self.assertTrue(result.active)
        self.assertGreaterEqual(board.apply_polls, 2)
        self.assertEqual(board.frames.count(b'OC0001\r\n'), 1)

    def test_ack_never_counts_as_status(self):
        with self.assertRaises(ValueError): parse_subtitle_status('ACK O')
        for line in ('O SB='+'0'*19, 'O SB='+'0'*19+'a', 'O SB='+'0'*20+' extra'):
            with self.assertRaises(ValueError): parse_subtitle_status(line)

    def test_missing_blank_does_not_confirm_or_replay(self):
        board = FakeBoard(no_apply=True)
        with self.assertRaisesRegex(UploadError, '未确认blank'):
            self.client(board).upload(render_text('待提交'))
        self.assertEqual(board.frames.count(b'OC0001\r\n'), 1)

    def test_stale_version_is_not_applied(self):
        with self.assertRaisesRegex(UploadError, '未确认blank'):
            self.client(FakeBoard(stale_version=True)).upload(render_text('旧状态'))

    def test_crc_failure_and_missing_chunk(self):
        with self.assertRaisesRegex(UploadError, 'CRC'):
            self.client(FakeBoard(bad_crc=True)).upload(render_text('CRC'))
        board = FakeBoard(drop_chunk=True)
        with self.assertRaisesRegex(UploadError, '80块'): self.client(board).upload(render_text('缺块'))
        self.assertFalse(any(f.startswith(b'OC') for f in board.frames))

    def test_version_wrap_and_abort_preserve_display(self):
        board = FakeBoard()
        board.version, board.active_tag = 0xffff, 0xffff
        client = self.client(board)
        applied = client.upload(render_text('回绕'))
        self.assertEqual((applied.version, applied.active_tag), (0, 0))
        self.assertEqual(client.abort().active_crc, applied.active_crc)

    def test_capability_gate_and_ack_only_begin(self):
        def old(frame): return CAP.replace('OY', '')
        with self.assertRaisesRegex(UploadError, '未声明'): UploadClient(old).upload(render_text('中文'))
        board = FakeBoard()
        original = board.exchange
        def dropped_begin(frame):
            return 'ACK O' if frame.startswith(b'OB') else original(frame)
        with self.assertRaisesRegex(UploadError, 'OB仅获ACK'):
            UploadClient(dropped_begin).upload(render_text('中文'))


class HardwareTests(unittest.TestCase):
    @staticmethod
    def hardware(config):
        return f'H CFG={config:08X} EV=0000 SI=00000000 DM=00000000 LD=00000000 FF=00000000 CL=00000000 SQ=00000000'

    def test_new_fields_preserve_low24_and_h_wire(self):
        low = 0x00b38e69
        old = parse_hardware(self.hardware(low))
        for opacity in range(5):
            for fallback in (0, 1, 15, 31):
                h = self.hardware(low | opacity << 24 | fallback << 27)
                self.assertEqual(len(h)+2, 96)
                actual = parse_hardware(h)
                self.assertEqual(actual.settings, old.settings)
                self.assertEqual(actual.wave_opacity, opacity)
                self.assertEqual(actual.fallback_count, fallback)

    def test_y_limits_caps_and_ack_not_actual(self):
        session = Session('effects')
        session.begin('Q', 0); session.receive(CAP)
        session.begin('H', 0); session.receive(self.hardware(1 << 24))
        session.begin('Y4', 0); session.receive('ACK Y')
        self.assertEqual(session.hardware.wave_opacity, 1)
        session.begin('H', 0); session.receive(self.hardware(4 << 24 | 31 << 27))
        self.assertEqual(session.hardware.wave_opacity, 4)
        self.assertEqual(session.hardware.fallback_count, 31)
        for level in range(5): self.assertEqual(line_command(f'Y{level}'), f'Y{level}\r\n'.encode())
        for bad in ('Y5', 'Y-1', 'Y00', 'Y4\n'):
            with self.assertRaises(ValueError): line_command(bad)
        session.reset(); session.begin('Q', 0); session.receive(CAP.replace('OY',''))
        self.assertFalse(session.allowed('Y'))


if __name__ == '__main__':
    unittest.main()
