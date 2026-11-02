"""Qt workbench. Widgets never access a serial port directly."""
from dataclasses import asdict
from pathlib import Path
import json
from queue import Empty, SimpleQueue
import threading
import time

from PySide6.QtCore import Qt, QObject, Signal, QThread, QTimer, QRunnable, QThreadPool
from PySide6.QtWidgets import (QMainWindow, QWidget, QFrame, QLabel, QPushButton,
    QVBoxLayout, QHBoxLayout, QGridLayout, QComboBox,
    QPlainTextEdit, QLineEdit, QListWidget, QSplitter, QScrollArea, QCheckBox,
    QProgressBar, QFileDialog, QTableWidget, QTableWidgetItem, QHeaderView, QTabWidget, QApplication)

from protocol import Session, FEATURE_ZOOM_OUT, metric_text
from sequence import validate_sequence, MAX_JSON_BYTES
from local_preview import LocalPreview, PREVIEW_NOTICE
from subtitle_bitmap import render_text, preview_image, default_font
from .audio_labels import MODES, ZOOM_MODES, CLIP_TEXT, LOAD_ERRORS, FEATURE_NAMES
from .backend import BackendWorker
from .presets import PRESETS
from .widgets import (AnimatedStack, PresetCard, MetricCard, ImagePreview,
    ClickWheelComboBox, ClickWheelSpinBox)
from .appearance import AppearanceController

TRANSITIONS = ['直接切换', '黑场淡变', '横擦', '竖擦', '棋盘遮罩', '双图混合', '向左滑动', '向上滑动']
PARAMETERS = {
    'B': ('亮度', ['0', '1', '2', '3']),
    'C': ('对比度', ['0', '1', '2', '3']),
    'F': ('滤镜', ['0 · 原色', '1', '2', '3', '4', '5']),
    'X': ('高级转场', ['0 · 沿用 E / T', '1 · 双图混合', '2 · 向左滑动', '3 · 向上滑动']),
    'E': ('效果开关', ['0 · 旁路', '1 · 启用']),
    'T': ('旧式转场', ['0 · 黑场淡变', '1 · 横擦', '2 · 竖擦', '3 · 棋盘遮罩']),
    'Z': ('缩放', ['0 · 原尺寸', '1 · 中心2倍']),
    'D': ('转场步数', ['0 · 32步', '1 · 64步']),
    'R': ('自动周期', ['0 · 2秒', '1 · 5秒', '2 · 10秒', '3 · 15秒']),
    'V': ('音量', ['0 · 静音', '1', '2', '3', '4']),
    'W': ('波形叠加', ['0 · 关闭', '1 · 开启']),
    'Y': ('波形背景覆盖', ['0 · 0%', '1 · 25%', '2 · 50%', '3 · 75%', '4 · 100%']),
    'G': ('故事播放', ['0 · 退出', '1 · 从首项开始']),
}

def label(text, role=None, wrap=False):
    w = QLabel(text)
    if role:
        w.setProperty('role', role)
    w.setWordWrap(wrap)
    return w

def panel(name='card'):
    w = QFrame()
    w.setObjectName(name)
    return w

def button(text, callback, role=None):
    w = QPushButton(text)
    if role:
        w.setProperty('role', role)
    w.setCursor(Qt.PointingHandCursor)
    w.clicked.connect(callback)
    return w

class TaskSignals(QObject):
    done = Signal(int, object)

class FileTask(QRunnable):
    def __init__(self, token, fn):
        super().__init__()
        self.token, self.fn = token, fn
        self.signals = TaskSignals()
    def run(self):
        try:
            result = self.fn()
        except Exception as exc:
            result = exc
        self.signals.done.emit(self.token, result)

def collect_ports(token, scan, results):
    # OS enumeration has no cancellation API. A daemon owns only a plain queue,
    # never a Qt object, so a stuck driver cannot hold the window/process open.
    try:
        result = scan()
    except Exception as exc:
        result = exc
    results.put((token, result))

