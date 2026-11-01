"""Offline sequence validation. No serial access, file writes or GUI imports."""
from dataclasses import dataclass
import json

MAX_JSON_BYTES = 65536
FIELDS = frozenset(("source_id", "title_id", "dwell_ms", "transition", "cue", "prompt"))


@dataclass(frozen=True)
class SequenceEntry:
    source_id: int
    title_id: int
    dwell_ms: int
    transition: int
    cue: int
    prompt: bool


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"JSON字段重复：{key}")
        result[key] = value
    return result


def _no_constant(value):
    raise ValueError(f"JSON不接受{value}")


def validate_sequence(text, media_count=None):
    """Validate every entry before any transport operation can be prepared."""
    if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_JSON_BYTES:
        raise ValueError("序列JSON必须是文本，且不超过64 KiB")
    try:
        document = json.loads(text, object_pairs_hook=_unique_object, parse_constant=_no_constant)
    except RecursionError as exc:
        raise ValueError("JSON嵌套过深；序列表只需顶层对象、entries数组和条目对象") from exc
    if not isinstance(document, dict) or set(document) != {"schema", "entries"}:
        raise ValueError("序列JSON顶层只能含schema与entries")
    if type(document["schema"]) is not int or document["schema"] != 1:
        raise ValueError("序列schema必须是整数1")
    entries = document["entries"]
    if not isinstance(entries, list) or not 1 <= len(entries) <= 16:
        raise ValueError("序列必须包含1..16条记录")
    if media_count is not None and (type(media_count) is not int or not 1 <= media_count <= 128):
        raise ValueError("板端有效素材数量须为1..128")
    validated = []
    ranges = dict(source_id=(1, 128), title_id=(1, 128), dwell_ms=(1000, 60000),
                  transition=(0, 7), cue=(0, 4))
    for number, entry in enumerate(entries, 1):
        if not isinstance(entry, dict) or set(entry) != FIELDS:
            raise ValueError(f"第{number}条必须完整提供六个规定字段，不接受未知字段")
        for field, (low, high) in ranges.items():
            if type(entry[field]) is not int or not low <= entry[field] <= high:
                raise ValueError(f"第{number}条{field}须为整数{low}..{high}")
        if type(entry["prompt"]) is not bool:
            raise ValueError(f"第{number}条prompt须为JSON布尔值true/false")
        if media_count is not None and entry["source_id"] > media_count:
            raise ValueError(f"第{number}条source_id超过实际Q数量{media_count}")
        validated.append(SequenceEntry(**entry))
    return tuple(validated)


def pack_entry(entry):
    """40 bits: source[6:0], title[13:7], dwell[29:14], T[32:30],
    cue[35:33], prompt[36], reserved[39:37]=0. IDs on wire are zero-based.
    """
    return ((entry.source_id-1) | ((entry.title_id-1) << 7) |
            (entry.dwell_ms << 14) | (entry.transition << 30) |
            (entry.cue << 33) | (int(entry.prompt) << 36))


class SequenceUpload:
    """Stop-and-wait upload, followed by actual SQ publication confirmation.

    No serial access here. The GUI owns the sole Session/transport and gives
    this state machine only replies that Session has matched to a request.
    """
    def __init__(self, text, status):
        self.entries = validate_sequence(text, status.count if status and status.ready else None)
        if status is None or not status.ready or not 1 <= status.count <= 128:
            raise ValueError("须先取得READY=1、数量1..128的有效Q")
        if not set("HUJK") <= status.capabilities:
            raise ValueError("固件CAP未报告完整H/U/J/K能力")
        self.commands = ("U",) + tuple(f"J{index:02X}{pack_entry(entry):010X}"
            for index, entry in enumerate(self.entries)) + (f"K{len(self.entries):02d}",)
        self.phase = "baseline"
        self.awaiting = None
        self.position = 0
        self.next_at = 0.0
        self.commit_deadline = None
        self.baseline_version = None
        self.baseline_bank = None
        self.message = "JSON已完整校验；读取本次上传前的H版本基线"

    @property
    def active(self): return self.phase in ("baseline", "send", "commit")

    def abort(self, message):
        self.phase = "unknown"
        self.awaiting = None
        self.message = message + "；不自动重发U/J/K，按H核对实际状态"

    def next_command(self, now):
        if self.active and self.commit_deadline is not None and now >= self.commit_deadline:
            self.abort("等待SQ新版本超过5秒，应用结果未知")
        if not self.active or self.awaiting is not None or now < self.next_at:
            return None
        command = self.commands[self.position] if self.phase == "send" else "H"
        self.awaiting = command
        return command

    def receive(self, kind, line, hardware, now):
        command = self.awaiting
        if not self.active or command is None:
            return
        self.awaiting = None
        if kind == "error":
            self.abort(f"{line}：本次上传已停止，当前行未接收")
            return
        if command == "H":
            if kind != "hardware" or hardware is None:
                self.abort("H回复不匹配，应用结果未知")
                return
            if self.phase == "baseline":
                if not 1 <= hardware.sequence_count <= 16:
                    self.abort("SQ基线条目数无效")
                    return
                self.baseline_version = hardware.sequence_version
                self.baseline_bank = hardware.sequence_bank
                self.phase = "send"
                self.message = f"基线版本{self.baseline_version}；开始提交{len(self.entries)}条记录"
                self.next_at = now + .02
            else:
                if hardware.sequence_error:
                    self.phase = "failed"
                    self.message = f"板端SQ错误{hardware.sequence_error}，未确认应用；不自动重传"
                    return
                expected = (self.baseline_version + 1) & 0xffff
                if hardware.sequence_version == expected:
                    if (hardware.sequence_bank != self.baseline_bank and
                        hardware.sequence_count == len(self.entries) and not hardware.upload_open):
                        self.phase = "applied"
                        self.message = f"H确认已应用：版本{expected}、{len(self.entries)}条、bank已切换；GUI未发送G1，播放状态看Q/H"
                    else:
                        self.abort("SQ版本已变，但bank/数量/上传状态与本次提交不一致，结果未知")
                elif hardware.sequence_version != self.baseline_version:
                    self.abort("SQ版本出现非预期变化，结果未知")
                else:
                    self.message = f"K已提交，等待实际应用；SQ仍为版本{self.baseline_version}"
                    self.next_at = now + .1
            return
        if kind != "ack" or line != "ACK " + command[0]:
            self.abort("上传应答不匹配，结果未知")
            return
        self.position += 1
        self.next_at = now + .02
        if command.startswith("K"):
            self.phase = "commit"
            self.commit_deadline = now + 5.0
            self.message = "ACK K仅表示提交；轮询H确认SQ版本、数量、bank和错误码"
        else:
            self.message = f"{line}：已提交{max(0, self.position-1)}/{len(self.entries)}条；尚未确认应用"
