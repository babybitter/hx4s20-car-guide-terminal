"""Original dark and light workbench styling for the isolated Qt console.

Inspired by contemporary desktop instrument workbenches; no upstream assets
or stylesheet code are incorporated.
"""


def configure_fonts():
    """Register installed Chinese fonts when Qt's offscreen DB is empty.

    This reads system fonts in place; no font files are copied or distributed.
    Normal desktop runs keep their native font discovery.
    """
    from pathlib import Path
    from PySide6.QtGui import QFont, QFontDatabase
    from PySide6.QtWidgets import QApplication
    families = set(QFontDatabase.families())
    preferred = ('Microsoft YaHei UI', 'Microsoft YaHei', 'Noto Sans CJK SC',
                 'Noto Sans SC', 'WenQuanYi Micro Hei', 'Segoe UI')
    if not any(name in families for name in preferred[:2]):
        for name in ('msyh.ttc', 'msyhbd.ttc', 'segoeui.ttf'):
            path = Path('C:/Windows/Fonts') / name
            if path.is_file():
                QFontDatabase.addApplicationFont(str(path))
        families = set(QFontDatabase.families())
    family = next((name for name in preferred if name in families), 'sans-serif')
    app = QApplication.instance()
    if app is not None:
        app.setFont(QFont(family, 10))
    return family

