"""Qt windows: configuration, floating subtitle, launcher and region selection."""

from PySide6.QtCore import QEvent, QPoint, QPointF, QRect, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QFontMetrics, QIcon, QPainter, QPainterPath, QPalette, QPen, QPixmap, QTextBlockFormat, QTextCursor
from PySide6.QtWidgets import (
    QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog, QFormLayout, QHBoxLayout, QLabel,
    QLineEdit, QPushButton, QScrollArea, QSlider, QSpinBox, QTextEdit, QVBoxLayout, QWidget,
)

from .core import LANGUAGES, MODES, PROVIDERS
from .desktop import show_on_all_workspaces
from .pet import SKINS, capture_pet

STYLE = """
QWidget { font-size: 13px; }
QLabel#heading { font-size: 14px; font-weight: 600; }
QLabel#muted { color: palette(mid); }
QLineEdit, QComboBox, QSpinBox, QTextEdit {
    background: palette(base); border: 1px solid palette(mid); border-radius: 5px; padding: 5px; }
QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QTextEdit:focus {
    border: 1px solid palette(highlight); }
QPushButton { background: palette(button); border: 1px solid palette(mid);
              border-radius: 5px; padding: 5px 10px; }
QPushButton:hover { border-color: palette(highlight); }
QPushButton:pressed { background: palette(midlight); }
QPushButton:focus { border: 1px solid palette(highlight); }
QPushButton:disabled { color: palette(mid); }
QPushButton#primary, QPushButton:checked { background: palette(highlight);
    color: palette(highlighted-text); border-color: palette(highlight); }
QMenu { background: palette(window); border: 1px solid palette(mid); }
QMenu::item { padding: 9px 20px; }
QMenu::item:selected { background: palette(highlight); color: palette(highlighted-text); }
"""


def label(text, muted=False):
    widget = QLabel(text)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(True)
    if muted:
        widget.setObjectName("muted")
    return widget


def apply_theme(app):
    muted = "#abb4c3" if app.palette().color(QPalette.ColorRole.Window).lightness() < 128 else "#606975"
    app.setStyleSheet(STYLE + "\nQLabel#muted { color: " + muted + "; }")


def button(text, callback=None, primary=False):
    widget = QPushButton(text)
    widget.setMinimumHeight(28)
    if callback:
        widget.clicked.connect(callback)
    if primary:
        widget.setObjectName("primary")
    return widget


def pin_icon(pinned):
    image = QPixmap(20, 20)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.translate(10, 9)
    painter.rotate(40)
    shape = QPainterPath()
    shape.moveTo(-4, -6)
    shape.lineTo(4, -6)
    shape.lineTo(3, -1)
    shape.lineTo(5, 2)
    shape.lineTo(-5, 2)
    shape.lineTo(-3, -1)
    shape.closeSubpath()
    color = QColor("#fbd45e" if pinned else "#e9edf5")
    painter.setPen(QPen(color, 1.2))
    painter.setBrush(color if pinned else Qt.BrushStyle.NoBrush)
    painter.drawPath(shape)
    painter.drawLine(0, 2, 0, 8)
    painter.end()
    return QIcon(image)


def bounded_position(widget, saved, default):
    point = QPoint(*saved) if saved else default
    screen = QApplication.screenAt(point) or QApplication.primaryScreen()
    available = screen.availableGeometry()
    return QPoint(max(available.left(), min(point.x(), available.right() - widget.width() + 1)),
                  max(available.top(), min(point.y(), available.bottom() - widget.height() + 1)))


def scrollable_tab(widget):
    scroll = QScrollArea()
    scroll.setWidgetResizable(True)
    scroll.setFrameShape(QScrollArea.Shape.NoFrame)
    scroll.setWidget(widget)
    return scroll


