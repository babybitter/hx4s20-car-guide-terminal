"""Atomic UART Q/H plus independently probed S19 AQ; no I/O dependencies."""
from dataclasses import dataclass
import re

BAUD_RATE = 115200
MAX_SUBTITLE_LENGTH = 40
COMMANDS = frozenset("NAMPIBCFTVWRESQ")
V2_COMMANDS = frozenset("HXZDGUJK")
S18_COMMANDS = frozenset("Y")
PROFILES = {"control": frozenset("NAMPIRQH"), "effects": COMMANDS | V2_COMMANDS | S18_COMMANDS}
LIMITS = {"B": 3, "C": 3, "F": 5, "T": 3, "V": 4, "W": 1, "R": 3, "E": 1}
V2_LIMITS = {"X": 3, "Z": 1, "D": 1, "G": 1, "Y": 4}
ALL_LIMITS = LIMITS | V2_LIMITS
PERIODS = (2, 5, 10, 15)
DEMO_PERIODS = (1.5, 3, 5, 8)
FEATURE_AUDIO = 0x01
FEATURE_DEMO_PERIODS = 0x02
FEATURE_MENU_BOOT = 0x04
FEATURE_ZOOM_OUT = 0x08
FEATURE_BANDS = 0x10
_AUDIO = re.compile(r"A,([0-9A-Fa-f]{20})")
_STATUS = re.compile(r"Q P=([0-9]{3}) C=([0-9]{3}) A=([01]) READY=([01]) "
                     r"ERR=([0-9A-F]) R=([0-3]) VER=1 CAP=([A-Z]+)")
_HARDWARE = re.compile(r"H CFG=([0-9A-F]{8}) EV=([0-9A-F]{4}) "
    r"SI=([0-9A-F]{8}) DM=([0-9A-F]{8}) LD=([0-9A-F]{8}) "
    r"FF=([0-9A-F]{8}) CL=([0-9A-F]{8}) SQ=([0-9A-F]{8})")

@dataclass(frozen=True)
class BoardStatus:
    page: int
    count: int
    auto: bool
    ready: bool
    error: int
    period: int
    capabilities: frozenset


@dataclass(frozen=True)
class AudioStatus:
    version: int
    features: int
    clip_id: int
    assets_ready: bool
    busy: bool
    music: bool
    mute: bool
    mode: int
    pending: bool
    stream_fault: bool
    loader_fault: int
    zoom_mode: int
    player_fault: int
    underruns: int
    event_seq: int
    position_ms: int

    def has(self, feature):
        return bool(self.features & feature)

    @property
    def load_error(self):
        """Compatibility name used by the first S19 console candidate."""
        return self.loader_fault


def parse_audio(line):
    """Accept a bare framed line or exactly one CRLF; never strip garbage."""
    if not isinstance(line, str):
        return None
    match = _AUDIO.fullmatch(line.removesuffix("\r\n"))
    if not match:
        return None
    value = int(match[1], 16)
    version, features, clip, flags, detail, underruns = (
        (value >> shift) & 255 for shift in (72, 64, 56, 48, 40, 32))
    busy = bool(flags & 0x40)
    if version != 1 or (busy and clip not in (*range(26), 31)) or (not busy and clip != 255):
        return None
    loader_fault = detail >> 4
    zoom_mode = (detail >> 2) & 3
    if loader_fault > 6 or zoom_mode > 2 or detail & 2:
        return None
    return AudioStatus(version, features, clip, bool(flags & 0x80), busy,
        bool(flags & 0x20), bool(flags & 0x10), (flags >> 2) & 3,
        bool(flags & 2), bool(flags & 1), loader_fault, zoom_mode, detail & 1,
        underruns, (value >> 16) & 65535, value & 65535)

@dataclass(frozen=True)
class HardwareStatus:
    config: int
    event_seq: int
    sd_init_ms: int
    dir_ms: int
    preload_ms: int
    firstframe_ms: int
    cache_ms: int
    sequence: int

    @property
    def settings(self):
        c = self.config
        return dict(B=c & 3, C=(c >> 2) & 3, F=(c >> 4) & 7,
                    T=(c >> 7) & 3, V=(c >> 9) & 7, E=(c >> 12) & 1,
                    W=(c >> 13) & 1, R=(c >> 14) & 3, X=(c >> 16) & 3,
                    Z=(c >> 18) & 1, D=(c >> 19) & 1,
                    story_active=(c >> 20) & 1, mute=(c >> 21) & 1,
                    modifier=(c >> 22) & 1, underrun=(c >> 23) & 1)

    @property
    def wave_opacity(self): return (self.config >> 24) & 7

    @property
    def fallback_count(self): return (self.config >> 27) & 31

    @property
    def sequence_version(self): return self.sequence >> 16

    @property
    def sequence_error(self): return (self.sequence >> 8) & 255

    @property
    def sequence_count(self): return (self.sequence >> 3) & 31

    @property
    def sequence_bank(self): return (self.sequence >> 2) & 1

    @property
    def upload_open(self): return bool(self.sequence & 2)

    @property
    def story_active(self): return bool(self.sequence & 1)

def parse_hardware(line):
    match = _HARDWARE.fullmatch(line.removesuffix("\r\n"))
    return HardwareStatus(*(int(field, 16) for field in match.groups())) if match else None

def metric_text(value):
    if value == 0xffffffff:
        return "未测量"
    if value == 65535:
        return "65535 ms（饱和上限）"
    return f"{value} ms" if value < 65535 else f"{value}（超出已定义计数范围）"

