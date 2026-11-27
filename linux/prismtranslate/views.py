"""Qt windows: configuration, floating subtitle, launcher and region selection."""

from PySide6.QtCore import QPoint, QRect, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QFormLayout, QHBoxLayout, QLabel,
    QLineEdit, QPushButton, QScrollArea, QSpinBox, QTabWidget, QTextEdit, QVBoxLayout, QWidget,
)

from .core import LANGUAGES, PROVIDERS

STYLE = """
QWidget { font-family: "Noto Sans", "Noto Sans CJK SC", sans-serif;
          font-size: 14px; color: #e8edf5; background: #151c29; }
QLabel#heading { font-size: 24px; font-weight: 600; }
QLabel { background: transparent; }
QLabel#muted { color: #a4b2c8; }
QLineEdit, QComboBox, QSpinBox, QTextEdit {
    background: #202c3e; border: 1px solid #41516a; border-radius: 7px; padding: 7px; }
QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QTextEdit:focus {
    border: 2px solid #a89bff; }
QPushButton { background: #28364c; border: 1px solid #506078;
              border-radius: 7px; padding: 8px 13px; }
QPushButton:hover { background: #354764; }
QPushButton:pressed { background: #465a7c; }
QPushButton:focus { border: 2px solid #b7acff; }
QPushButton:disabled { color: #8190a7; background: #222b3a; }
QPushButton#primary { background: #7561cc; border-color: #a696f0; color: white; }
QPushButton#primary:hover { background: #7a64cd; }
QTabWidget::pane { border: 1px solid #344159; border-radius: 8px; }
QTabBar::tab { padding: 10px 18px; background: #202c3e; }
QTabBar::tab:selected { background: #354764; }
QMenu { background: #202c3e; border: 1px solid #506078; }
QMenu::item { padding: 9px 20px; }
QMenu::item:selected { background: #465a7c; }
QToolTip { color: #e8edf5; background: #28364c; border: 1px solid #506078; }
"""


def label(text, muted=False):
    widget = QLabel(text)
    widget.setTextFormat(Qt.TextFormat.PlainText)
    widget.setWordWrap(True)
    if muted:
        widget.setObjectName("muted")
    return widget