class SettingsWindow(QDialog):
    save_requested = Signal()
    translate_requested = Signal(str)
    clipboard_requested = Signal()
    capture_requested = Signal(bool)
    models_requested = Signal()
    changed = Signal()
    permissions_requested = Signal()

    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.current_provider = settings.provider
        self.setWindowTitle("棱镜翻译 · 设置")
        self.setMinimumSize(480, 500)
        self.resize(520, 740)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        connection = QWidget()
        form = QFormLayout(connection)
        form.setContentsMargins(22, 22, 22, 22)
        form.setVerticalSpacing(12)
        layout.addWidget(scrollable_tab(connection), 1)

        def section(title):
            heading = label(title)
            heading.setObjectName("heading")
            form.addRow(heading)

        def segments(choices, selected):
            row = QWidget()
            buttons = QHBoxLayout(row)
            buttons.setContentsMargins(0, 0, 0, 0)
            buttons.setSpacing(0)
            group = QButtonGroup(row)
            group.setExclusive(True)
            combo = QComboBox(row)
            combo.hide()
            controls = []
            for key, name in choices.items():
                combo.addItem(name, key)
                control = button(name)
                control.setCheckable(True)
                group.addButton(control)
                control.clicked.connect(lambda checked=False, key=key: combo.setCurrentIndex(combo.findData(key)))
                buttons.addWidget(control)
                controls.append(control)
            combo.setCurrentIndex(combo.findData(selected))

            def update(index):
                for number, control in enumerate(controls):
                    control.setChecked(number == index)
            combo.currentIndexChanged.connect(update)
            update(combo.currentIndex())
            return combo, row

        section("功能模式")
        self.mode, modes = segments(MODES, settings.mode)
        form.addRow(modes)
        self.mode_hint = label("", True)
        form.addRow(self.mode_hint)
        self.permissions_button = button("截图权限…", self.permissions_requested.emit)
        form.addRow(self.permissions_button)
        section("接口协议")
        self.provider, providers = segments({key: value[0] for key, value in PROVIDERS.items()}, settings.provider)
        form.addRow(providers)
        self.base_url = QLineEdit()
        self.base_label = label("接口地址 (Base URL)", True)
        form.addRow(self.base_label)
        form.addRow(self.base_url)
        self.api_key = QLineEdit()
        self.api_key.setEchoMode(QLineEdit.EchoMode.Password)
        self.key_label = label("API Key", True)
        form.addRow(self.key_label)
        self.key_row = QWidget()
        keys = QHBoxLayout(self.key_row)
        keys.setContentsMargins(0, 0, 0, 0)
        keys.addWidget(self.api_key)
        self.reveal = button("显示", self.toggle_key)
        keys.addWidget(self.reveal)
        form.addRow(self.key_row)
        self.model = QComboBox()
        self.model.setEditable(True)
        self.model.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        form.addRow("模型 (Model)", self.model)
        self.refresh = button("刷新模型", self.models_requested.emit)
        form.addRow(self.refresh)
        self.model_status = label("", True)
        form.addRow("", self.model_status)
        self.provider_hint = label("", True)
        form.addRow(self.provider_hint)
        section("语言")
        self.source = QComboBox()
        self.source.addItem("自动检测", "auto")
        self.target = QComboBox()
        for code, name in LANGUAGES:
            self.source.addItem(name, code)
            self.target.addItem(name, code)
        self.source.setCurrentIndex(self.source.findData(settings.source))
        self.target.setCurrentIndex(self.target.findData(settings.target))
        form.addRow("源语言", self.source)
        form.addRow("目标语言", self.target)
        section("字幕显示")
        self.watch = QCheckBox("自动监听粘贴板变化")
        self.watch.setChecked(settings.watch_clipboard)
        self.original = QCheckBox("同时显示原文")
        self.original.setChecked(settings.show_original)
        self.ball = QCheckBox("显示悬浮球")
        self.ball.setChecked(settings.show_ball)
        self.skin = QComboBox()
        for key, name in SKINS.items():
            self.skin.addItem(name, key)
        self.skin.setCurrentIndex(self.skin.findData(settings.ball_skin))
        self.font_size = QSlider(Qt.Orientation.Horizontal)
        self.font_size.setRange(14, 40)
        self.font_size.setValue(settings.font_size)
        self.seconds = QSlider(Qt.Orientation.Horizontal)
        self.seconds.setRange(3, 30)
        self.seconds.setValue(settings.seconds)
        self.ocr_languages = QLineEdit(settings.ocr_languages)
        for widget in (self.original, self.watch, self.ball):
            form.addRow(widget)
        form.addRow("悬浮球皮肤", self.skin)
        for title, slider, suffix in (("字号", self.font_size, ""), ("停留时间", self.seconds, "s")):
            row = QWidget()
            controls = QHBoxLayout(row)
            controls.setContentsMargins(0, 0, 0, 0)
            controls.addWidget(slider)
            value = label(str(slider.value()) + suffix)
            value.setMinimumWidth(34)
            slider.valueChanged.connect(lambda number, value=value, suffix=suffix: value.setText(str(number) + suffix))
            controls.addWidget(value)
            form.addRow(title, row)
        section("快捷键")
        self.shortcut_hint = label("", True)
        form.addRow(self.shortcut_hint)
        form.addRow("OCR 语言包", self.ocr_languages)
        self.reduce_motion = QCheckBox("减少动态效果")
        self.reduce_motion.setChecked(settings.reduce_motion)
        form.addRow(self.reduce_motion)
        form.addRow(label("截图使用本地 Tesseract。X11 可直接框选；Wayland 使用系统截屏授权。\n"
                          "Ctrl+O 从图片识别 · Ctrl+Q 退出。", True))
        self.sample = QTextEdit()
        self.sample.setPlainText("Hello, world!")
        self.sample.setPlaceholderText("输入或粘贴文字，验证翻译服务…")
        self.sample.setFixedHeight(60)
        form.addRow(self.sample)
        footer = QHBoxLayout()
        self.test_button = button("测试翻译（Hello, world!）", lambda: self.translate_requested.emit(self.sample.toPlainText()))
        footer.addWidget(self.test_button)
        footer.addStretch()
        self.save_button = button("保存设置", self.save_requested.emit)
        footer.addWidget(self.save_button)
        form.addRow(footer)
        tasks = QHBoxLayout()
        self.clipboard_button = button("翻译剪贴板", self.clipboard_requested.emit)
        self.ocr_button = button("截图 OCR", lambda: self.capture_requested.emit(False))
        self.capture_button = button("OCR翻译", lambda: self.capture_requested.emit(True))
        for widget in (self.clipboard_button, self.ocr_button, self.capture_button):
            tasks.addWidget(widget)
        form.addRow(tasks)
        self.status = label("就绪", True)
        self.status.setAccessibleName("操作状态")
        layout.addWidget(self.status)
        layout.setContentsMargins(0, 0, 0, 10)
        self.provider.currentIndexChanged.connect(self.change_provider)
        self.restore_profile()
        self.update_mode()
        self.mode.currentIndexChanged.connect(self.update_mode)
        self.skin.setVisible(settings.show_ball)
        self.ball.toggled.connect(self.skin.setVisible)
        notify_change = lambda *_: self.changed.emit()
        for combo in (self.provider, self.mode, self.source, self.target, self.skin, self.model):
            combo.currentIndexChanged.connect(notify_change)
        self.model.editTextChanged.connect(notify_change)
        for edit in (self.base_url, self.api_key, self.ocr_languages):
            edit.textEdited.connect(notify_change)
        for check in (self.watch, self.original, self.ball, self.reduce_motion):
            check.toggled.connect(notify_change)
        for slider in (self.font_size, self.seconds):
            slider.valueChanged.connect(notify_change)

    def toggle_key(self):
        visible = self.api_key.echoMode() == QLineEdit.EchoMode.Password
        self.api_key.setEchoMode(QLineEdit.EchoMode.Normal if visible else QLineEdit.EchoMode.Password)
        self.reveal.setText("隐藏" if visible else "显示")

    def update_mode(self, *_):
        self.permissions_button.setVisible(self.mode.currentData() != "translate")
        self.mode_hint.setText({
            "translate": "翻译：按 Ctrl+Shift+T 或开启自动监听，翻译粘贴板文本并显示字幕。",
            "ocr": "OCR：按 Ctrl+Shift+T 截图识别原文并显示字幕，可选词后 Ctrl+C 复制。",
            "ocr-translate": "OCR翻译：按 Ctrl+Shift+T 截图后翻译。长按悬浮球可直接选择两种 OCR 任务。",
        }[self.mode.currentData()])
        self.shortcut_hint.setText("全局快捷键：Ctrl+Shift+T 执行所选功能（" + self.mode.currentText() + "）")

    def store_profile(self):
        self.settings.profiles[self.current_provider] = {
            "base_url": self.base_url.text().strip(),
            "model": self.model.currentText().strip(),
            "api_key": self.api_key.text().strip(),
        }

    def restore_profile(self):
        profile = self.settings.profiles[self.current_provider]
        self.base_url.setText(profile["base_url"])
        self.api_key.setText(profile["api_key"])
        self.model.clear()
        if profile["model"]:
            self.model.addItem(profile["model"])
        local = self.current_provider == "ollama"
        for widget in (self.base_url, self.base_label, self.key_label, self.key_row):
            widget.setVisible(not local)
        self.model.setEditable(not local)
        if not local:
            self.model.setEditText(profile["model"])
        self.refresh.setVisible(local)
        self.model_status.setVisible(local)
        self.provider_hint.setText("使用本机 Ollama（http://127.0.0.1:11434），无需 API Key，不会自动下载模型。"
                                  if local else "使用兼容接口：POST {BaseURL}/" +
                                  ("chat/completions" if self.current_provider == "openai" else "messages"))

    def change_provider(self, *_):
        self.store_profile()
        self.current_provider = self.provider.currentData()
        self.restore_profile()
        if self.current_provider == "ollama":
            self.models_requested.emit()

    def apply(self):
        self.store_profile()
        self.settings.provider = self.current_provider
        self.settings.source = self.source.currentData()
        self.settings.target = self.target.currentData()
        self.settings.watch_clipboard = self.watch.isChecked()
        self.settings.show_original = self.original.isChecked()
        self.settings.show_ball = self.ball.isChecked()
        self.settings.ball_skin = self.skin.currentData()
        self.settings.mode = self.mode.currentData()
        self.settings.reduce_motion = self.reduce_motion.isChecked()
        self.settings.font_size = self.font_size.value()
        self.settings.seconds = self.seconds.value()
        self.settings.ocr_languages = self.ocr_languages.text().strip()

    def set_busy(self, busy):
        for widget in (self.clipboard_button, self.ocr_button, self.capture_button, self.test_button):
            widget.setEnabled(not busy)

    def closeEvent(self, event):
        # There must always be a discoverable entry point on desktops without a tray.
        if not QApplication.instance().property("has_tray") and not self.settings.show_ball:
            self.status.setText("此桌面没有系统托盘；请开启悬浮棱镜后再关闭窗口。")
            event.ignore()
        else:
            event.accept()


