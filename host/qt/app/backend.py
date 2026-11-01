"""Single-owner serial service. Move this QObject to a dedicated QThread.

The copied protocol/sequence/bitmap implementations remain unmodified. Qt UI
receives immutable board snapshots; requested values never impersonate them.
"""
from __future__ import annotations

import copy
from pathlib import Path
import sys
import threading
import time

from PySide6.QtCore import QObject, QTimer, Signal, Slot

LEGACY = Path(__file__).resolve().parents[1] / "legacy" / "tools" / "console"
if str(LEGACY) not in sys.path:
    sys.path.insert(0, str(LEGACY))

from protocol import Session, BAUD_RATE, FEATURE_AUDIO
from sequence import SequenceUpload
from subtitle_bitmap import UploadClient, UploadError, render_text, parse_subtitle_status
from .presets import PRESETS


class WireFailure(RuntimeError):
    """Unknown transport result: disconnect, invalidate snapshots, never retry."""


class Cancelled(WireFailure):
    pass


class BoardRejected(RuntimeError):
    """Complete ERR response: request was rejected, connection stays usable."""


class BackendWorker(QObject):
    event = Signal(dict)
    stopped = Signal()

    def __init__(self, serial_factory=None, parent=None):
        super().__init__(parent)
        self.serial_factory = serial_factory
        self.port = None
        self.session = Session("effects")
        self.cancel_event = threading.Event()
        self.timer = None
        self.busy = False
        self.stopping = False
        self._rx = bytearray()
        self.last_snapshot = None

    @Slot()
    def start(self):
        self.timer = QTimer(self)
        self.timer.setInterval(1000)
        self.timer.timeout.connect(self.poll)
        self.timer.start()

    def _emit(self, kind, **values):
        self.event.emit(dict(kind=kind, **values))

    def _message(self, text, level="info"):
        self._emit("message", text=text, level=level)
        self._emit("log", text=text)

    def _state(self):
        self.last_snapshot = dict(kind="state", status=self.session.status,
            hardware=self.session.hardware, audio=self.session.audio,
            audio_supported=self.session.audio_supported, profile=self.session.profile)
        self.event.emit(self.last_snapshot.copy())

    def _check_cancel(self):
        if self.cancel_event.is_set():
            raise Cancelled("已停止后续发送；已发命令可能生效，结果未知。重新连接查询，不自动重放")

    def _sleep(self, seconds):
        if self.cancel_event.wait(seconds):
            self._check_cancel()

    def _disconnect(self, text="已断开 · 实际状态已清空"):
        port, self.port = self.port, None
        if port is not None:
            try:
                port.close()
            except Exception:
                pass
        self._rx.clear()
        self.session.reset()
        self._state()
        self._emit("connection", connected=False, text=text)

    def _quiet(self):
        deadline, quiet = time.monotonic() + 3.0, time.monotonic() + .2
        while time.monotonic() < quiet:
            self._check_cancel()
            if time.monotonic() >= deadline:
                raise WireFailure("串口持续有旧数据，无法建立请求边界")
            if self.port.read(512):
                quiet = time.monotonic() + .2
            self._sleep(.005)

    def _connect(self, request):
        self._disconnect()
        self.session = Session(request.get("profile", "effects"))
        if self.serial_factory is None:
            import serial
            factory = serial.Serial
        else:
            factory = self.serial_factory
        self.port = factory(port=request["port"], baudrate=BAUD_RATE,
            bytesize=8, parity="N", stopbits=1, timeout=.03, write_timeout=.2)
        self._emit("connection", connected=False, text="正在同步串口、查询设备能力…")
        self._quiet()
        if self.port.write(b"\r\n") != 2:
            raise WireFailure("同步分隔符未完整写入")
        self._quiet()
        self._refresh()
        self._emit("connection", connected=True, text="已连接 · Q/H/AQ 按能力回读")

    def _wire(self, payload):
        self._check_cancel()
        if self.port is None:
            raise ValueError("请先连接串口")
        if not isinstance(payload, bytes) or not payload.endswith(b"\r\n"):
            raise ValueError("请求必须是完整CRLF帧")
        # A reply left from an unrelated transaction is never matched to a new
        # command. Empty separators are harmless; any other bytes invalidate it.
        stale = self.port.read(512)
        if self._rx.strip(b"\r\n") or stale.strip(b"\r\n"):
            raise WireFailure("收到无对应请求的旧回复；请重新连接同步")
        self._rx.clear()
        self._emit("log", text="TX  " + payload[:-2].decode("ascii"))
        if self.port.write(payload) != len(payload):
            raise WireFailure("串口短写；执行结果未知，不自动重发")
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            self._check_cancel()
            self._rx.extend(self.port.read(512))
            if any(byte not in (10, 13) and not 32 <= byte <= 126 for byte in self._rx):
                raise WireFailure("收到非ASCII回复")
            if len(self._rx) > 160:
                raise WireFailure("回复超长或多条回复无法匹配")
            if b"\r\n" in self._rx:
                raw, trailing = bytes(self._rx).split(b"\r\n", 1)
                self._rx.clear()
                if not raw or trailing.strip(b"\r\n") or b"\r" in raw or b"\n" in raw:
                    raise WireFailure("回复边界无效或出现多条未请求回复")
                line = raw.decode("ascii")
                self._emit("log", text="RX  " + line)
                return line
            self._sleep(.002)
        raise WireFailure("1秒未收到完整回复；执行结果未知，不自动重发")

    def _command(self, command, *, allow_error=False):
        self._check_cancel()
        payload = self.session.begin(command, time.monotonic())
        line = self._wire(payload)
        try:
            kind = self.session.receive(line)
        except ValueError as exc:
            raise WireFailure(str(exc)) from exc
        if kind in ("status", "hardware", "audio", "audio_unsupported"):
            self._state()
        if kind == "audio_unsupported":
            self._message("旧固件未支持AQ，停止自动AQ轮询；Q/H继续可用")
        if kind == "error" and not allow_error:
            raise BoardRejected(f"{line}：本次命令被拒绝，不自动重发")
        return kind, line

    def _refresh(self, force_audio=False):
        self._command("Q")
        if self.session.allowed("H"):
            self._command("H")
        if force_audio or self.session.audio_supported is not False:
            self._command("AQ")

    def _prevalidate(self, commands):
        if self.port is None:
            raise ValueError("请先连接串口")
        trial = copy.copy(self.session)
        trial.pending = None
        for command in commands:
            trial.begin(command, time.monotonic())
            trial.pending = None

    def _manual(self, command):
        self._prevalidate((command,))
        if len(command) == 2 and command[1].isdigit():
            self._emit("requested", values={command[0]: int(command[1])})
        kind, _ = self._command(command)
        if kind == "ack":
            self._message(f"{command} 已接收并提交；实际值以Q/H/AQ回读为准")
            self._refresh()
            if command.startswith("L") and self.session.audio is not None:
                requested = int(command[1])
                if self.session.audio.mode == requested:
                    self._message(f"AQ已核实模式L{requested}；实际发声仍受音量、静音与素材状态影响", "success")
                else:
                    self._message(f"请求L{requested}尚未核实，AQ实际L{self.session.audio.mode}；未重发", "error")

    def _preset(self, name, next_page=False):
        if name not in PRESETS:
            raise ValueError("未知一键方案")
        preset = PRESETS[name]
        commands = preset["commands"]
        # Validate ALL capabilities and optional next-page before any write.
        self._prevalidate((*commands, "H", *(("N",) if next_page else ())))
        self._emit("requested", values=dict(preset["expected"]))
        for index, command in enumerate(commands, 1):
            self._command(command)
            self._emit("progress", value=index, total=len(commands), text=f"{name} · {index}/{len(commands)}，等待实际回读")
        deadline = time.monotonic() + 2.0
        while True:
            self._command("H")
            actual = self.session.hardware.settings
            if all(actual.get(key) == value for key, value in preset["expected"].items()):
                break
            if time.monotonic() >= deadline:
                self._message(f"{name}已提交，但H未确认全部参数；保留实际回读，不自动重发或翻页", "error")
                return
            self._sleep(.1)
        self._message(f"{name}：H已确认参数组合；板端画面效果需实机观察", "success")
        if next_page:
            self._command("N")
        self._refresh()

    def _sequence(self, text):
        if self.session.profile != "effects":
            raise ValueError("故事上传仅在effects配置档开放")
        upload = SequenceUpload(text, self.session.status)
        self._prevalidate(("H", *upload.commands))
        while upload.active:
            self._check_cancel()
            command = upload.next_command(time.monotonic())
            if command is None:
                self._sleep(.01)
                continue
            kind, line = self._command(command, allow_error=True)
            upload.receive(kind, line, self.session.hardware, time.monotonic())
            self._emit("progress", value=max(0, min(len(upload.entries), upload.position - 1)),
                total=len(upload.entries), text=upload.message)
        self._message(upload.message, "success" if upload.phase == "applied" else "error")
        self._refresh()

    def _subtitle_exchange(self, payload):
        if payload == b"Q\r\n":
            return self._command("Q")[1]
        if (not payload.startswith(b"O") or len(payload) > 44 or
                any(byte < 32 or byte > 126 for byte in payload[:-2])):
            raise ValueError("字幕请求格式无效")
        line = self._wire(payload)
        if line.startswith("ERR"):
            raise BoardRejected(f"{line}：字幕命令被拒绝，不自动重发")
        if payload == b"OQ\r\n":
            try:
                parse_subtitle_status(line)
            except ValueError as exc:
                raise WireFailure(str(exc)) from exc
        elif line != "ACK O":
            raise WireFailure("字幕应答与待处理请求不匹配；结果未知，不自动重发")
        return line

    def _subtitle(self, request):
        status = self.session.status
        if self.port is None or status is None or "O" not in status.capabilities:
            raise ValueError("设备尚未声明O位图字幕能力；请连接支持的固件")
        bitmap = render_text(request["text"], request.get("font") or None)
        self._check_cancel()
        client = UploadClient(self._subtitle_exchange, sleep=self._sleep)
        state = client.upload(bitmap, progress=lambda value: self._emit("progress", value=value,
            total=80, text=f"中文字幕 {value}/80 块 · 尚未确认应用"))
        self._message(f"中文字幕已确认blank应用 · token={state.active_tag:04X} · version={state.version:04X} · CRC={state.active_crc:04X}", "success")
        self._refresh()

    @Slot(dict)
    def execute(self, request):
        action = request.get("action")
        if self.stopping:
            self._emit("busy", busy=False)
            return
        if action == "disconnect":
            self._disconnect()
            self.cancel_event.clear()
            self._emit("busy", busy=False)
            return
        if self.busy:
            self._message("当前事务尚未完成，本次操作未排队", "error")
            return
        # A cancellation issued before a queued connect reaches the worker must
        # cancel that connect too. Never erase the stop request on entry.
        if self.cancel_event.is_set():
            self._disconnect("已取消 · 请重新连接查询实际状态")
            self.cancel_event.clear()
            self._emit("busy", busy=False)
            return
        self.busy = True
        self._emit("busy", busy=True)
        try:
            if action == "connect":
                self._connect(request)
            elif action == "command":
                self._manual(request["command"])
            elif action == "preset":
                self._preset(request["name"], request.get("next_page", False))
            elif action == "sequence":
                self._sequence(request["text"])
            elif action == "subtitle":
                self._subtitle(request)
            elif action == "subtitle_abort":
                if self.port is None or self.session.status is None or "O" not in self.session.status.capabilities:
                    raise ValueError("设备尚未声明字幕能力")
                UploadClient(self._subtitle_exchange, sleep=self._sleep).abort()
                self._message("板端已确认终止未应用字幕事务；原显示字幕保留", "success")
                self._refresh()
            elif action == "refresh":
                if self.port is None:
                    raise ValueError("请先连接串口")
                self._refresh(force_audio=True)
            else:
                raise ValueError("未知操作")
        except (WireFailure, OSError) as exc:
            self._message(str(exc), "error")
            self._disconnect(str(exc))
            # Cancellation has now been consumed and the port is closed; an
            # explicit new connection can safely establish a fresh session.
            self.cancel_event.clear()
        except (ValueError, BoardRejected, UploadError) as exc:
            self._message(str(exc), "error")
            # Input validation and complete board rejections preserve the port.
            # Pending implies a wire transaction failed before a matched reply.
            if self.session.pending is not None or action == "connect":
                self._disconnect("事务结果未知；请重新连接查询")
        except Exception as exc:
            self._message(f"操作异常：{exc}；结果未知，不自动重发", "error")
            self._disconnect("操作异常 · 实际状态已清空")
        finally:
            self.busy = False
            self._emit("busy", busy=False)

    @Slot()
    def poll(self):
        if self.stopping or self.busy or self.port is None:
            return
        if self.cancel_event.is_set():
            self._disconnect("已停止发送 · 请重新连接核对实际状态")
            self.cancel_event.clear()
            return
        self.busy = True
        # No UI busy events for background polling. A GUI action may be queued
        # during this poll; poll's old busy=False must not unlock that action.
        try:
            self._refresh()
        except (BoardRejected, UploadError) as exc:
            self._message(str(exc), "error")
        except Exception as exc:
            self._message(str(exc), "error")
            self._disconnect(str(exc))
            self.cancel_event.clear()
        finally:
            self.busy = False

    @Slot()
    def stop(self):
        self.stopping = True
        try:
            if self.timer is not None:
                self.timer.stop()
            self._disconnect("已关闭")
        finally:
            # Connect this to QThread.quit with DirectConnection. The GUI may
            # be waiting for the thread and cannot deliver queued quit calls.
            self.stopped.emit()