class MainWindow(QMainWindow):
    request = Signal(dict)
    shutdown = Signal()

    def __init__(self, resource_root, demo=False, profile='effects', appearance=None):
        super().__init__()
        self.resource_root = Path(resource_root)
        self.appearance = appearance or AppearanceController(QApplication.instance())
        self.demo, self.connected, self.busy = demo, False, False
        self.session = Session(profile)
        self.manifest = self.resource_root / 'legacy/assets/catalog_manifest.json'
        self.default_folder = self.resource_root / 'legacy/tools/bmp/output_bmp/catalog'
        self.preview_folder = self.default_folder
        self.preview_token = self.subtitle_token = 0
        self.preview_result = self.subtitle_bitmap = None
        self.last_preview_status = None
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(2)
        self.controls, self.actual_labels, self.preset_buttons = {}, {}, {}
        self.actions = []
        self.table_loading = False
        self.story_sync_error = None
        self.closing = False
        self._port_scan_active = False
        self._port_scan_token = 0
        self._port_rows = []
        self._port_results = SimpleQueue()
        self.setWindowTitle('HX4S20 · Terminal Studio')
        self.resize(1560, 960)
        self.setMinimumSize(1080, 700)
        self.thread = QThread(self)
        self.worker = BackendWorker()
        self.worker.moveToThread(self.thread)
        self.request.connect(self.worker.execute)
        self.shutdown.connect(self.worker.stop)
        self.worker.stopped.connect(self.thread.quit, Qt.DirectConnection)
        self.worker.event.connect(self.on_event)
        self.thread.started.connect(self.worker.start)
        self.thread.finished.connect(self.worker.deleteLater)
        self.thread.start()
        self.build()
        self.appearance.error.connect(lambda message: self.notify(message, True))
        self.port_timer = QTimer(self)
        self.port_timer.setInterval(2000)
        self.port_timer.timeout.connect(self.refresh_ports)
        self.port_result_timer = QTimer(self)
        self.port_result_timer.setInterval(50)
        self.port_result_timer.timeout.connect(self.poll_ports)
        if not demo:
            self.port_timer.start()
        self.refresh_ports()
        self.update_enabled()
        self.subtitle_timer = QTimer(self)
        self.subtitle_timer.setSingleShot(True)
        self.subtitle_timer.setInterval(250)
        self.subtitle_timer.timeout.connect(self.render_subtitle)
        self.subtitle_text.textChanged.connect(self.schedule_subtitle)
        self.font_path.textChanged.connect(self.schedule_subtitle)
        self.render_subtitle()
        if demo:
            self.connection_text.setText('界面预览 · 不连接硬件')
            self.message.setText('本地界面预览：可浏览页面、编辑故事与预览字幕；没有模拟板端状态。')

    def build(self):
        root = QWidget()
        self.setCentralWidget(root)
        outer = QHBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        sidebar = panel('sidebar')
        sidebar.setFixedWidth(204)
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(18, 24, 18, 20)
        logo = label('HX4S20', 'brand')
        side.addWidget(logo)
        side.addWidget(label('TERMINAL STUDIO', 'muted'))
        side.addSpacing(16)
        side.addWidget(label('工作台 / WORKSPACE', 'muted'))
        self.nav = QListWidget()
        self.nav.setObjectName('navigation')
        self.page_titles = ['设备总览', '演示与效果', '故事编排', '字幕工作室', '语音与音乐', '本地素材', '诊断与回读']
        for i, text in enumerate(self.page_titles):
            self.nav.addItem(f'{i+1:02d}    {text}')
        side.addWidget(self.nav, 1)
        side.addWidget(label('设备连接', 'subtitle'))
        self.port_combo = ClickWheelComboBox()
        self.port_combo.setPlaceholderText('选择 COM 端口')
        self.port_combo.setAccessibleName('可用串口')
        self.port_combo.setMaxVisibleItems(12)
        self.port_combo.view().setMinimumWidth(320)
        self.port_combo.currentIndexChanged.connect(lambda: self.update_enabled())
        side.addWidget(self.port_combo)
        self.port_status = label('正在检测串口…', 'muted', True)
        side.addWidget(self.port_status)
        self.profile_combo = QComboBox()
        self.profile_combo.addItem('完整控制 · effects', 'effects')
        self.profile_combo.addItem('基础控制 · control', 'control')
        self.profile_combo.setCurrentIndex(0 if self.session.profile == 'effects' else 1)
        self.profile_combo.currentIndexChanged.connect(self.profile_changed)
        side.addWidget(self.profile_combo)
        self.port_refresh_button = button('刷新串口', self.refresh_ports)
        side.addWidget(self.port_refresh_button)
        self.connect_button = button('连接设备', self.toggle_connection, 'primary')
        side.addWidget(self.connect_button)
        side.addWidget(label('115200 · 8N1\n单连接 / 严格应答匹配', 'muted', True))
        side.addSpacing(12)
        self.motion = QCheckBox('界面动效')
        self.motion.setChecked(True)
        side.addWidget(self.motion)
        self.theme_combo = QComboBox()
        self.theme_combo.setAccessibleName('界面主题')
        self.theme_combo.setToolTip('即时切换界面外观；不修改设备参数')
        for title, mode in [('外观 · 跟随系统', 'system'), ('外观 · 浅色', 'light'), ('外观 · 深色', 'dark')]:
            self.theme_combo.addItem(title, mode)
        self.theme_combo.setCurrentIndex(self.theme_combo.findData(self.appearance.mode))
        self.theme_combo.currentIndexChanged.connect(lambda: self.appearance.set_mode(self.theme_combo.currentData()))
        side.addWidget(self.theme_combo)
        side.addWidget(label('Qt Edition  /  独立工程', 'muted'))
        outer.addWidget(sidebar)
        body = QVBoxLayout()
        body.setContentsMargins(20, 16, 20, 12)
        body.setSpacing(12)
        outer.addLayout(body, 1)
        header = QHBoxLayout()
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        title_box.addWidget(label('车载导览终端', 'muted'))
        self.page_heading = label('设备总览', 'heading')
        title_box.addWidget(self.page_heading)
        header.addLayout(title_box)
        header.addStretch()
        self.connection_text = label('未连接 · 状态未验证', 'subtitle')
        header.addWidget(self.connection_text)
        body.addLayout(header)
        self.splitter = QSplitter(Qt.Horizontal)
        self.stack = AnimatedStack()
        self.stack.addWidget(self.dashboard_page())
        self.stack.addWidget(self.effects_page())
        self.stack.addWidget(self.story_page())
        self.stack.addWidget(self.subtitle_page())
        self.stack.addWidget(self.audio_page())
        self.stack.addWidget(self.assets_page())
        self.stack.addWidget(self.diagnostics_page())
        self.splitter.addWidget(self.stack)
        self.splitter.addWidget(self.inspector())
        self.splitter.setSizes([1000, 292])
        self.splitter.setStretchFactor(0, 1)
        self.splitter.setStretchFactor(1, 0)
        self.splitter.setChildrenCollapsible(False)
        body.addWidget(self.splitter, 1)
        self.nav.currentRowChanged.connect(self.navigate)
        self.nav.setCurrentRow(0)
        self.motion.toggled.connect(self.set_motion_enabled)
        self.message = label('选择串口后连接设备。实际状态只来自板端 Q / H / AQ 回读。', 'subtitle', True)
        self.message.setMinimumHeight(30)
        body.addWidget(self.message)
        progress_row = QHBoxLayout()
        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        self.progress.setFixedHeight(8)
        self.progress.setTextVisible(False)
        progress_row.addWidget(self.progress, 1)
        self.cancel_button = button('停止发送', self.cancel, 'danger')
        progress_row.addWidget(self.cancel_button)
        self.log_toggle = button('展开通信日志', self.toggle_log)
        progress_row.addWidget(self.log_toggle)
        progress_row.addWidget(button('导出日志', self.export_log))
        body.addLayout(progress_row)
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.document().setMaximumBlockCount(2000)
        self.log.setMaximumHeight(170)
        self.log.hide()
        body.addWidget(self.log)

    def page(self, title, description):
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 6, 0)
        layout.setSpacing(14)
        layout.addWidget(label(title, 'heading'))
        layout.addWidget(label(description, 'muted', True))
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setWidget(content)
        return scroll, layout

    def action(self, text, command, role=None):
        b = button(text, lambda: self.dispatch({'action':'command', 'command':command}), role)
        self.actions.append((b, command))
        return b

    def dashboard_page(self):
        page, box = self.page('每一站，都有新的风景', '统一控制画面、故事与声音，让演示流程更从容。')
        hero = panel('hero')
        h = QVBoxLayout(hero)
        h.setContentsMargins(24, 24, 24, 24)
        h.addWidget(label('HX4S20  /  LIVE CONTROL', 'muted'))
        h.addWidget(label('一键就绪，自由演示。', 'heading'))
        h.addWidget(label('转场预设自动组合参数，手动调节保持自由。', 'subtitle', True))
        h.addSpacing(8)
        row = QHBoxLayout()
        row.addWidget(button('进入演示工作台  →', lambda: self.nav.setCurrentRow(1), 'primary'))
        row.addWidget(button('编排故事', lambda: self.nav.setCurrentRow(2)))
        row.addStretch()
        h.addLayout(row)
        box.addWidget(hero)
        cards = QGridLayout()
        self.metrics = {}
        for i, (key, text, sub) in enumerate([('page','当前页','来自 Q 的有效页号'), ('ready','设备就绪','等待板端状态'), ('auto','自动播放','请求与实际状态分离'), ('error','错误码','无回读时不显示正常')]):
            c = MetricCard(text, '—', sub)
            self.metrics[key] = c
            cards.addWidget(c, i//2, i%2)
        box.addLayout(cards)
        box.addWidget(label('播放控制', 'subtitle'))
        row = QHBoxLayout()
        for title, cmd in [('下一页','N'),('切换自动','A'),('切换提示','M'),('试听','P')]:
            row.addWidget(self.action(title,cmd))
        box.addLayout(row)
        row = QHBoxLayout()
        self.page_spin = ClickWheelSpinBox()
        self.page_spin.setRange(1,128)
        self.page_spin.setToolTip('点击后滚轮调节，失焦锁定。')
        row.addWidget(label('指定页面', 'muted'))
        row.addWidget(self.page_spin)
        self.select_page_button = button('切换到此页', lambda: self.dispatch({'action':'command','command':f'I{self.page_spin.value():03d}'}))
        row.addWidget(self.select_page_button)
        row.addStretch()
        box.addLayout(row)
        self.board_summary = label('尚无有效板端状态。连接后自动探测功能与协议扩展。', 'muted', True)
        box.addWidget(self.board_summary)
        box.addStretch()
        return page

    def effects_page(self):
        page, box = self.page('演示与效果', '选择一种效果，自动完成参数组合；右侧仍可逐项手动调节。')
        row = QHBoxLayout()
        self.next_page_check = QCheckBox('配置核实后，自动切换下一页')
        row.addWidget(self.next_page_check)
        row.addStretch()
        box.addLayout(row)
        self.preset_note = label('一键配置会逐条等待应答，并通过 H 核实配置。不会把 ACK 当作画面完成。', 'muted', True)
        box.addWidget(self.preset_note)
        grid = QGridLayout()
        grid.setSpacing(12)
        for i, (name, preset) in enumerate(PRESETS.items()):
            card = PresetCard(name, preset['description'], f'{i+1:02d}')
            card.clicked.connect(lambda checked=False, n=name: self.dispatch({'action':'preset','name':n,'next_page':self.next_page_check.isChecked()}))
            self.preset_buttons[name] = card
            grid.addWidget(card, i//2, i%2)
        box.addLayout(grid)
        row = QHBoxLayout()
        row.addWidget(self.action('下一页 · 观察转场', 'N', 'primary'))
        row.addWidget(self.action('查询实际配置', 'H'))
        row.addStretch()
        box.addLayout(row)
        box.addWidget(label('组合配置不是板端原子事务：中途出错会停止后续命令，已接受的部分不会回滚。', 'muted', True))
        box.addStretch()
        return page

    def story_page(self):
        page, box = self.page('把沿途风景，串成故事', '支持 1—16 条记录。表格与 JSON 双向同步，上传前验证全部记录。')
        bar = QHBoxLayout()
        for title, fn in [('导入 JSON', self.import_sequence), ('导出 JSON',self.export_sequence), ('完整校验',self.validate_story)]:
            bar.addWidget(button(title, fn))
        bar.addStretch()
        box.addLayout(bar)
        self.story_tabs = QTabWidget()
        self.story_table = QTableWidget(0,6)
        self.story_table.setHorizontalHeaderLabels(['素材号','标题号','停留 ms','转场','提示音','提示窗'])
        self.story_table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        self.story_table.setMinimumHeight(290)
        self.story_tabs.addTab(self.story_table, '可视化编排')
        self.story_json = QPlainTextEdit()
        self.story_json.setMinimumHeight(290)
        self.story_tabs.addTab(self.story_json, 'JSON 编辑')
        box.addWidget(self.story_tabs)
        bar = QHBoxLayout()
        bar.addWidget(button('＋ 添加一条', self.add_story_row))
        bar.addWidget(button('删除选中条目', self.remove_story_row))
        bar.addStretch()
        self.sequence_upload_button = button('上传并确认应用', self.upload_story, 'primary')
        bar.addWidget(self.sequence_upload_button)
        box.addLayout(bar)
        bar = QHBoxLayout()
        bar.addWidget(self.action('开始故事', 'G1'))
        bar.addWidget(self.action('退出故事', 'G0'))
        box.addLayout(bar)
        box.addWidget(label('转场：0直接 / 1黑场淡变 / 2横擦 / 3竖擦 / 4棋盘 / 5混合 / 6左滑 / 7上滑\n提示音：0—3短音，4不播放；提示窗：true / false。', 'muted', True))
        self.story_status = label('上传不会自动开始播放。只有版本、bank、条数与错误状态一致，才确认新表已应用。', 'muted', True)
        box.addWidget(self.story_status)
        initial = {'schema':1,'entries':[dict(source_id=i,title_id=i,dwell_ms=5000,transition=0,cue=4,prompt=False) for i in range(1,5)]}
        self.story_json.setPlainText(json.dumps(initial, ensure_ascii=False, indent=2))
        self.json_to_table()
        self.story_table.itemChanged.connect(self.table_to_json)
        self.story_json.textChanged.connect(self.story_text_changed)
        box.addStretch()
        return page

    def subtitle_page(self):
        page, box = self.page('字幕工作室', '中文位图与旧式 ASCII 字幕统一管理，共用当前串口连接。')
        box.addWidget(label('中文位图 · 单行 / 最多40字符 / 与英文同高21px', 'subtitle'))
        self.subtitle_text = QPlainTextEdit('欢迎乘坐本次列车 下一站：人民广场')
        self.subtitle_text.setPlaceholderText('单行字幕；粘贴的换行和Tab自动转为空格，空格也计入40字符。')
        self.subtitle_text.setToolTip('换行自动转为空格；21×21字格从右侧进入、向左完整移出后循环。')
        self.subtitle_text.setMaximumHeight(110)
        box.addWidget(self.subtitle_text)
        row = QHBoxLayout()
        try:
            font = default_font()
        except ValueError:
            font = ''
        self.font_path = QLineEdit(font)
        self.font_path.setPlaceholderText('选择支持中文的 TTF / TTC / OTF 字体')
        row.addWidget(self.font_path,1)
        row.addWidget(button('选择字体',self.choose_font))
        box.addLayout(row)
        self.subtitle_image = ImagePreview()
        self.subtitle_image.setMinimumHeight(120)
        self.subtitle_image.setMaximumHeight(180)
        box.addWidget(self.subtitle_image)
        self.subtitle_info = label('正在生成实际发送位图…','muted',True)
        box.addWidget(self.subtitle_info)
        row = QHBoxLayout()
        self.subtitle_upload_button = button('上传中文字幕',self.upload_subtitle,'primary')
        row.addWidget(self.subtitle_upload_button)
        self.subtitle_abort_button = button('终止板端字幕上传',lambda: self.dispatch({'action':'subtitle_abort'}))
        row.addWidget(self.subtitle_abort_button)
        row.addStretch()
        box.addLayout(row)
        box.addWidget(label('预览来自实际1-bit位图。上传80块后验证 token / CRC / 版本与应用标志。', 'muted',True))
        box.addSpacing(12)
        box.addWidget(label('兼容旧固件 · ASCII 字幕', 'subtitle'))
        self.ascii_text = QLineEdit('HX4S20 CAR TERMINAL')
        self.ascii_text.setPlaceholderText('可打印 ASCII，最多40字符；空文本用于清空')
        box.addWidget(self.ascii_text)
        self.ascii_preview = label('本地文本预览（非板端画面）：HX4S20 CAR TERMINAL  [19/40]', 'muted',True)
        self.ascii_text.textChanged.connect(lambda text:self.ascii_preview.setText(f'本地文本预览（非板端画面）：{text}  [{len(text)}/40]'))
        box.addWidget(self.ascii_preview)
        row = QHBoxLayout()
        self.ascii_send_button = button('发送 ASCII 字幕',lambda: self.dispatch({'action':'command','command':'S:'+self.ascii_text.text()}))
        self.ascii_clear_button = button('清空板端 ASCII',lambda: self.dispatch({'action':'command','command':'S:'}))
        row.addWidget(self.ascii_send_button)
        row.addWidget(self.ascii_clear_button)
        box.addLayout(row)
        box.addStretch()
        return page

    def audio_page(self):
        page, box = self.page('语音与背景音乐', '独立探测 AQ 能力，兼容不支持音频扩展的旧固件。')
        row = QGridLayout()
        for i, title in enumerate(MODES):
            row.addWidget(self.action(f'L{i}  {title}', f'L{i}'),i//2,i%2)
        box.addLayout(row)
        box.addWidget(self.action('查询 / 重新探测 AQ','AQ'))
        self.audio_summary = label('尚无有效 AQ 回读；实际播放状态未知。','subtitle',True)
        box.addWidget(self.audio_summary)
        self.audio_health = label('素材就绪、错误、静音和位置将在此展示。','muted',True)
        box.addWidget(self.audio_health)
        self.audio_features = label('功能由 AQ features 决定，不从 Q.CAP 猜测。','muted',True)
        box.addWidget(self.audio_features)
        box.addWidget(label('片段内容参考 · 不提供任意 ID 播放命令','subtitle'))
        catalog = QTableWidget(len(CLIP_TEXT)+2,2)
        catalog.setHorizontalHeaderLabels(['ID / hex','中文内容'])
        catalog.horizontalHeader().setSectionResizeMode(1,QHeaderView.Stretch)
        catalog.setEditTriggers(QTableWidget.NoEditTriggers)
        catalog.setMinimumHeight(230)
        entries = [(f'{k} / {k:02X}',v) for k,v in CLIP_TEXT.items()] + [('26—30','保留'),('255 / FF','空闲，无当前片段')]
        for i, pair in enumerate(entries):
            for j, val in enumerate(pair): catalog.setItem(i,j,QTableWidgetItem(val))
        box.addWidget(catalog)
        box.addWidget(label('L模式允许发声不等于正在播放；V0与实体SW4静音优先，位置只展示AQ实际值。','muted',True))
        return page

    def assets_page(self):
        page, box = self.page('本地素材', PREVIEW_NOTICE)
        row = QHBoxLayout()
        row.addWidget(button('选择素材目录',self.choose_folder))
        row.addWidget(button('恢复项目默认目录',lambda:self.set_folder(self.default_folder)))
        box.addLayout(row)
        self.folder_label = label(str(self.preview_folder),'muted',True)
        box.addWidget(self.folder_label)
        self.asset_title = label('等待有效 Q 回读','subtitle')
        box.addWidget(self.asset_title)
        self.asset_image = ImagePreview()
        self.asset_image.setMinimumHeight(260)
        box.addWidget(self.asset_image,1)
        self.asset_message = label('未连接 / 尚无就绪状态，不推测板端页面。','muted',True)
        box.addWidget(self.asset_message)
        self.asset_metadata = QPlainTextEdit()
        self.asset_metadata.setReadOnly(True)
        self.asset_metadata.setMaximumHeight(180)
        box.addWidget(self.asset_metadata)
        box.addWidget(label('素材只读校验：每次有效Q重新读取文件与清单。文件变化或校验失败立即清除旧图。','muted',True))
        return page

    def diagnostics_page(self):
        page, box = self.page('诊断与实际回读','Q / H / AQ 各自是独立时刻的快照，不代表HDMI采集。')
        row = QHBoxLayout()
        for command in ('Q','H','AQ'):
            row.addWidget(self.action(f'查询 {command}',command))
        box.addLayout(row)
        self.hardware_text = QPlainTextEdit()
        self.hardware_text.setReadOnly(True)
        self.hardware_text.setMinimumHeight(320)
        self.hardware_text.setPlainText('尚无有效 H 快照。未测量项不会补成0。')
        box.addWidget(self.hardware_text)
        self.cap_text = label('CAP尚未报告。CAP只代表命令解析能力，不保证下游效果已实现。','muted',True)
        box.addWidget(self.cap_text)
        box.addWidget(label('功能边界','subtitle'))
        box.addWidget(label('BMP上传、分辨率切换：原上位机未实现，本版不伪造此能力。\n编译、烧录、清卡不属于此控制台。\n界面动效仅发生在电脑端，不模拟板端画面或成功结果。','muted',True))
        box.addStretch()
        return page

    def inspector(self):
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setMinimumWidth(255)
        scroll.setMaximumWidth(370)
        scroll.setFrameShape(QFrame.NoFrame)
        content = panel('inspector')
        layout = QVBoxLayout(content)
        layout.setContentsMargins(16,16,16,16)
        layout.setSpacing(12)
        layout.addWidget(label('参数检查器','subtitle'))
        layout.addWidget(label('手动请求  /  板端实际值','muted'))
        layout.addWidget(label('下拉框为请求值；下方数值来自回读。','muted',True))
        layout.addWidget(label('点击后滚轮调节，失焦锁定。','muted',True))
        for code,(title,values) in PARAMETERS.items():
            layout.addWidget(label(f'{title}  ·  {code}','subtitle'))
            combo = ClickWheelComboBox()
            combo.addItems(values)
            if code == 'Y': combo.setCurrentIndex(1)
            combo.activated.connect(lambda i,c=code:self.dispatch({'action':'command','command':f'{c}{i}'}))
            self.controls[code] = combo
            layout.addWidget(combo)
            actual = label('实际：—','muted')
            self.actual_labels[code] = actual
            layout.addWidget(actual)
        layout.addStretch()
        scroll.setWidget(content)
        return scroll

    def navigate(self,index):
        if index < 0: return
        self.stack.setCurrentIndex(index)
        self.page_heading.setText(self.page_titles[index])

    def set_motion_enabled(self,enabled):
        self.stack.set_motion_enabled(enabled)
        for card in self.preset_buttons.values():
            card.set_motion_enabled(enabled)

    def profile_changed(self):
        if not self.connected:
            self.session = Session(self.profile_combo.currentData())
            self.update_enabled()

    @staticmethod
    def enumerate_ports():
        """Read OS device metadata only; never open or probe any serial port."""
        from serial.tools import list_ports
        rows = {}
        for port in list_ports.comports():
            device = (port.device or '').strip()
            if not device:
                continue
            description = (port.description or '').strip()
            if description.lower() == 'n/a':
                description = ''
            description = description.removesuffix(f' ({device})')
            title = f'{device} · {description}' if description else device
            details = '\n'.join(str(v) for v in
                (title, getattr(port, 'manufacturer', None), getattr(port, 'hwid', None)) if v)
            identity = tuple(getattr(port, field, None) for field in
                ('vid', 'pid', 'serial_number', 'location', 'hwid'))
            rows[device.casefold()] = (device, title, details, identity)
        def order(row):
            name = row[0].upper()
            return (0, int(name[3:])) if name.startswith('COM') and name[3:].isdigit() else (1, name)
        return sorted(rows.values(), key=order)

    def refresh_ports(self):
        if self.demo:
            self.port_status.setText('预览模式不检测串口')
            return
        if (self.closing or self.connected or self.busy or self._port_scan_active
                or self.port_combo.view().isVisible()):
            return
        self._port_scan_active = True
        self._port_scan_token += 1
        self.port_refresh_button.setEnabled(False)
        threading.Thread(target=collect_ports, args=(self._port_scan_token,
            self.enumerate_ports, self._port_results), daemon=True,
            name='serial-port-discovery').start()
        self.port_result_timer.start()

    def poll_ports(self):
        try:
            token, result = self._port_results.get_nowait()
        except Empty:
            return
        self.port_result_timer.stop()
        self.ports_refreshed(token, result)

    def ports_refreshed(self, token, result):
        if token != self._port_scan_token:
            return
        self._port_scan_active = False
        if self.closing:
            return
        # A scan started before a click/connection must not change that choice.
        if self.connected or self.busy or self.port_combo.view().isVisible():
            self.update_enabled()
            return
        failed = isinstance(result, Exception)
        rows = [] if failed else result
        if rows != self._port_rows:
            selected = self.port_combo.currentData()
            identity = self.port_combo.currentData(Qt.UserRole + 1)
            self.port_combo.blockSignals(True)
            self.port_combo.clear()
            for device, title, details, hardware in rows:
                self.port_combo.addItem(title, device)
                self.port_combo.setItemData(self.port_combo.count()-1, details, Qt.ToolTipRole)
                self.port_combo.setItemData(self.port_combo.count()-1, hardware, Qt.UserRole + 1)
            # Keep a surviving choice. A removed port never silently becomes another.
            index = self.port_combo.findData(selected) if selected else -1
            if index >= 0 and self.port_combo.itemData(index, Qt.UserRole + 1) != identity:
                index = -1
            self.port_combo.setCurrentIndex(index)
            self.port_combo.blockSignals(False)
            self._port_rows = rows
        if failed:
            self.port_status.setText('串口检测失败，请点击刷新')
            self.port_status.setToolTip(str(result))
        elif rows:
            self.port_status.setText(f'发现 {len(rows)} 个串口，请选择')
            self.port_status.setToolTip('未连接时每2秒自动更新；只检测端口，不自动连接。')
        else:
            self.port_status.setText('未检测到串口，请连接USB数据线')
            self.port_status.setToolTip('插入设备后自动更新，也可点击“刷新串口”。')
        self.update_enabled()

    def toggle_connection(self):
        if self.demo: return
        if self.connected:
            self.dispatch({'action':'disconnect'})
        elif self.port_combo.currentData():
            self.dispatch({'action':'connect','port':self.port_combo.currentData(),'profile':self.profile_combo.currentData()})
        else:
            self.notify('请从下拉列表选择 COM 端口；未找到时连接USB数据线并刷新。',True)

    def dispatch(self,request):
        if self.demo:
            self.notify('界面预览模式不连接硬件，也不发送命令。')
            return
        if self.busy:
            self.notify('正在等待当前操作完成；本次点击未排队。')
            return
        self.busy = True
        self.update_enabled()
        self.request.emit(request)

    def cancel(self):
        self.worker.cancel_event.set()
        self.notify('已请求停止。已发送的提交无法撤销；结果需重新回读确认。')

    def on_event(self,event):
        kind = event.get('kind')
        if kind == 'busy':
            self.busy = event['busy']
            self.update_enabled()
        elif kind == 'connection':
            self.connected = event['connected']
            self.connection_text.setText(event['text'])
            self.connect_button.setText('断开设备' if self.connected else '连接设备')
            if not self.connected:
                self.session.reset()
                self.show_state()
            self.update_enabled()
        elif kind == 'state':
            self.session.status = event.get('status')
            self.session.hardware = event.get('hardware')
            self.session.audio = event.get('audio')
            self.session.audio_supported = event.get('audio_supported')
            self.session.profile = event.get('profile',self.session.profile)
            self.show_state()
            self.update_enabled()
        elif kind == 'requested':
            for code,value in event['values'].items():
                combo = self.controls.get(code)
                if combo is not None and 0 <= value < combo.count():
                    combo.setCurrentIndex(value)
        elif kind == 'log':
            self.log.appendPlainText(time.strftime('%H:%M:%S  ')+event['text'])
        elif kind == 'message':
            self.notify(event['text'],event.get('level') == 'error')
        elif kind == 'progress':
            self.progress.setRange(0,max(1,event.get('total',100)))
            self.progress.setValue(event.get('value',0))
            self.message.setText(event.get('text',''))

    def notify(self,text,error=False):
        self.message.setText(text)
        self.message.setProperty('role', 'errorMessage' if error else 'successMessage')
        self.message.style().unpolish(self.message)
        self.message.style().polish(self.message)
        self.log.appendPlainText(time.strftime('%H:%M:%S  ')+text)

    def update_enabled(self):
        if not hasattr(self,'connect_button') or not hasattr(self,'cancel_button'): return
        available = self.connected and not self.busy and not self.demo
        def allowed(cmd):
            key = 'AQ' if cmd=='AQ' else cmd[0]
            return available and self.session.allowed(key)
        for w,cmd in self.actions: w.setEnabled(allowed(cmd))
        for code,w in self.controls.items(): w.setEnabled(allowed(code))
        self.connect_button.setEnabled(bool(not self.demo and not self.busy and
            (self.connected or self.port_combo.currentData())))
        self.port_combo.setEnabled(not self.connected and not self.busy and not self.demo)
        self.port_refresh_button.setEnabled(not self.connected and not self.busy and
            not self.demo and not self._port_scan_active)
        self.profile_combo.setEnabled(not self.connected and not self.busy)
        self.select_page_button.setEnabled(allowed('I'))
        self.page_spin.setEnabled(allowed('I'))
        for name,card in self.preset_buttons.items():
            commands = PRESETS[name]['commands']
            card.setEnabled(allowed('H') and all(allowed(cmd) for cmd in commands))
        s = self.session.status
        self.sequence_upload_button.setEnabled(bool(available and self.session.profile=='effects' and s and s.ready and 1<=s.count<=128 and set('HUJK')<=s.capabilities))
        subtitle_ok = bool(available and s and 'O' in s.capabilities)
        self.subtitle_upload_button.setEnabled(subtitle_ok and self.subtitle_bitmap is not None)
        self.subtitle_abort_button.setEnabled(subtitle_ok)
        self.ascii_send_button.setEnabled(allowed('S'))
        self.ascii_clear_button.setEnabled(allowed('S'))
        self.cancel_button.setEnabled(self.busy and not self.demo)

    def show_state(self):
        s,h,a = self.session.status,self.session.hardware,self.session.audio
        if s:
            self.metrics['page'].set_value(f'{s.page:02d} / {s.count:02d}' if s.ready and 1<=s.page<=s.count<=128 else '未就绪')
            self.metrics['ready'].set_value('已就绪' if s.ready else '等待中')
            self.metrics['auto'].set_value('开启' if s.auto else '关闭')
            self.metrics['error'].set_value(f'{s.error:X}')
            self.page_spin.setMaximum(max(1,min(128,s.count)))
            self.board_summary.setText(f'最近有效 Q  · 页号 {s.page}  /  数量 {s.count}  /  周期 {self.session.periods[s.period]} 秒\nCAP：'+''.join(sorted(s.capabilities)))
            self.cap_text.setText('CAP：'+''.join(sorted(s.capabilities))+'\n仅代表协议能力；实际画面、声音需板端验证。')
        else:
            for card in self.metrics.values(): card.set_value('—')
            self.board_summary.setText('尚无有效板端状态。')
            self.cap_text.setText('CAP尚未报告。')
        periods = [f'{i} · {v}秒' for i,v in enumerate(self.session.periods)]
        self.replace_options(self.controls['R'],periods)
        zooms = PARAMETERS['Z'][1] + (['2 · 半幅缩小'] if self.session.features & FEATURE_ZOOM_OUT else [])
        self.replace_options(self.controls['Z'],zooms)
        settings = h.settings if h else {}
        for code,text in self.actual_labels.items():
            value = settings.get(code)
            if code == 'R': value = f'{self.session.periods[s.period]} 秒' if s else None
            if code == 'Y': value = f'{h.wave_opacity*25}%' if h and s and 'Y' in s.capabilities and h.wave_opacity<=4 else None
            if code == 'Z': value = ZOOM_MODES[a.zoom_mode] if a else (f'H any_zoom={settings.get("Z")}（布尔）' if h else None)
            if code == 'G': value = ('运行中' if h.story_active else '未运行') if h else None
            text.setText('实际：'+str(value) if value is not None else '实际：—')
        if h:
            actual = '\n'.join(f'{k} = {v}' for k,v in settings.items())
            timing = '\n'.join(f'{name}: {metric_text(value)}' for name,value in [('SI · SD初始化',h.sd_init_ms),('DM · 目录挂载',h.dir_ms),('LD · 素材预载',h.preload_ms),('FF · 首个好帧',h.firstframe_ms),('CL · 缓存请求',h.cache_ms)])
            err = {0:'无错误',1:'上传未打开/忙',2:'缺条目/数量错误',3:'默认序列初始化中'}.get(h.sequence_error,'未知错误')
            sq = f'SQ={h.sequence:08X}  版本={h.sequence_version}  bank={h.sequence_bank}\n条数={h.sequence_count}  上传打开={int(h.upload_open)}  运行={int(h.story_active)}\n错误={h.sequence_error} · {err}'
            self.hardware_text.setPlainText(f'CFG={h.config:08X}   EV={h.event_seq:04X}\n{actual}\n\n{timing}\n\n{sq}\n\n波形覆盖档={h.wave_opacity}；转场降级计数={h.fallback_count}（31饱和）')
            self.story_status.setText(sq+'\n新表发布不自动启动故事，也不保证此前播放已停止。')
        else:
            self.hardware_text.setPlainText('尚无有效 H 快照；断线后旧快照已清空。')
            self.story_status.setText('尚无实际SQ状态。')
        for name,card in self.preset_buttons.items():
            selected = bool(h and all(settings.get(k)==v for k,v in PRESETS[name]['expected'].items()))
            card.setProperty('selected',selected)
            card.update()
        if a:
            clip = '空闲' if a.clip_id==255 else CLIP_TEXT.get(a.clip_id,'未知片段')
            self.audio_summary.setText(f'实际模式 L{a.mode} · {MODES[a.mode]}\n当前片段 {a.clip_id} · {clip}\n位置 {a.position_ms} ms  /  事件 {a.event_seq}  /  忙碌 {int(a.busy)}  /  音乐 {int(a.music)}')
            self.audio_health.setText(f'素材就绪 {int(a.assets_ready)}  /  静音 {int(a.mute)}  /  待播 {int(a.pending)}\n装载故障 {a.loader_fault}（{LOAD_ERRORS[a.loader_fault]}）  /  流故障 {int(a.stream_fault)}\n播放器故障 {a.player_fault}  /  欠载 {a.underruns}（255饱和，不计初始buffering）')
            names = [name for bit,name in enumerate(FEATURE_NAMES) if a.features & (1<<bit)]
            self.audio_features.setText(f'AQ v{a.version} · features=0x{a.features:02X}\n'+ ' / '.join(names))
        else:
            self.audio_summary.setText('旧固件不支持 AQ；可手动重新探测。' if self.session.audio_supported is False else '尚无有效 AQ 回读。')
            self.audio_health.setText('实际音频状态未知。')
            self.audio_features.setText('未知能力不启用相关操作。')
        if s is not self.last_preview_status or s is None:
            self.last_preview_status = s
            self.load_preview()

    @staticmethod
    def replace_options(combo,values):
        if [combo.itemText(i) for i in range(combo.count())] == values: return
        index = combo.currentIndex()
        combo.blockSignals(True)
        combo.clear()
        combo.addItems(values)
        combo.setCurrentIndex(min(max(0,index),len(values)-1))
        combo.blockSignals(False)

    def load_preview(self):
        self.preview_token += 1
        token = self.preview_token
        status = self.session.status
        self.asset_image.set_pil_image(None)
        if status is None or not status.ready:
            self.asset_title.setText('等待有效 Q 回读')
            self.asset_message.setText('未连接或设备未就绪，旧图片已清除。')
            self.asset_metadata.clear()
            return
        self.asset_message.setText('正在重新校验本地文件…')
        loader = LocalPreview(self.preview_folder,self.manifest)
        task = FileTask(token,lambda:loader.load(status))
        task.signals.done.connect(self.preview_done)
        self.pool.start(task)

    def preview_done(self,token,result):
        if self.closing or token != self.preview_token: return
        if isinstance(result,Exception):
            self.asset_message.setText(str(result))
            return
        self.preview_result = result
        self.asset_title.setText(result.title)
        self.asset_message.setText(result.message)
        self.asset_metadata.setPlainText(result.metadata)
        self.asset_image.set_pil_image(result.image)

    def set_folder(self,path):
        self.preview_folder = Path(path)
        self.folder_label.setText(str(path))
        self.load_preview()
    def choose_folder(self):
        path = QFileDialog.getExistingDirectory(self,'选择只读素材目录',str(self.preview_folder))
        if path: self.set_folder(path)
    def choose_font(self):
        path,_ = QFileDialog.getOpenFileName(self,'选择中文字体',self.font_path.text(),'字体 (*.ttf *.ttc *.otf)')
        if path: self.font_path.setText(path)

    def schedule_subtitle(self):
        self.subtitle_token += 1
        self.subtitle_bitmap = None
        self.subtitle_image.set_pil_image(None)
        self.update_enabled()
        self.subtitle_timer.start()

    def render_subtitle(self):
        self.subtitle_token += 1
        token = self.subtitle_token
        text,font = self.subtitle_text.toPlainText(),self.font_path.text()
        task = FileTask(token,lambda:render_text(text,font))
        task.signals.done.connect(self.subtitle_done)
        self.pool.start(task)

    def subtitle_done(self,token,result):
        if self.closing or token != self.subtitle_token:return
        if isinstance(result,Exception):
            self.subtitle_bitmap = None
            self.subtitle_image.set_pil_image(None)
            self.subtitle_info.setText('字幕校验失败：'+str(result))
        else:
            self.subtitle_bitmap = result
            self.subtitle_image.set_pil_image(preview_image(result).convert('RGB'))
            self.subtitle_info.setText(f'单行 {result.lengths[0]}/40字符 · 21×21字格（与英文同高）· 1280字节 / 80块 · CRC16 {result.crc:04X}\n'
                '预览为左对齐静态截帧：灰白字、右下2px半透明黑影、底部2px青线；板端从右进左出循环，速率1.3px/帧。\n'
                'CRLF、CR、LF与Tab均转为空格并计入字符数；拒绝缺字与未定义控制字符。')
        self.update_enabled()

    def upload_subtitle(self):
        self.dispatch({'action':'subtitle','text':self.subtitle_text.toPlainText(),'font':self.font_path.text()})

    def table_to_json(self,*args):
        if self.table_loading:return
        try:
            entries=[]
            keys=['source_id','title_id','dwell_ms','transition','cue','prompt']
            for row in range(self.story_table.rowCount()):
                values=[]
                for col in range(6):
                    text=self.story_table.item(row,col).text() if self.story_table.item(row,col) else ''
                    if col==5:
                        if text not in ('true','false'): raise ValueError('提示窗填写 true 或 false')
                        values.append(text=='true')
                    else: values.append(int(text))
                entries.append(dict(zip(keys,values)))
            self.table_loading=True
            self.story_json.setPlainText(json.dumps({'schema':1,'entries':entries},ensure_ascii=False,indent=2))
            self.story_sync_error = None
        except ValueError as exc:
            self.story_sync_error = '表格输入无效：'+str(exc)
            self.story_status.setText('表格输入无效：'+str(exc)+'；上传前须修正。')
        finally:self.table_loading=False

    def json_to_table(self):
        entries=validate_sequence(self.story_json.toPlainText())
        self.table_loading=True
        try:
            self.story_table.setRowCount(len(entries))
            for row,entry in enumerate(entries):
                for col,value in enumerate(asdict(entry).values()):
                    self.story_table.setItem(row,col,QTableWidgetItem(str(value).lower()))
            self.story_sync_error = None
        finally:self.table_loading=False

    def story_text_changed(self):
        if self.table_loading:return
        try:self.json_to_table()
        except ValueError as exc:
            self.story_sync_error = 'JSON编辑内容无效：'+str(exc)
            self.story_status.setText(self.story_sync_error)

    def current_story_text(self):
        if self.story_sync_error:
            raise ValueError(self.story_sync_error+'；请返回对应编辑器修正后再上传。')
        if self.story_tabs.currentIndex()==0:
            # Never upload a stale JSON after invalid table input.
            for row in range(self.story_table.rowCount()):
                for col in range(6):
                    item=self.story_table.item(row,col)
                    if item is None:raise ValueError('表格含空字段')
                    if col==5 and item.text() not in ('true','false'):raise ValueError('提示窗须为 true/false')
                    if col<5:int(item.text())
            self.table_to_json()
        return self.story_json.toPlainText()

    def add_story_row(self):
        try:
            entries=validate_sequence(self.current_story_text())
            if len(entries)>=16:raise ValueError('最多16条')
            data=[asdict(x) for x in entries]+[dict(source_id=1,title_id=1,dwell_ms=5000,transition=0,cue=4,prompt=False)]
            self.story_json.setPlainText(json.dumps({'schema':1,'entries':data},ensure_ascii=False,indent=2))
        except ValueError as exc:self.notify(str(exc),True)

    def remove_story_row(self):
        row=self.story_table.currentRow()
        if row<0:return
        if self.story_table.rowCount()<=1:
            self.notify('故事至少保留1条记录。',True)
            return
        self.story_table.removeRow(row)
        self.table_to_json()

    def validate_story(self):
        try:
            s=self.session.status
            entries=validate_sequence(self.current_story_text(),s.count if s and s.ready else None)
            self.notify(f'全部 {len(entries)} 条校验通过。'+('已核对板端素材数量。' if s and s.ready else '离线校验，尚未核对板端素材数量。'))
        except ValueError as exc:self.notify(str(exc),True)

    def upload_story(self):
        try:
            text=self.current_story_text()
            validate_sequence(text)
            self.dispatch({'action':'sequence','text':text})
        except ValueError as exc:self.notify(str(exc),True)

    def import_sequence(self):
        name,_=QFileDialog.getOpenFileName(self,'导入故事序列','','JSON (*.json)')
        if not name:return
        try:
            with open(name,'rb') as stream:data=stream.read(MAX_JSON_BYTES+1)
            if len(data)>MAX_JSON_BYTES:raise ValueError('JSON超过64 KiB')
            text=data.decode('utf-8-sig')
            validate_sequence(text)
            self.story_json.setPlainText(text)
            self.notify('故事已载入本地编辑器，未发送命令。')
        except (OSError,ValueError) as exc:self.notify(str(exc),True)

    def export_sequence(self):
        try:
            text=self.current_story_text()
            validate_sequence(text)
            name,_=QFileDialog.getSaveFileName(self,'导出故事序列','story.json','JSON (*.json)')
            if name:Path(name).write_text(text,encoding='utf-8')
        except (OSError,ValueError) as exc:self.notify(str(exc),True)

    def toggle_log(self):
        visible=not self.log.isVisible()
        self.log.setVisible(visible)
        self.log_toggle.setText('收起通信日志' if visible else '展开通信日志')

    def export_log(self):
        name,_=QFileDialog.getSaveFileName(self,'导出通信日志','terminal.log','日志 (*.log *.txt)')
        if name:
            try:Path(name).write_text(self.log.toPlainText(),encoding='utf-8')
            except OSError as exc:self.notify(str(exc),True)

    def closeEvent(self,event):
        if not self.closing:
            self.closing=True
            self.port_timer.stop()
            self.port_result_timer.stop()
            self.worker.cancel_event.set()
            self.shutdown.emit()
        if not self.thread.wait(1800):
            event.ignore()
            QTimer.singleShot(150,self.close)
            return
        self.pool.waitForDone(1500)
        event.accept()