class DraggableWindow(QWidget):
    moved = Signal()

    def __init__(self):
        super().__init__(None, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint |
                         Qt.WindowType.WindowStaysOnTopHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.drag_start = None
        self.dragged = False
        self.pinned = False

    def showEvent(self, event):
        show_on_all_workspaces(self)
        super().showEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton and not self.pinned:
            self.drag_start = event.globalPosition().toPoint() - self.pos()
            self.dragged = False

    def mouseMoveEvent(self, event):
        if self.drag_start is not None and event.buttons() & Qt.MouseButton.LeftButton:
            point = event.globalPosition().toPoint() - self.drag_start
            if (point - self.pos()).manhattanLength() >= QApplication.startDragDistance():
                self.dragged = True
            if self.dragged:
                self.move(point)

    def mouseReleaseEvent(self, event):
        if self.drag_start is not None:
            if self.dragged:
                self.move(bounded_position(self, [self.x(), self.y()], self.pos()))
                self.moved.emit()
            self.drag_start = None


class Subtitle(DraggableWindow):
    visibility_changed = Signal(bool)

    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.setWindowTitle("棱镜翻译 · 字幕")
        self.setStyleSheet("QWidget#bubble { background: rgba(0,0,0,199); border: 1px solid rgba(255,255,255,20);"
                          "border-radius: 16px; }")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(12, 12, 12, 12)
        self.bubble = QWidget()
        self.bubble.setObjectName("bubble")
        outer.addWidget(self.bubble)
        layout = QVBoxLayout(self.bubble)
        layout.setContentsMargins(22, 14, 22, 14)
        layout.setSpacing(6)
        self.pin = button("", self.toggle_pin)
        self.pin.setIcon(pin_icon(False))
        self.pin.setParent(self)
        self.pin.setFixedSize(28, 28)
        self.pin.setToolTip("锁定字幕，保持显示")
        self.pin.setStyleSheet("QPushButton {background: rgba(0,0,0,210); color: white;"
                              "border: 1px solid #607080; border-radius: 14px; padding: 0;}")
        self.pin.setCheckable(True)
        self.pin.setAccessibleName("固定字幕，停止自动关闭和拖动")
        self.pin.hide()
        self.original = QTextEdit()
        self.result = QTextEdit()
        for widget in (self.original, self.result):
            widget.setReadOnly(True)
            widget.setStyleSheet("QTextEdit { background: transparent; border: 0; padding: 0; }")
            widget.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
            layout.addWidget(widget)
        self.original.setAccessibleName("原文")
        self.result.setAccessibleName("翻译或识别结果")
        self.timer = QTimer(self)
        self.timer.setSingleShot(True)
        self.timer.timeout.connect(self.hide)
        self.remaining = settings.seconds * 1000
        self.moved.connect(self.save_position)
        self.selectable = True
        for widget in (self.original, self.result):
            widget.viewport().installEventFilter(self)
        QApplication.instance().installEventFilter(self)

    def showEvent(self, event):
        self.visibility_changed.emit(True)
        super().showEvent(event)

    def hideEvent(self, event):
        self.visibility_changed.emit(False)
        self.timer.stop()
        super().hideEvent(event)

    def show_result(self, original, result, error=False, loading=False):
        screen = QApplication.screenAt(self.pos()) if self.isVisible() else QApplication.primaryScreen()
        screen = screen or QApplication.primaryScreen()
        available = screen.availableGeometry()
        font = QFont()
        font.setPixelSize(self.settings.font_size)
        font.setWeight(QFont.Weight.DemiBold)
        original_font = QFont()
        original_font.setPixelSize(max(12, self.settings.font_size - 6))
        maximum = min(760, int(available.width() * .9) - 44)
        natural = max([QFontMetrics(font).horizontalAdvance(line) for line in result.splitlines()] or [120])
        if self.settings.show_original and original:
            natural = max(natural, max(QFontMetrics(original_font).horizontalAdvance(line) for line in original.splitlines()))
        self.setFixedWidth(max(188, min(maximum + 24, natural + 68)))
        self.original.setVisible(self.settings.show_original and bool(original))
        self.original.setPlainText(original)
        self.result.setPlainText(result)
        self.result.setFont(font)
        self.original.setFont(original_font)
        self.original.setStyleSheet("QTextEdit {background: transparent; border: 0; color: rgba(255,255,255,179); padding: 0;}")
        self.result.setStyleSheet("QTextEdit { background: transparent; border: 0; padding: 0;"
                                 "font-size: " + str(self.settings.font_size) + "px;"
                                 "color: " + ("#ffc8c0" if error else "#f0f3fa") + "; }")
        for widget, limit in ((self.original, available.height() // 4), (self.result, int(available.height() * .55))):
            cursor = widget.textCursor()
            cursor.select(QTextCursor.SelectionType.Document)
            block = QTextBlockFormat()
            block.setAlignment(Qt.AlignmentFlag.AlignCenter)
            cursor.mergeBlockFormat(block)
            cursor.clearSelection()
            cursor.movePosition(QTextCursor.MoveOperation.Start)
            widget.setTextCursor(cursor)
            widget.document().setTextWidth(self.width() - 68)
            widget.setFixedHeight(min(limit, max(24, int(widget.document().size().height()) + 4)))
        self.adjustSize()
        center = QPoint(*self.settings.overlay_center) if self.settings.overlay_center else QPoint(
            available.center().x(), available.bottom() - round(available.height() * .18))
        default = center - QPoint(self.width() // 2, self.height() // 2)
        self.move(bounded_position(self, [], default))
        self.pin.move(self.width() - 28, 0)
        self.remaining = self.settings.seconds * 1000
        self.show()
        self.raise_()
        self.selectable = not error and not loading
        interactions = (Qt.TextInteractionFlag.TextSelectableByMouse |
                        Qt.TextInteractionFlag.TextSelectableByKeyboard) if self.selectable else Qt.TextInteractionFlag.NoTextInteraction
        for widget in (self.original, self.result):
            widget.setTextInteractionFlags(interactions)
        self.pin.setVisible(self.selectable and (self.underMouse() or self.pinned))
        if self.selectable:
            self.activateWindow()
            self.result.setFocus()
        if not loading and not self.pinned and not self.underMouse():
            self.timer.start(self.remaining)

    def toggle_pin(self):
        self.pinned = self.pin.isChecked()
        self.pin.setIcon(pin_icon(self.pinned))
        self.pin.setToolTip("已锁定：点按解锁" if self.pinned else "锁定字幕，保持显示")
        if self.pinned:
            self.timer.stop()
        elif not self.underMouse():
            self.timer.start(self.remaining)

    def enterEvent(self, event):
        if self.timer.isActive():
            self.remaining = max(1, self.timer.remainingTime())
        self.timer.stop()
        self.pin.setVisible(self.selectable)
        super().enterEvent(event)

    def leaveEvent(self, event):
        if not self.pinned:
            self.timer.start(self.remaining)
            self.pin.hide()
        super().leaveEvent(event)

    def copy_result(self):
        QApplication.clipboard().setText(self.result.toPlainText())

    def save_position(self):
        self.settings.overlay_position = [self.x(), self.y()]
        self.settings.overlay_center = [self.x() + self.width() // 2, self.y() + self.height() // 2]
        # Controller persists positions together on exit.

    def show_loading(self, text):
        self.show_result("", text, loading=True)
        self.selectable = False
        self.pin.hide()
        self.timer.stop()

    def dismiss_outside(self, point):
        if self.isVisible() and not self.pinned and not self.geometry().contains(point):
            self.hide()

    def eventFilter(self, watched, event):
        if self.isVisible() and event.type() == QEvent.Type.MouseButtonPress:
            self.dismiss_outside(event.globalPosition().toPoint())
        # Selection and Ctrl+C remain native; empty bubble space can be dragged.
        if watched in (self.result.viewport(), self.original.viewport()) and not self.pinned:
            if event.type() == QEvent.Type.MouseButtonPress:
                editor = self.result if watched is self.result.viewport() else self.original
                cursor = editor.cursorForPosition(event.position().toPoint())
                if cursor.atEnd() and event.position().y() > editor.cursorRect(cursor).bottom() + 4:
                    self.mousePressEvent(event)
                    return True
            elif event.type() == QEvent.Type.MouseMove and self.drag_start is not None:
                self.mouseMoveEvent(event)
                return True
            elif event.type() == QEvent.Type.MouseButtonRelease and self.drag_start is not None:
                self.mouseReleaseEvent(event)
                return True
        return super().eventFilter(watched, event)


class RegionSelector(QWidget):
    selected = Signal(object)
    cancelled = Signal()
    selection_changed = Signal(QRect)
    completed = Signal(QRect)

    def __init__(self, screen, screenshot, skin="classic"):
        super().__init__(None, Qt.WindowType.FramelessWindowHint |
                         Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Window)
        self.screenshot = screenshot
        if screenshot.isNull():
            # Used only during the ring entry's fullscreen/focus handoff.
            # Keep this native window transparent while the compositor hides
            # its dock; the eventual frame paints the whole window opaquely.
            self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.skin = skin
        self.pointer = QPoint()
        self.setMouseTracking(True)
        self.screen_geometry = screen.geometry()
        self.start = None
        self.selection = QRect()
        self.setScreen(screen)
        self.setGeometry(self.screen_geometry)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setWindowTitle("拖动选择文字区域 · Esc 取消")
        show_on_all_workspaces(self)

    def paintEvent(self, event):
        if self.screenshot.isNull():
            return
        painter = QPainter(self)
        readout = None
        # Keep the image at its captured scale even if a window manager moves
        # or resizes this window. Local (0, 0) need not be the screen origin.
        origin = self.mapFromGlobal(self.screen_geometry.topLeft())
        painter.drawPixmap(origin, self.screenshot)
        painter.fillRect(self.rect(), QColor(20, 24, 38, 97))
        if not self.selection.isNull():
            painter.save()
            painter.setClipRect(self.selection)
            painter.drawPixmap(origin, self.screenshot)
            painter.restore()
            if self.skin != "classic":
                capture_pet(painter, self.skin, QPointF(self.selection.topLeft()), False)
            painter.setPen(QPen(QColor("#0a0f19"), 3))
            painter.drawRect(self.selection)
            painter.setPen(QPen(QColor("white"), 1))
            painter.drawRect(self.selection)
            if self.skin != "classic":
                capture_pet(painter, self.skin, QPointF(self.selection.topLeft()), True)
            text = "{} × {}".format(self.selection.width(), self.selection.height())
            readout = QRect(self.selection.right() - 120, self.selection.bottom() + 10, 120, 28)
            if readout.bottom() > self.height():
                readout.moveBottom(self.selection.top() - 10)
            readout.moveLeft(max(0, min(readout.left(), self.width() - readout.width())))
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor(18, 23, 33, 240))
            painter.drawRoundedRect(readout, 7, 7)
            painter.setPen(QColor("white"))
            painter.drawText(readout, Qt.AlignmentFlag.AlignCenter, text)
        for color, width in (("#000000", 3), ("#ffffff", 1)):
            painter.setPen(QPen(QColor(color), width))
            painter.drawLine(self.pointer - QPoint(8, 0), self.pointer + QPoint(8, 0))
            painter.drawLine(self.pointer - QPoint(0, 8), self.pointer + QPoint(0, 8))
        painter.setPen(QColor("#ffffff"))
        if self.skin != "classic":
            hint = "拖动框选，松手识别 · Esc 取消"
            font = QFont()
            font.setPixelSize(12)
            painter.setFont(font)
            width = QFontMetrics(font).horizontalAdvance(hint) + 24
            rectangle = QRect((self.width() - width) // 2, self.height() - 56, width, 28)
            if readout is None or not rectangle.intersects(readout):
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor(18, 23, 33, 240))
                painter.drawRoundedRect(rectangle, 7, 7)
                painter.setPen(QColor("white"))
                painter.drawText(rectangle, Qt.AlignmentFlag.AlignCenter, hint)

    def mousePressEvent(self, event):
        if self.screenshot.isNull() and event.button() != Qt.MouseButton.RightButton:
            return
        if event.button() == Qt.MouseButton.LeftButton:
            self.start = event.position().toPoint()
            self.global_start = self.mapToGlobal(self.start)
        elif event.button() == Qt.MouseButton.RightButton:
            self.cancelled.emit()

    def mouseMoveEvent(self, event):
        self.pointer = event.position().toPoint()
        if self.start is not None:
            self.selection = self.selection_rect(event.position().toPoint())
            self.selection_changed.emit(self.global_rect(event.position().toPoint()))
        self.update()

    def selection_rect(self, end):
        # Explicit origin/size avoids QRect's inclusive-corner adjustment when
        # dragging backwards, and gives the same pixels in either direction.
        return QRect(min(self.start.x(), end.x()), min(self.start.y(), end.y()),
                     abs(self.start.x() - end.x()), abs(self.start.y() - end.y())).intersected(self.rect())

    def global_rect(self, end):
        point = self.mapToGlobal(end)
        return QRect(min(self.global_start.x(), point.x()), min(self.global_start.y(), point.y()),
                     abs(self.global_start.x() - point.x()), abs(self.global_start.y() - point.y()))

    def mouseReleaseEvent(self, event):
        if self.start is None or self.screenshot.isNull():
            return
        global_rect = self.global_rect(event.position().toPoint())
        self.selection = self.selection_rect(event.position().toPoint())
        self.start = None
        if self.selection.width() < 8 or self.selection.height() < 8:
            if global_rect.width() >= 8 and global_rect.height() >= 8:
                self.completed.emit(global_rect)
                return
            self.selection = QRect()
            self.update()
            return
        ratio = self.screenshot.devicePixelRatio()
        origin = self.mapToGlobal(self.selection.topLeft()) - self.screen_geometry.topLeft()
        rect = QRect(round(origin.x() * ratio), round(origin.y() * ratio),
                     round(self.selection.width() * ratio), round(self.selection.height() * ratio))
        self.selected.emit(self.screenshot.copy(rect.intersected(self.screenshot.rect())))
        self.completed.emit(global_rect)

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.cancelled.emit()
