"""Floating pet and the product's hold-to-select quick-action ring."""

import math
import random
import time

from PySide6.QtCore import QEvent, QPoint, QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QCursor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QApplication, QLabel, QWidget

from .pet import head
from .desktop import show_on_all_workspaces
from .views import DraggableWindow, bounded_position


def ring_action(point, center, press, previous=None, busy=False):
    """The same 36/76/96 pt geometry and seams as BallSelectionGeometry."""
    if math.hypot(point.x() - press.x(), point.y() - press.y()) < 36:
        return None
    dx, dy = point.x() - center.x(), point.y() - center.y()
    if not 36 <= math.hypot(dx, dy) <= 96:
        return None
    seam = abs(dy) < 2 or (dy < 0 and abs(dx) < 2)
    candidate = previous if seam else ("watch" if dy > 0 else ("ocr" if dx < 0 else "ocr-translate"))
    return None if busy and candidate != "watch" else candidate


class QuickRing(QWidget):
    def __init__(self, ball):
        # Keep these as top-level tools, transient to the focused ball. An
        # unowned Tool maps against the client leader on X11; Mutter marks it
        # demands-attention, which makes Ubuntu Dock reveal the app icon.
        super().__init__(ball, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint |
                         Qt.WindowType.WindowStaysOnTopHint)
        self.ball = ball
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setFixedSize(168, 168)
        self.setAccessibleName("快捷操作环：OCR、OCR翻译、自动监听粘贴板")
        self.selected = None
        self.selected_at = 0
        self.press = QPoint()
        self.bubble = QLabel(ball, Qt.WindowType.Tool | Qt.WindowType.FramelessWindowHint |
                             Qt.WindowType.WindowStaysOnTopHint)
        self.bubble.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.bubble.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.bubble.setStyleSheet("QLabel {background: rgba(24,28,36,240); color: white;"
                                 "border: 1px solid #687080; border-radius: 7px; padding: 6px 10px;}")
        self.label_timer = QTimer(self)
        self.label_timer.setSingleShot(True)
        self.label_timer.setInterval(500)
        self.label_timer.timeout.connect(self.reveal_label)

    def begin(self, press):
        self.press = press
        screen = QApplication.screenAt(press) or QApplication.primaryScreen()
        self.available = screen.availableGeometry()
        center = self.ball.mapToGlobal(QPoint(36, 39))
        center.setX(max(self.available.left() + 84, min(center.x(), self.available.right() - 84)))
        center.setY(max(self.available.top() + 84, min(center.y(), self.available.bottom() - 84)))
        self.move(center - QPoint(84, 84))
        self.selected = None
        self.shown_at = time.monotonic()
        show_on_all_workspaces(self)
        self.show()
        self.raise_()
        self.update_pointer(press)

    def update_pointer(self, point):
        candidate = ring_action(point, self.pos() + QPoint(84, 84), self.press,
                                self.selected, self.ball.busy)
        if candidate != self.selected:
            self.selected = candidate
            self.selected_at = time.monotonic()
            self.bubble.hide()
            self.label_timer.stop()
            if candidate:
                self.label_timer.start()
        self.setWindowOpacity(.4 if math.hypot(point.x() - self.x() - 84, point.y() - self.y() - 84) > 96 else 1)
        self.update()

    def reveal_label(self):
        if not self.isVisible() or not self.selected:
            return
        titles = {"ocr": "OCR", "ocr-translate": "OCR翻译",
                  "watch": "自动监听粘贴板  " + ("开" if self.ball.settings.watch_clipboard else "关")}
        self.bubble.setText(titles[self.selected])
        self.bubble.adjustSize()
        center = self.pos() + QPoint(84, 84)
        # Prefer the nearest free side, keeping label and pointer targets apart.
        y = center.y() + 88 if self.selected == "watch" else center.y() - 88 - self.bubble.height()
        if y < self.available.top() or y + self.bubble.height() > self.available.bottom():
            y = center.y() - self.bubble.height() // 2
            x = center.x() + 88
            if x + self.bubble.width() > self.available.right():
                x = center.x() - 88 - self.bubble.width()
        else:
            x = center.x() - self.bubble.width() // 2
        x = max(self.available.left(), min(x, self.available.right() - self.bubble.width()))
        self.bubble.move(x, y)
        show_on_all_workspaces(self.bubble)
        self.bubble.show()

    def cancel(self):
        self.label_timer.stop()
        self.bubble.hide()
        self.hide()
        self.selected = None

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.translate(84, 84)
        if not self.ball.settings.reduce_motion:
            scale = .9 + .1 * min(1, (time.monotonic() - self.shown_at) / .12)
            painter.scale(scale, scale)
        # Qt screen coordinates point down; top-left/top-right map to OCR.
        sectors = {"ocr": (90, 180), "ocr-translate": (0, 90), "watch": (180, 360)}
        for action, (start, end) in sectors.items():
            painter.save()
            shape = QPainterPath()
            first_point = True
            for radius, angles in ((76, range(start + 2, end - 1, 2)),
                                   (36, range(end - 4, start + 3, -2))):
                for angle in angles:
                    radians = math.radians(angle)
                    point = QPointF(radius * math.cos(radians), -radius * math.sin(radians))
                    if first_point:
                        shape.moveTo(point)
                        first_point = False
                    else:
                        shape.lineTo(point)
            shape.closeSubpath()
            painter.setOpacity(.4 if self.ball.busy and action != "watch" else 1)
            chosen = self.selected == action
            if chosen and not self.ball.settings.reduce_motion:
                scale = 1 + .06 * min(1, (time.monotonic() - self.selected_at) / .1)
                painter.scale(scale, scale)
            painter.setBrush(self.palette().highlight() if chosen else QColor(235, 238, 244, 235))
            painter.setPen(QPen(QColor("#99a2b0"), .5))
            painter.drawPath(shape)
            painter.setPen(self.palette().highlightedText().color() if chosen else QColor("#242c38"))
            icon_center = {"ocr": QPointF(-40, -40), "ocr-translate": QPointF(40, -40),
                           "watch": QPointF(0, 56)}[action]
            painter.save()
            painter.translate(icon_center)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(QPen(painter.pen().color(), 1.4))
            if action == "watch":
                painter.drawRoundedRect(QRectF(-7, -8, 14, 16), 2, 2)
                painter.drawLine(-3, -3, 4, -3)
                painter.drawLine(-3, 1, 4, 1)
            elif action == "ocr":
                for x, y, dx, dy in ((-8, -8, 1, 1), (8, -8, -1, 1), (-8, 8, 1, -1), (8, 8, -1, -1)):
                    painter.drawLine(x, y, x + dx * 5, y)
                    painter.drawLine(x, y, x, y + dy * 5)
                painter.drawLine(-3, -2, 3, -2)
                painter.drawLine(-3, 2, 3, 2)
            else:
                font = QFont()
                font.setPixelSize(15)
                painter.setFont(font)
                painter.drawText(QRectF(-9, -10, 18, 20), Qt.AlignmentFlag.AlignCenter, "译")
            painter.restore()
            painter.restore()


