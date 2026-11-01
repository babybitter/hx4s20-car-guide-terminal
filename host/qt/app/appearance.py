"""Local UI preferences; theme changes never touch device configuration."""
import json
from pathlib import Path

from PySide6.QtCore import QObject, Qt, Signal

from .theme import apply_theme


class AppearanceController(QObject):
    changed = Signal(str, str)
    error = Signal(str)
    MODES = ('system', 'light', 'dark')

    def __init__(self, app, settings_path=None):
        super().__init__(app)
        self.app = app
        self.settings_path = Path(settings_path) if settings_path else None
        self.mode = 'system'
        if self.settings_path is not None:
            try:
                saved = json.loads(self.settings_path.read_text(encoding='utf-8'))
                if isinstance(saved, dict) and saved.get('theme') in self.MODES:
                    self.mode = saved['theme']
            except (OSError, ValueError):
                pass
        self.effective_mode = 'light'
        app.styleHints().colorSchemeChanged.connect(self._system_changed)
        self._apply()

    def system_effective_mode(self):
        return 'dark' if self.app.styleHints().colorScheme() == Qt.ColorScheme.Dark else 'light'

    def _apply(self):
        self.effective_mode = self.system_effective_mode() if self.mode == 'system' else self.mode
        apply_theme(self.app, self.effective_mode)
        self.changed.emit(self.mode, self.effective_mode)

    def _system_changed(self, *args):
        if self.mode == 'system':
            self._apply()

    def set_mode(self, mode):
        if mode not in self.MODES:
            raise ValueError('Unknown appearance mode')
        self.mode = mode
        self._apply()
        if self.settings_path is not None:
            temporary = self.settings_path.with_suffix('.tmp')
            try:
                self.settings_path.parent.mkdir(parents=True, exist_ok=True)
                temporary.write_text(json.dumps({'theme': self.mode}, indent=2), encoding='utf-8')
                temporary.replace(self.settings_path)
            except OSError as exc:
                self.error.emit(f'主题已切换，但无法保存偏好：{exc}')
