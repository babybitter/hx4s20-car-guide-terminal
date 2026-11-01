"""Small, dependency-light presentation widgets for the Qt workbench."""
from PySide6.QtCore import QEvent, QEasingCurve, Property, QPropertyAnimation, QRectF, QSize, Qt
from PySide6.QtGui import QColor, QFont, QImage, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (
    QApplication, QFrame, QGraphicsOpacityEffect, QLabel, QPushButton, QSizePolicy,
    QStackedWidget, QVBoxLayout,
)


class AnimatedStack(QStackedWidget):
    """Short page dissolve; never delays a control or a protocol operation."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._motion_enabled = True
        self._opacity = QGraphicsOpacityEffect(self)
        self._opacity.setOpacity(1.0)
        self.setGraphicsEffect(self._opacity)
        self._fade = QPropertyAnimation(self._opacity, b"opacity", self)
        self._fade.setDuration(160)
        self._fade.setEasingCurve(QEasingCurve.Type.OutCubic)
        self._fade.finished.connect(lambda: self._opacity.setOpacity(1.0))

    def set_motion_enabled(self, enabled):
        self._motion_enabled = bool(enabled)
        if not enabled:
            self._fade.stop()
            self._opacity.setOpacity(1.0)

    def setCurrentIndex(self, index):
        changed = self.currentIndex() != index and 0 <= index < self.count()
        self._fade.stop()
        self._opacity.setOpacity(1.0)
        super().setCurrentIndex(index)
        if changed and self._motion_enabled and self.isVisible():
            self._fade.setStartValue(0.35)
            self._fade.setEndValue(1.0)
            self._fade.start()

    def setCurrentWidget(self, widget):
        self.setCurrentIndex(self.indexOf(widget))


class PresetCard(QPushButton):
    """Clickable effect tile with a restrained animated accent and vector motif."""

    def __init__(self, title, subtitle, index="01", parent=None):
        super().__init__(parent)
        self.title = str(title)
        self.subtitle = str(subtitle)
        self.index = str(index)
        self._hover = 0.0
        self._motion_enabled = True
        self.setObjectName("preset")
        self.setAccessibleName(self.title)
        self.setAccessibleDescription(self.subtitle)
        self.setToolTip(self.subtitle)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setMinimumSize(210, 106)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._animation = QPropertyAnimation(self, b"hoverAmount", self)
        self._animation.setDuration(130)
        self._animation.setEasingCurve(QEasingCurve.Type.OutCubic)

    def sizeHint(self):
        return QSize(260, 112)

    def _get_hover(self):
        return self._hover

    def _set_hover(self, value):
        self._hover = float(value)
        self.update()

    hoverAmount = Property(float, _get_hover, _set_hover)

    def set_motion_enabled(self, enabled):
        self._motion_enabled = bool(enabled)
        self._animation.stop()
        self._set_hover(1.0 if self.underMouse() and self.isEnabled() else 0.0)

    def _animate_hover(self, value):
        self._animation.stop()
        if self._motion_enabled:
            self._animation.setStartValue(self._hover)
            self._animation.setEndValue(value)
            self._animation.start()
        else:
            self._set_hover(value)

    def enterEvent(self, event):
        if self.isEnabled():
            self._animate_hover(1.0)
        super().enterEvent(event)

    def leaveEvent(self, event):
        self._animate_hover(0.0)
        super().leaveEvent(event)

    def changeEvent(self, event):
        super().changeEvent(event)
        if event.type() in (QEvent.Type.PaletteChange,QEvent.Type.StyleChange,QEvent.Type.EnabledChange):
            self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        rect = QRectF(self.rect()).adjusted(1, 1, -1, -1)
        enabled = self.isEnabled()
        selected = self.isChecked() or bool(self.property("selected"))
        hover = self._hover if enabled else 0.0
        app = QApplication.instance()
        light = app is not None and app.property('terminalTheme') == 'light'
        colors = ({'surface':'#ffffff','disabled':'#edf2f7','selected':'#e1f2eb',
                   'pressed':'#d0e9df','border':'#c9d6e5','accent':'#0d8b72',
                   'dim_accent':'#8a9bac','eyebrow':'#0a7b65','dim_eyebrow':'#6e8197',
                   'title':'#183650','dim_title':'#788a9e','detail':'#59728a','dim_detail':'#7e8fa3'}
                  if light else
                  {'surface':'#172131','disabled':'#141c27','selected':'#193b36',
                   'pressed':'#20473f','border':'#314157','accent':'#70e6c8',
                   'dim_accent':'#475b65','eyebrow':'#65d6bc','dim_eyebrow':'#64778a',
                   'title':'#eaf2fa','dim_title':'#8190a2','detail':'#a0b1c6','dim_detail':'#68788d'})
        background = QColor(colors['surface'] if enabled else colors['disabled'])
        if selected:
            background = QColor(colors['selected'])
        elif hover > 0:
            background = (QColor(255-int(hover*14),255-int(hover*7),255-int(hover*10)) if light else
                          QColor(23+int(hover*4),33+int(hover*10),49+int(hover*9)))
        if self.isDown():
            background = QColor(colors['pressed'])
        border = QColor(colors['accent'] if selected or self.hasFocus() else colors['border'])
        if enabled and hover and not selected:
            border = (QColor(201-int(hover*91),214-int(hover*40),229-int(hover*73)) if light else
                      QColor(49+int(hover*35),65+int(hover*70),87+int(hover*48)))
        painter.setPen(QPen(border, 1.2))
        painter.setBrush(background)
        painter.drawRoundedRect(rect, 10, 10)

        # A small original transition schematic: three offset frame outlines.
        accent = QColor(colors['accent'] if enabled else colors['dim_accent'])
        accent.setAlpha(150 if selected else 85 + int(hover * 65))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(accent, 1.1))
        x = self.width() - 57
        for step in range(3):
            painter.drawRoundedRect(QRectF(x + step * 6, 17 + step * 4, 24, 18), 3, 3)

        eyebrow = QFont(self.font())
        eyebrow.setPixelSize(10)
        eyebrow.setBold(True)
        painter.setFont(eyebrow)
        painter.setPen(QColor(colors['eyebrow'] if enabled else colors['dim_eyebrow']))
        painter.drawText(QRectF(16, 12, self.width() - 78, 15), Qt.AlignmentFlag.AlignLeft, f"PRESET  /  {self.index}")

        title_font = QFont(self.font())
        title_font.setPixelSize(17)
        title_font.setBold(True)
        painter.setFont(title_font)
        painter.setPen(QColor(colors['title'] if enabled else colors['dim_title']))
        title_text = painter.fontMetrics().elidedText(self.title, Qt.TextElideMode.ElideRight, self.width() - 34)
        painter.drawText(QRectF(16, 36, self.width() - 32, 27), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, title_text)

        detail_font = QFont(self.font())
        detail_font.setPixelSize(11)
        painter.setFont(detail_font)
        painter.setPen(QColor(colors['detail'] if enabled else colors['dim_detail']))
        painter.drawText(QRectF(16, 69, self.width() - 32, 32), Qt.AlignmentFlag.AlignLeft | Qt.TextFlag.TextWordWrap, self.subtitle)
        painter.end()


class MetricCard(QFrame):
    def __init__(self, title, value="—", subtitle="", parent=None):
        super().__init__(parent)
        self.setObjectName("metricCard")
        self.setMinimumHeight(112)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 14, 18, 13)
        layout.setSpacing(5)
        self.title_label = QLabel(str(title))
        self.title_label.setProperty("role", "muted")
        self.value_label = QLabel(str(value))
        self.value_label.setProperty("role", "metric")
        self.subtitle_label = QLabel(str(subtitle))
        self.subtitle_label.setProperty("role", "muted")
        self.subtitle_label.setWordWrap(True)
        layout.addWidget(self.title_label)
        layout.addWidget(self.value_label)
        layout.addWidget(self.subtitle_label)

    def set_value(self, value):
        self.value_label.setText(str(value))

    def set_subtitle(self, subtitle):
        self.subtitle_label.setText(str(subtitle))


class ImagePreview(QLabel):
    """Aspect-preserving local image view. Owns its Qt image memory."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("imagePreview")
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMinimumSize(200, 150)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setWordWrap(True)
        self._original = QPixmap()
        self.setText("等待有效状态\n本地素材预览 · 非 HDMI 采集")

    def set_pil_image(self, image):
        if image is None:
            self._original = QPixmap()
            self.clear()
            self.setText("等待有效状态\n本地素材预览 · 非 HDMI 采集")
            return
        source = image.convert("RGBA")
        data = source.tobytes("raw", "RGBA")
        qt_image = QImage(data, source.width, source.height, source.width * 4, QImage.Format.Format_RGBA8888).copy()
        self._original = QPixmap.fromImage(qt_image)
        self._render()

    def _render(self):
        if not self._original.isNull():
            bounds = self.contentsRect().size() - QSize(16, 16)
            if bounds.width() > 0 and bounds.height() > 0:
                self.setPixmap(self._original.scaled(bounds, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._render()