class FloatingBall(DraggableWindow):
    menu_requested = Signal(QPoint)
    quick_action = Signal(str)

    def __init__(self, settings, icon):
        super().__init__()
        self.settings = settings
        self.setFixedSize(72, 72)
        self.setWindowTitle("棱镜翻译 · 悬浮球")
        self.setAccessibleName("棱镜翻译悬浮球")
        self.setAccessibleDescription("单击打开菜单；长按选择 OCR、OCR翻译或自动监听粘贴板；按住拖动移动。")
        self.setToolTip("单击打开菜单 · 长按快速选择 · 拖动移动")
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.ring = QuickRing(self)
        self.phase = "idle"
        self.busy = False
        self.mood = "idle"
        self.started = time.monotonic()
        self.interaction = self.started
        self.mood_start = self.started
        self.blink_start = -1
        self.next_blink = self.started + 3
        self.gaze = (0, 0)
        self.hover = 0
        self.headphone_opacity = float(settings.watch_clipboard)
        self.timer = QTimer(self)
        self.timer.setInterval(33)
        self.timer.timeout.connect(self.tick)
        self.hold = QTimer(self)
        self.hold.setSingleShot(True)
        self.hold.setInterval(400)
        self.hold.timeout.connect(self.begin_ring)
        available = QApplication.primaryScreen().availableGeometry()
        self.move(bounded_position(self, settings.ball_position,
                                   QPoint(available.right() - 88, available.center().y())))
        QApplication.instance().installEventFilter(self)
        for screen in QApplication.screens():
            screen.availableGeometryChanged.connect(self.ensure_reachable)
        QApplication.instance().screenAdded.connect(self.screen_added)
        QApplication.instance().screenRemoved.connect(self.ensure_reachable)

    def screen_added(self, screen):
        screen.availableGeometryChanged.connect(self.ensure_reachable)
        self.ensure_reachable()

    def ensure_reachable(self, *_):
        self.cancel_gesture()
        self.move(bounded_position(self, [self.x(), self.y()], self.pos()))

    def set_mood(self, mood):
        self.mood = mood
        self.mood_start = self.interaction = time.monotonic()
        self.update()

    def tick(self):
        now = time.monotonic()
        if self.mood in ("happy", "sad") and now - self.mood_start > (1.4 if self.mood == "happy" else 1.6):
            self.mood = "idle"
        pointer = QCursor.pos() - self.mapToGlobal(QPoint(36, 39))
        distance = math.hypot(pointer.x(), pointer.y())
        hovered = distance <= 25
        if hovered or self.phase != "idle":
            self.interaction = now
        self.hover += (float(hovered) - self.hover) * .37
        if self.busy:
            angle = -(now - self.started) * math.pi * 1.8
            target = (math.cos(angle), math.sin(angle))
        else:
            target = (pointer.x() / max(160, distance), -pointer.y() / max(160, distance))
        self.gaze = tuple(old + (new - old) * .37 for old, new in zip(self.gaze, target))
        self.headphone_opacity += (float(self.settings.watch_clipboard) - self.headphone_opacity) * .3
        if now >= self.next_blink:
            self.blink_start = now
            self.next_blink = now + random.uniform(2.5, 6)
        if self.phase == "selecting":
            self.ring.update_pointer(QCursor.pos())
        self.update()

    def showEvent(self, event):
        self.interaction = time.monotonic()
        self.timer.start()
        super().showEvent(event)

    def hideEvent(self, event):
        self.timer.stop()
        self.cancel_gesture()
        super().hideEvent(event)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        now = time.monotonic()
        elapsed = now - self.started
        sleeping = not self.busy and self.mood == "idle" and now - self.interaction > 90
        still = self.settings.reduce_motion
        scale = 1 + .06 * self.hover - (.08 if self.phase == "pressing" else 0)
        offset_x = offset_y = 0
        if not still:
            scale += math.sin(elapsed * math.pi * 2 / (4.5 if sleeping else 3.2)) * (.025 if sleeping else .012)
            age = now - self.mood_start
            if self.mood == "happy" and age < .7:
                offset_y = -abs(math.sin(age / .35 * math.pi)) * 3
            elif self.mood == "sad" and age < .5:
                offset_x = math.sin(age * 50) * (1 - age / .5) * 2.5
        painter.translate(36 + offset_x, 39 + offset_y)
        painter.scale(scale, scale)
        for radius in range(28, 23, -1):
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor(0, 0, 0, (29 - radius) * 3))
            painter.drawEllipse(QRectF(-radius, -radius + 3, radius * 2, radius * 2))
        blink_age = now - self.blink_start
        openness = 1 if still or not 0 <= blink_age < .16 else 1 - math.sin(blink_age / .16 * math.pi)
        mood = "busy" if self.busy else ("happy" if self.phase == "pressing" else self.mood)
        head(painter, self.settings.ball_skin, mood,
             (0, 0) if still else self.gaze, openness, sleeping,
             float(self.settings.watch_clipboard) if still else self.headphone_opacity, 0 if still else elapsed)
        if self.phase == "pressing":
            progress = min(1, (now - self.press_time) / .4)
            painter.setPen(QPen(self.palette().highlight().color(), 1.2))
            painter.drawArc(QRectF(-32, -32, 64, 64), 90 * 16, -round(progress * 360 * 16))

    def mousePressEvent(self, event):
        self.interaction = time.monotonic()
        if event.button() == Qt.MouseButton.LeftButton:
            self.cancel_gesture()
            self.press_point = event.globalPosition().toPoint()
            self.press_origin = self.pos()
            self.press_time = time.monotonic()
            self.phase = "pressing"
            self.hold.start()
        elif event.button() == Qt.MouseButton.RightButton:
            self.cancel_gesture()
            self.menu_requested.emit(event.globalPosition().toPoint())

    def mouseMoveEvent(self, event):
        point = event.globalPosition().toPoint()
        if self.phase == "pressing" and math.hypot(point.x() - self.press_point.x(), point.y() - self.press_point.y()) > 5:
            self.hold.stop()
            self.phase = "dragging"
        if self.phase == "dragging":
            self.move(self.press_origin + point - self.press_point)
        elif self.phase == "selecting":
            self.ring.update_pointer(point)

    def begin_ring(self):
        if self.phase == "pressing":
            self.phase = "selecting"
            self.ring.begin(self.press_point)

    def mouseReleaseEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        phase = self.phase
        selected = self.ring.selected
        self.cancel_gesture()
        if phase == "selecting":
            if selected:
                # Hide both ring and label before capture starts.
                self.quick_action.emit(selected)
        elif phase == "dragging":
            self.settle()
        elif phase == "pressing":
            self.menu_requested.emit(event.globalPosition().toPoint())

    def settle(self):
        point = bounded_position(self, [self.x(), self.y()], self.pos())
        screen = QApplication.screenAt(self.mapToGlobal(QPoint(36, 39))) or QApplication.primaryScreen()
        available = screen.availableGeometry()
        left, right = available.left() - 7, available.right() - 65
        if point.x() - left < 48:
            point.setX(left)
        elif right - point.x() < 48:
            point.setX(right)
        self.move(point)
        self.settings.ball_position = [self.x(), self.y()]
        self.moved.emit()

    def cancel_gesture(self):
        self.hold.stop()
        self.ring.cancel()
        self.phase = "idle"
        self.update()

    def eventFilter(self, watched, event):
        if self.phase != "idle" and event.type() in (QEvent.Type.ApplicationDeactivate, QEvent.Type.WindowDeactivate):
            if event.type() == QEvent.Type.ApplicationDeactivate or watched is self:
                self.cancel_gesture()
        if self.phase != "idle" and event.type() == QEvent.Type.KeyPress and event.key() == Qt.Key.Key_Escape:
            self.cancel_gesture()
            return True
        return super().eventFilter(watched, event)

    def keyPressEvent(self, event):
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Space):
            self.menu_requested.emit(self.mapToGlobal(QPoint(36, 39)))
        elif event.key() == Qt.Key.Key_Escape:
            self.cancel_gesture()