STYLESHEET = """
* {
    font-family: "Microsoft YaHei UI", "Segoe UI";
    font-size: 13px;
    color: #e4eaf2;
}
QMainWindow, QDialog { background: #0d1119; }
QWidget { outline: none; }
QWidget#central, QWidget#page, QStackedWidget { background: #0d1119; }
QFrame#sidebar, QWidget#sidebar { background: #101621; border-right: 1px solid #253040; }
QFrame#header, QWidget#header { background: #111823; border-bottom: 1px solid #253040; }
QFrame#card, QFrame#metricCard, QGroupBox {
    background: #151d29;
    border: 1px solid #293547;
    border-radius: 12px;
}
QFrame#inspector, QWidget#inspector { background: #121a26; border-left: 1px solid #273244; }
QFrame#separator { background: #293547; border: none; max-height: 1px; }
QGroupBox { margin-top: 18px; padding: 16px 12px 12px; font-weight: 600; }
QGroupBox::title {
    subcontrol-origin: margin;
    subcontrol-position: top left;
    padding: 0 7px;
    left: 12px;
    color: #cbd8e8;
}
QLabel { background: transparent; border: none; }
QLabel[role="heading"], QLabel#heading { font-size: 24px; font-weight: 700; color: #f1f5fa; }
QLabel[role="subtitle"], QLabel#subtitle { color: #92a3b9; font-size: 13px; }
QLabel[role="muted"], QLabel#muted { color: #8fa0b7; font-size: 12px; }
QLabel[role="section"] { font-size: 15px; font-weight: 600; color: #dfe9f5; }
QLabel[role="metric"], QLabel#metric { font-size: 29px; font-weight: 600; color: #f2f7fc; }
QLabel[role="accent"], QLabel#accent { color: #5ee4c3; font-weight: 600; }
QLabel[role="eyebrow"] { color: #5ee4c3; font-size: 11px; font-weight: 600; }
QLabel[role="warning"] { color: #edbd70; }
QLabel[role="brand"] { color: #5ee4c3; font-size: 23px; font-weight: 700; }
QLabel[role="errorMessage"] { color: #ffad9e; }
QLabel[role="successMessage"] { color: #bfe9e0; }
QFrame#hero {
    background: qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 #143d3c,stop:1 #16243c);
    border: 1px solid #285351;
    border-radius: 16px;
}
QLabel#imagePreview {
    background: #0f1520;
    border: 1px solid #293547;
    border-radius: 10px;
    color: #8fa0b7;
}
QPushButton, QToolButton {
    background: #1b2635;
    border: 1px solid #344357;
    border-radius: 7px;
    padding: 8px 13px;
    min-height: 18px;
    color: #d9e5f3;
}
QPushButton:hover, QToolButton:hover { background: #243347; border-color: #5b718c; }
QPushButton:pressed, QToolButton:pressed { background: #152d31; border-color: #5ee4c3; }
QPushButton:focus, QToolButton:focus { border-color: #63d6c0; }
QPushButton:checked, QToolButton:checked { background: #173a38; border-color: #458d82; color: #79eed1; }
QPushButton[role="primary"], QPushButton#primary {
    background: #5ee4c3; border-color: #5ee4c3; color: #0b2521; font-weight: 700;
}
QPushButton[role="primary"]:hover, QPushButton#primary:hover { background: #87f1d7; border-color: #87f1d7; }
QPushButton[role="primary"]:pressed, QPushButton#primary:pressed { background: #40bfa1; }
QPushButton[role="danger"], QPushButton#danger { color: #ffacb3; background: #38222d; border-color: #69404d; }
QPushButton[role="danger"]:hover, QPushButton#danger:hover { background: #512d38; border-color: #ae6273; }
QPushButton[role="nav"], QPushButton#nav {
    text-align: left; background: transparent; border: 1px solid transparent;
    color: #9cacc1; padding: 12px 14px; border-radius: 8px;
}
QPushButton[role="nav"]:hover, QPushButton#nav:hover { color: #f2f7fc; background: #1b2635; }
QPushButton[role="nav"]:checked, QPushButton#nav:checked {
    background: #18312f; border-color: #2a524c; color: #79eed1;
}
QPushButton:disabled, QToolButton:disabled {
    color: #66768c; background: #151c27; border-color: #273243;
}
QPushButton[role="primary"]:disabled, QPushButton#primary:disabled {
    color: #6b8b83; background: #213b36; border-color: #2d4c44;
}
QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox {
    background: #0f1723; border: 1px solid #344155; border-radius: 6px;
    padding: 7px 9px; min-height: 19px; selection-background-color: #285c55;
}
QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QDoubleSpinBox:focus { border-color: #5ee4c3; }
QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled, QDoubleSpinBox:disabled {
    color: #65758a; background: #131b27; border-color: #253143;
}
QComboBox { padding-right: 24px; }
QComboBox::drop-down { width: 22px; border: none; }
QComboBox QAbstractItemView {
    background: #172231; border: 1px solid #3b4d63; padding: 4px;
    selection-background-color: #23433e; selection-color: #9af2dd;
}
QAbstractItemView { selection-background-color: #22463f; selection-color: #c9fff0; }
QPlainTextEdit, QTextEdit, QTextBrowser {
    background: #0e1622; border: 1px solid #2c3a4f; border-radius: 8px;
    padding: 9px; selection-background-color: #285c55; color: #cbd8e8;
}
QPlainTextEdit#log { font-family: "Cascadia Mono", "Consolas", "Microsoft YaHei UI"; font-size: 12px; }
QTableWidget, QTableView, QTreeWidget {
    background: #111a27; alternate-background-color: #15202e;
    border: 1px solid #2c3a4f; border-radius: 8px; gridline-color: #263347;
}
QHeaderView { background: #111a27; }
QHeaderView::section {
    background: #1c2838; color: #adbed3; border: none;
    border-right: 1px solid #2a394e; border-bottom: 1px solid #344155;
    padding: 9px 10px; font-weight: 600;
}
QTableCornerButton::section { background: #1c2838; border: none; }
QListWidget { background: transparent; border: none; padding: 4px; }
QListWidget::item { padding: 13px 12px; margin: 3px 0; border: 1px solid transparent; border-radius: 8px; color: #9aabc1; }
QListWidget::item:hover { background: #1b2635; color: #e8f0fa; }
QListWidget::item:selected { background: #18312f; border-color: #2a524c; color: #79eed1; }
QScrollArea { background: transparent; border: none; }
QScrollArea > QWidget > QWidget { background: transparent; }
QScrollBar:vertical { width: 9px; background: transparent; margin: 2px; }
QScrollBar::handle:vertical { background: #344357; border-radius: 3px; min-height: 30px; }
QScrollBar::handle:vertical:hover { background: #52677f; }
QScrollBar:horizontal { height: 9px; background: transparent; margin: 2px; }
QScrollBar::handle:horizontal { background: #344357; border-radius: 3px; min-width: 30px; }
QScrollBar::handle:horizontal:hover { background: #52677f; }
QScrollBar::add-line, QScrollBar::sub-line { width: 0px; height: 0px; border: none; }
QScrollBar::add-page, QScrollBar::sub-page { background: transparent; }
QSplitter::handle { background: #202d3d; }
QSplitter::handle:hover { background: #3e695f; }
QTabWidget::pane { border: 1px solid #2b394d; border-radius: 8px; background: #131c29; }
QTabBar::tab { background: #111a27; color: #94a7be; padding: 10px 16px; border-bottom: 2px solid transparent; }
QTabBar::tab:selected { color: #7beed2; background: #192a31; border-bottom-color: #5ee4c3; }
QTabBar::tab:hover { color: #e8f0fa; background: #1d2a3c; }
QProgressBar { background: #0e1622; border: 1px solid #2b3b50; border-radius: 5px; text-align: center; min-height: 12px; }
QProgressBar::chunk { background: #46bda3; border-radius: 4px; }
QCheckBox { spacing: 8px; color: #bac8d9; }
QCheckBox::indicator { width: 15px; height: 15px; border-radius: 4px; border: 1px solid #53667f; background: #111a27; }
QCheckBox::indicator:checked { background: #54d7b8; border-color: #82efd5; }
QCheckBox::indicator:disabled { background: #1c2938; border-color: #314154; }
QCheckBox:disabled { color: #66768c; }
QSlider::groove:horizontal { height: 5px; background: #26374c; border-radius: 2px; }
QSlider::sub-page:horizontal { background: #4cbdab; border-radius: 2px; }
QSlider::handle:horizontal { width: 14px; margin: -5px 0; background: #79ead0; border-radius: 7px; }
QStatusBar { background: #101722; border-top: 1px solid #273447; color: #91a5bd; }
QStatusBar::item { border: none; }
QToolTip { background: #223044; color: #e6effa; border: 1px solid #50647f; padding: 7px; }
QMenu { background: #172231; border: 1px solid #3b4d63; padding: 4px; }
QMenu::item { padding: 7px 24px; border-radius: 4px; }
QMenu::item:selected { background: #23433e; color: #9af2dd; }
"""