def parse_status(line):
    match = _STATUS.fullmatch(line.removesuffix("\r\n"))
    if not match:
        return None
    p, c, a, ready, error, period, caps = match.groups()
    if not 1 <= int(p) <= 128 or not 0 <= int(c) <= 255:
        return None
    if len(set(caps)) != len(caps) or "Q" not in caps:
        return None
    return BoardStatus(int(p), int(c), a == "1", ready == "1", int(error, 16),
                       int(period), frozenset(caps))

def line_command(command, *, features=0):
    """Validate without trimming, truncation, substitution or partial execution."""
    if not isinstance(command, str) or not command:
        raise ValueError("命令不能为空")
    if any(ord(c) < 32 or ord(c) > 126 for c in command):
        raise ValueError("只允许可打印 ASCII；不可包含换行、中文或控制字符")
    good = command in ("N", "A", "M", "P", "Q", "H", "U", "AQ")
    if command.startswith("S:"):
        good = len(command[2:]) <= MAX_SUBTITLE_LENGTH
    elif command.startswith("I"):
        good = bool(re.fullmatch(r"I[0-9]{3}", command)) and 1 <= int(command[1:]) <= 128
    elif command.startswith("J"):
        good = bool(re.fullmatch(r"J[0-9A-F]{12}", command))
        if good:
            index, word = int(command[1:3], 16), int(command[3:], 16)
            good = (index <= 15 and word >> 37 == 0 and
                    1000 <= ((word >> 14) & 0xffff) <= 60000 and ((word >> 33) & 7) <= 4)
    elif command.startswith("K"):
        good = bool(re.fullmatch(r"K[0-9]{2}", command)) and 1 <= int(command[1:]) <= 16
    elif command.startswith("L"):
        good = command in ("L0", "L1", "L2", "L3")
    elif command == "Z2":
        good = bool(features & FEATURE_ZOOM_OUT)
    elif command[0] in ALL_LIMITS:
        good = len(command) == 2 and command[1] in "0123456789" and int(command[1]) <= ALL_LIMITS[command[0]]
    if not good:
        raise ValueError("命令格式、参数范围或字幕长度无效")
    return (command + "\r\n").encode("ascii")

def subtitle_command(text):
    return line_command("S:" + text)

class Session:
    """One outstanding transaction. Timeouts never replay toggle commands."""
    def __init__(self, profile="control"):
        if profile not in PROFILES:
            raise ValueError("未知配置档")
        self.profile = profile
        self.reset()

    def reset(self):
        self.status = None
        self.hardware = None
        self.audio = None
        self.audio_supported = None  # None: unprobed/transient; False: legacy ERR.
        self.pending = None
        self.deadline = 0.0

    def allowed(self, code):
        if self.pending:
            return False
        if code == "AQ":
            return self.status is not None  # CAP describes A, not the AQ extension.
        if code == "L":
            return self.audio is not None and self.audio.has(FEATURE_AUDIO)
        if code == "Z2":
            return self.allowed("Z") and bool(self.features & FEATURE_ZOOM_OUT)
        return code == "Q" or (self.status is not None and
            code in self.status.capabilities and code in PROFILES[self.profile])

    @property
    def features(self):
        return self.audio.features if self.audio is not None else 0

    @property
    def periods(self):
        return DEMO_PERIODS if self.features & FEATURE_DEMO_PERIODS else PERIODS

    def begin(self, command, now):
        payload = line_command(command, features=self.features)
        if not self.allowed("AQ" if command == "AQ" else command[0]):
            raise ValueError("等待回复、能力未报告或当前配置档未启用此功能")
        if command.startswith("I") and int(command[1:]) > self.status.count:
            raise ValueError("页号超过板端实际有效页数")
        if command.startswith("J") and (int(command[3:], 16) & 127) >= self.status.count:
            raise ValueError("序列source_id超过板端实际有效页数")
        self.pending = command
        self.deadline = now + 1.0
        return payload

    def receive(self, line):
        if self.pending is None:
            raise ValueError("收到无对应请求的回复，请重新连接同步")
        status = parse_status(line)
        hardware = parse_hardware(line)
        audio = parse_audio(line)
        if status is not None and self.pending == "Q":
            self.status = status
            if "H" not in status.capabilities:
                self.hardware = None
            result = "status"
        elif hardware is not None and self.pending == "H":
            self.hardware = hardware
            result = "hardware"
        elif audio is not None and self.pending == "AQ":
            self.audio, self.audio_supported = audio, True
            result = "audio"
        elif self.pending == "AQ" and line in ("ERR", "ERR SYNTAX", "ERR RANGE", "ERR LENGTH"):
            self.audio, self.audio_supported = None, False
            result = "audio_unsupported"
        elif line == "ACK " + self.pending[0] and self.pending not in ("Q", "H", "AQ"):
            result = "ack"
        elif line in {"ERR SYNTAX", "ERR RANGE", "ERR LENGTH", "ERR FRAME", "ERR TIMEOUT", "ERR BUSY"}:
            if self.pending == "AQ":
                self.audio, self.audio_supported = None, None
            result = "error"
        else:
            raise ValueError("回复格式或命令不匹配；不视为执行成功")
        self.pending = None
        return result

    def timed_out(self, now):
        return self.pending is not None and now >= self.deadline

class LineReceiver:
    """Bounded byte framing; return only complete, strictly ASCII lines."""
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        lines = []
        for byte in data:
            if byte in (10, 13):
                if self.buffer:
                    lines.append(self.buffer.decode("ascii"))
                    self.buffer.clear()
            elif 32 <= byte <= 126 and len(self.buffer) < 160:
                self.buffer.append(byte)
            else:
                self.buffer.clear()
                raise ValueError("收到非 ASCII 或超长回复")
        return lines