def button(text, callback=None, primary=False):
    widget = QPushButton(text)
    widget.setMinimumHeight(38)
    if callback:
        widget.clicked.connect(callback)
    if primary:
        widget.setObjectName("primary")
    return widget


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

    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.current_provider = settings.provider
        self.setWindowTitle("棱镜翻译 · Linux")
        self.setMinimumSize(480, 500)
        self.resize(600, 740)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 20)
        title = label("棱镜翻译")
        title.setObjectName("heading")
        layout.addWidget(title)
        layout.addWidget(label("让文字跨越语言。剪贴板与截图，随时化作悬浮字幕。", True))
        tasks = QHBoxLayout()
        self.clipboard_button = button("翻译剪贴板", self.clipboard_requested.emit, True)
        self.ocr_button = button("截图识别", lambda: self.capture_requested.emit(False))
        self.capture_button = button("截图翻译", lambda: self.capture_requested.emit(True))
        for widget in (self.clipboard_button, self.ocr_button, self.capture_button):
            tasks.addWidget(widget)
        layout.addLayout(tasks)
        tabs = QTabWidget()
        layout.addWidget(tabs, 1)
        connection = QWidget()
        form = QFormLayout(connection)
        form.setContentsMargins(16, 20, 16, 20)
        self.provider = QComboBox()
        for key, value in PROVIDERS.items():
            self.provider.addItem(value[0], key)
        self.provider.setCurrentIndex(self.provider.findData(settings.provider))
        form.addRow("翻译服务", self.provider)
        self.base_url = QLineEdit()
        form.addRow("API 地址", self.base_url)
        self.api_key = QLineEdit()
        self.api_key.setEchoMode(QLineEdit.EchoMode.Password)
        form.addRow("API Key", self.api_key)
        self.model = QComboBox()
        self.model.setEditable(True)
        self.model.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        form.addRow("模型", self.model)
        self.refresh = button("刷新本机 Ollama 模型", self.models_requested.emit)
        form.addRow("", self.refresh)
        self.model_status = label("", True)
        form.addRow("", self.model_status)
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
        form.addRow(label("Ollama 只连接本机 127.0.0.1:11434，不需要密钥，不会自动下载模型。\n"
                           "远程密钥保存在权限为 600 的本地配置文件中，未加密。", True))
        tabs.addTab(scrollable_tab(connection), "服务与语言")
        appearance = QWidget()
        form2 = QFormLayout(appearance)
        form2.setContentsMargins(16, 20, 16, 20)
        self.watch = QCheckBox("复制文字后自动翻译")
        self.watch.setChecked(settings.watch_clipboard)
        self.original = QCheckBox("字幕同时显示原文")
        self.original.setChecked(settings.show_original)
        self.ball = QCheckBox("显示悬浮棱镜")
        self.ball.setChecked(settings.show_ball)
        self.font_size = QSpinBox()
        self.font_size.setRange(14, 40)
        self.font_size.setSuffix(" px")
        self.font_size.setValue(settings.font_size)
        self.seconds = QSpinBox()
        self.seconds.setRange(2, 60)
        self.seconds.setSuffix(" 秒")
        self.seconds.setValue(settings.seconds)
        self.ocr_languages = QLineEdit(settings.ocr_languages)
        for widget in (self.watch, self.original, self.ball):
            form2.addRow(widget)
        form2.addRow("字幕字号", self.font_size)
        form2.addRow("字幕停留", self.seconds)
        form2.addRow("OCR 语言", self.ocr_languages)
        form2.addRow(label("OCR 使用本地 Tesseract，语言以 + 分隔，例如 eng+chi_sim。\n"
                            "X11：Ctrl+Shift+T 翻译剪贴板。\n"
                            "Wayland：在系统快捷键中绑定 prismtranslate --action translate。\n"
                            "设置窗口：Ctrl+O 从图片识别 · Ctrl+Q 退出。\n"
                            "关闭此窗口后，悬浮棱镜或系统托盘仍可操作；退出请使用菜单。", True))
        tabs.addTab(scrollable_tab(appearance), "字幕与操作")
        self.sample = QTextEdit()
        self.sample.setPlaceholderText("输入或粘贴文字，验证翻译服务…")
        self.sample.setMinimumHeight(72)
        self.sample.setMaximumHeight(100)
        layout.addWidget(self.sample)
        footer = QHBoxLayout()
        self.test_button = button("测试翻译", lambda: self.translate_requested.emit(self.sample.toPlainText()))
        footer.addWidget(self.test_button)
        footer.addStretch()
        self.save_button = button("保存设置", self.save_requested.emit, True)
        footer.addWidget(self.save_button)
        layout.addLayout(footer)
        self.status = label("就绪", True)
        self.status.setAccessibleName("操作状态")
        layout.addWidget(self.status)
        self.provider.currentIndexChanged.connect(self.change_provider)
        self.restore_profile()

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
        self.model.setEditText(profile["model"])
        local = self.current_provider == "ollama"
        self.base_url.setEnabled(not local)
        self.api_key.setEnabled(not local)
        self.refresh.setVisible(local)
        self.model_status.setVisible(local)

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
    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.setWindowTitle("棱镜翻译 · 字幕")
        self.setStyleSheet("QWidget#bubble { background: #192336; border: 1px solid #68769a;"
                          "border-radius: 16px; }")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        self.bubble = QWidget()
        self.bubble.setObjectName("bubble")
        outer.addWidget(self.bubble)
        layout = QVBoxLayout(self.bubble)
        layout.setContentsMargins(20, 14, 20, 18)
        header = QHBoxLayout()
        header.addWidget(label("棱镜翻译", True))
        header.addStretch()
        self.pin = button("固定", self.toggle_pin)
        self.pin.setCheckable(True)
        self.pin.setAccessibleName("固定字幕，停止自动关闭和拖动")
        header.addWidget(self.pin)
        header.addWidget(button("复制", self.copy_result))
        header.addWidget(button("关闭", self.hide))
        layout.addLayout(header)
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

    def show_result(self, original, result, error=False):
        screen = QApplication.screenAt(self.pos()) if self.isVisible() else QApplication.primaryScreen()
        screen = screen or QApplication.primaryScreen()
        available = screen.availableGeometry()
        self.setFixedWidth(min(600, available.width() - 32))
        self.original.setVisible(self.settings.show_original and bool(original))
        self.original.setPlainText(original)
        self.result.setPlainText(result)
        font = QFont("Noto Sans")
        font.setPixelSize(self.settings.font_size)
        self.result.setFont(font)
        self.result.setStyleSheet("QTextEdit { background: transparent; border: 0; padding: 0;"
                                 "font-size: " + str(self.settings.font_size) + "px;"
                                 "color: " + ("#ffc8c0" if error else "#f0f3fa") + "; }")
        for widget, maximum in ((self.original, 110), (self.result, max(120, available.height() // 2))):
            widget.document().setTextWidth(self.width() - 48)
            widget.setFixedHeight(min(maximum, max(38, int(widget.document().size().height()) + 12)))
        self.adjustSize()
        default = QPoint(available.center().x() - self.width() // 2,
                         available.bottom() - self.height() - 64)
        self.move(bounded_position(self, self.settings.overlay_position, default))
        self.remaining = self.settings.seconds * 1000
        self.show()
        self.raise_()
        if not self.pinned and not self.underMouse():
            self.timer.start(self.remaining)

    def toggle_pin(self):
        self.pinned = self.pin.isChecked()
        self.pin.setText("已固定" if self.pinned else "固定")
        if self.pinned:
            self.timer.stop()
        elif not self.underMouse():
            self.timer.start(self.remaining)

    def enterEvent(self, event):
        if self.timer.isActive():
            self.remaining = max(1, self.timer.remainingTime())
        self.timer.stop()
        super().enterEvent(event)

    def leaveEvent(self, event):
        if not self.pinned:
            self.timer.start(self.remaining)
        super().leaveEvent(event)

    def copy_result(self):
        QApplication.clipboard().setText(self.result.toPlainText())

    def save_position(self):
        self.settings.overlay_position = [self.x(), self.y()]
        # Controller persists positions together on exit.


class FloatingBall(DraggableWindow):
    menu_requested = Signal(QPoint)

    def __init__(self, settings, icon):
        super().__init__()
        self.settings, self.icon = settings, icon
        self.setWindowTitle("棱镜翻译 · 悬浮棱镜")
        self.setAccessibleName("棱镜翻译操作菜单，可拖动")
        self.setFixedSize(64, 64)
        self.setToolTip("点击打开翻译与截图菜单 · 拖动移动")
        self.busy = False
        available = QApplication.primaryScreen().availableGeometry()
        self.move(bounded_position(self, settings.ball_position,
                                   QPoint(available.right() - 88, available.center().y())))
        self.moved.connect(lambda: setattr(settings, "ball_position", [self.x(), self.y()]))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setBrush(QColor("#27334d"))
        painter.setPen(QPen(QColor("#bdadff" if self.busy else "#7183aa"), 2))
        painter.drawEllipse(3, 3, 58, 58)
        self.icon.paint(painter, QRect(13, 13, 38, 38))

    def mouseReleaseEvent(self, event):
        was_dragged = self.dragged
        super().mouseReleaseEvent(event)
        if event.button() in (Qt.MouseButton.LeftButton, Qt.MouseButton.RightButton) and not was_dragged:
            self.menu_requested.emit(event.globalPosition().toPoint())
        self.dragged = False


class RegionSelector(QWidget):
    selected = Signal(object)
    cancelled = Signal()

    def __init__(self, screen, screenshot):
        super().__init__(None, Qt.WindowType.FramelessWindowHint |
                         Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.screenshot = screenshot
        self.start = None
        self.selection = QRect()
        self.setGeometry(screen.geometry())
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setWindowTitle("拖动选择文字区域 · Esc 取消")

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.drawPixmap(self.rect(), self.screenshot)
        painter.fillRect(self.rect(), QColor(8, 14, 27, 145))
        if not self.selection.isNull():
            painter.save()
            painter.setClipRect(self.selection)
            painter.drawPixmap(self.rect(), self.screenshot)
            painter.restore()
            painter.setPen(QPen(QColor("#c5b8ff"), 2))
            painter.drawRect(self.selection)
        painter.setPen(QColor("#ffffff"))
        painter.drawText(QRect(24, 24, self.width() - 48, 60),
                         Qt.AlignmentFlag.AlignLeft, "拖动选择文字区域   ·   Esc 取消")

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.start = event.position().toPoint()

    def mouseMoveEvent(self, event):
        if self.start is not None:
            self.selection = self.selection_rect(event.position().toPoint())
            self.update()

    def selection_rect(self, end):
        # Explicit origin/size avoids QRect's inclusive-corner adjustment when
        # dragging backwards, and gives the same pixels in either direction.
        return QRect(min(self.start.x(), end.x()), min(self.start.y(), end.y()),
                     abs(self.start.x() - end.x()), abs(self.start.y() - end.y())).intersected(self.rect())

    def mouseReleaseEvent(self, event):
        if self.start is None:
            return
        self.selection = self.selection_rect(event.position().toPoint())
        self.start = None
        if self.selection.width() < 8 or self.selection.height() < 8:
            self.selection = QRect()
            self.update()
            return
        ratio = self.screenshot.devicePixelRatio()
        rect = QRect(round(self.selection.x() * ratio), round(self.selection.y() * ratio),
                     round(self.selection.width() * ratio), round(self.selection.height() * ratio))
        self.selected.emit(self.screenshot.copy(rect))

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            self.cancelled.emit()