# Explicit pairings keep the two palettes intentional. Surface colors remain
# distinct in light mode instead of simply inverting brightness or hue.
_LIGHT_COLORS = {
    '#0b2521':'#ffffff', '#0d1119':'#f3f6fa', '#0e1622':'#ffffff',
    '#0f1520':'#edf2f8', '#0f1723':'#ffffff', '#101621':'#eaf0f7',
    '#101722':'#eaf0f7', '#111823':'#f8fafd', '#111a27':'#ffffff',
    '#121a26':'#f8fafd', '#131b27':'#eef2f6', '#131c29':'#ffffff',
    '#151c27':'#edf1f5', '#151d29':'#ffffff', '#15202e':'#f5f8fc',
    '#152d31':'#d5e9e2', '#172231':'#ffffff', '#173a38':'#e0f2ec',
    '#18312f':'#d9eee6', '#192a31':'#e1f2ed', '#1b2635':'#f5f8fc',
    '#1c2838':'#eaf0f7', '#1c2938':'#e5ebf2', '#1d2a3c':'#e9eff7',
    '#202d3d':'#d4deea', '#213b36':'#dce9e5', '#223044':'#ffffff',
    '#22463f':'#d8eee6', '#23433e':'#d8eee6', '#243347':'#e8eef6',
    '#253040':'#ced8e5', '#253143':'#d6deea', '#263347':'#dce4ee',
    '#26374c':'#d4deeb', '#273243':'#d6deea', '#273244':'#d2dce9',
    '#273447':'#ccd7e5', '#285c55':'#cce9df', '#293547':'#d5deea',
    '#2a394e':'#d1dce9', '#2a524c':'#a7d2c4', '#2b394d':'#d4deeb',
    '#2b3b50':'#c9d7e6', '#2c3a4f':'#cdd9e7', '#2d4c44':'#bdd4ca',
    '#314154':'#c9d5e3', '#344155':'#c7d3e2', '#344357':'#c3d0df',
    '#38222d':'#fff0f1', '#3b4d63':'#c1cfdf', '#3e695f':'#73b7a3',
    '#40bfa1':'#086b59', '#458d82':'#72b6a2', '#46bda3':'#16977c',
    '#4cbdab':'#21997f', '#50647f':'#bdccde', '#512d38':'#ffe1e5',
    '#52677f':'#8da2bc', '#53667f':'#9eb2c9', '#54d7b8':'#158f75',
    '#5b718c':'#93abc5', '#5ee4c3':'#087e6b', '#63d6c0':'#0c8c76',
    '#65758a':'#8995a5', '#66768c':'#8492a4', '#69404d':'#e8bac3',
    '#6b8b83':'#728a80', '#79ead0':'#0e8c73', '#79eed1':'#086e5c',
    '#7beed2':'#08725e', '#82efd5':'#0b7f68', '#87f1d7':'#15957d',
    '#8fa0b7':'#65758b', '#91a5bd':'#62758f', '#92a3b9':'#566981',
    '#94a7be':'#60758e', '#9aabc1':'#5a6e87', '#9af2dd':'#086e5c',
    '#9cacc1':'#5c7089', '#adbed3':'#516981', '#ae6273':'#c06c7d',
    '#bac8d9':'#425b74', '#c9fff0':'#075f4d', '#cbd8e8':'#344c65',
    '#d9e5f3':'#2d4762', '#dfe9f5':'#203b55', '#e4eaf2':'#253a51',
    '#e6effa':'#243e59', '#e8f0fa':'#183d57', '#edbd70':'#946000',
    '#f1f5fa':'#17324d', '#f2f7fc':'#152e49', '#ffacb3':'#ac354a',
    '#ffad9e':'#b43d2b', '#bfe9e0':'#1b725c', '#143d3c':'#e0f2eb',
    '#16243c':'#e4edfa', '#285351':'#bbd6cd',
}


