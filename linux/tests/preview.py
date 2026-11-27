"""Render test-owned Qt windows under Xvfb; no real credentials or API calls."""

import sys
import atexit
import subprocess
from pathlib import Path
from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import QIcon, QPalette, QColor
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QWidget
from prismtranslate.core import Settings
from prismtranslate.floating import FloatingBall
from prismtranslate.pet import SKINS
from prismtranslate.views import RegionSelector, SettingsWindow, Subtitle, apply_theme

app = QApplication([])
compositor = subprocess.Popen(["xcompmgr", "-n"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_compositor():
    if compositor.poll() is None:
        compositor.terminate()
        compositor.wait(timeout=3)


atexit.register(stop_compositor)
QTest.qWait(150)
assert compositor.poll() is None, "compositor failed to start"
if "--dark" in sys.argv:
    palette = app.palette()
    for role, color in ((QPalette.ColorRole.Window, "#242830"), (QPalette.ColorRole.WindowText, "#edf0f5"),
                        (QPalette.ColorRole.Base, "#191d25"), (QPalette.ColorRole.Text, "#edf0f5"),
                        (QPalette.ColorRole.Button, "#323842"), (QPalette.ColorRole.ButtonText, "#edf0f5"),
                        (QPalette.ColorRole.Mid, "#808a99"), (QPalette.ColorRole.Highlight, "#7561cc"),
                        (QPalette.ColorRole.HighlightedText, "#ffffff")):
        palette.setColor(role, QColor(color))
    app.setPalette(palette)
apply_theme(app)
background = QWidget()
background.setWindowFlags(background.windowFlags() | Qt.WindowType.FramelessWindowHint)
background.setStyleSheet("background: #cbd5e3;" if "--dark" not in sys.argv else "background: #303946;")
background.setGeometry(app.primaryScreen().geometry())
background.showFullScreen()
settings = Settings()
window = SettingsWindow(settings)
window.move(25, 25)
window.sample.setPlainText("Hello, PrismTranslate!\nTranslate clipboard text into floating subtitles.")
window.status.setText("Linux / Xvfb 界面验证示例")
window.show()
subtitle = Subtitle(settings)
subtitle.show_result("Hello, PrismTranslate!", "你好，棱镜翻译！\n让剪贴板与截图文字化作悬浮字幕。")
subtitle.move(650, 240)
balls, labels = [], []
for index, (skin, name) in enumerate(SKINS.items()):
    pet_settings = Settings(ball_skin=skin, reduce_motion=True)
    ball = FloatingBall(pet_settings, QIcon())
    ball.move(650 + index * 110, 70)
    ball.show()
    balls.append(ball)
    caption = QLabel(name)
    caption.move(655 + index * 110, 150)
    caption.show()
    labels.append(caption)
demo = FloatingBall(Settings(ball_skin="shiba", watch_clipboard=True, reduce_motion=True), QIcon())
demo.move(870, 550)
demo.show()
balls.append(demo)
ring = demo.ring
ring.begin(demo.mapToGlobal(QPoint(36, 39)))
ring.update_pointer(ring.pos() + QPoint(124, 44))
QTest.qWait(550)
app.processEvents()
QTest.qWait(150)
assert app.primaryScreen().grabWindow(0).save(sys.argv[1])
selector = RegionSelector(app.primaryScreen(), app.primaryScreen().grabWindow(0), "chick")
selector.selection = QRect(240, 240, 350, 240)
selector.pointer = selector.selection.bottomRight()
selector.showFullScreen()
QTest.qWait(150)
output = Path(sys.argv[1])
assert selector.grab().save(str(output.with_name(output.stem + "-capture.png")))
selector.close()
for ball in balls:
    ball.hide()