def theme_stylesheet(name='dark'):
    """Return a fully resolved stylesheet; callers resolve system preference."""
    if name == 'dark':
        return STYLESHEET
    if name != 'light':
        raise ValueError('主题须为 dark 或 light')
    import re
    return re.sub(r'#[0-9a-fA-F]{6}', lambda match:_LIGHT_COLORS[match[0].lower()], STYLESHEET)


def apply_theme(app, mode=None, *, resolved=None):
    """Apply a theme immediately, including native and custom-painted widgets.

    `resolved` is accepted as a named argument for appearance controllers.
    The application stores only the active resolved theme here; user preference
    and following system changes are owned by the caller.
    """
    from PySide6.QtGui import QColor, QPalette
    name = resolved if resolved is not None else (mode or 'dark')
    stylesheet = theme_stylesheet(name)
    light = name == 'light'
    palette = QPalette()
    colors = {
        QPalette.ColorRole.Window:'#f3f6fa' if light else '#0d1119',
        QPalette.ColorRole.WindowText:'#253a51' if light else '#e4eaf2',
        QPalette.ColorRole.Base:'#ffffff' if light else '#0e1622',
        QPalette.ColorRole.AlternateBase:'#f5f8fc' if light else '#15202e',
        QPalette.ColorRole.Text:'#253a51' if light else '#e4eaf2',
        QPalette.ColorRole.Button:'#f5f8fc' if light else '#1b2635',
        QPalette.ColorRole.ButtonText:'#2d4762' if light else '#d9e5f3',
        QPalette.ColorRole.Highlight:'#0c826c' if light else '#285c55',
        QPalette.ColorRole.HighlightedText:'#ffffff' if light else '#c9fff0',
        QPalette.ColorRole.ToolTipBase:'#ffffff' if light else '#223044',
        QPalette.ColorRole.ToolTipText:'#243e59' if light else '#e6effa',
        QPalette.ColorRole.Link:'#087e6b' if light else '#5ee4c3',
        QPalette.ColorRole.PlaceholderText:'#7c8da3' if light else '#768aa5',
    }
    for role, color in colors.items():
        palette.setColor(role,QColor(color))
    for role in (QPalette.ColorRole.Text,QPalette.ColorRole.ButtonText,QPalette.ColorRole.WindowText):
        palette.setColor(QPalette.ColorGroup.Disabled,role,QColor('#8492a4' if light else '#66768c'))
    app.setProperty('terminalTheme',name)
    app.setPalette(palette)
    app.setStyleSheet(stylesheet)
    for widget in app.topLevelWidgets():
        widget.update()
    return name
