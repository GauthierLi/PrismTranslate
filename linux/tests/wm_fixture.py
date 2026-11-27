"""Validate fullscreen selection against a real WM and reserved top panel.

This is Openbox/EWMH coverage; GNOME on 5080 must still be tested separately.
"""

import json
from pathlib import Path
import subprocess
import time

from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPixmap
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QWidget

from prismtranslate.views import RegionSelector

app = QApplication([])
app.setQuitOnLastWindowClosed(False)
manager = subprocess.Popen(["openbox"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
screen = app.primaryScreen()
geometry = screen.geometry()
panel = QWidget(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint)
panel.setAttribute(Qt.WidgetAttribute.WA_X11NetWmWindowTypeDock)
panel.setGeometry(geometry.x(), geometry.y(), geometry.width(), 27)
panel.setStyleSheet("background: #222733;")


def until(condition):
    deadline = time.monotonic() + 5
    while not condition() and time.monotonic() < deadline:
        app.processEvents()
        QTest.qWait(20)
    if not condition():
        print("Qt available geometry:", screen.availableGeometry(), flush=True)
        print("WM process:", manager.poll(), flush=True)
        print(subprocess.check_output(["xprop", "-root", "_NET_SUPPORTING_WM_CHECK", "_NET_WORKAREA", "_NET_CLIENT_LIST"], text=True), flush=True)
        print(subprocess.check_output(["ps", "-o", "pid,state,pcpu,wchan,comm", "-p", str(manager.pid)], text=True), flush=True)
        print(subprocess.check_output(["xwininfo", "-id", str(int(panel.winId()))], text=True), flush=True)
        print(subprocess.check_output(["xprop", "-id", str(int(panel.winId())), "_NET_WM_WINDOW_TYPE",
                                       "_NET_WM_STRUT", "_NET_WM_STRUT_PARTIAL"], text=True), flush=True)
        raise AssertionError("WM fixture timed out")


try:
    until(lambda: b"_NET_SUPPORTING_WM_CHECK(WINDOW)" in subprocess.check_output(
        ["xprop", "-root", "_NET_SUPPORTING_WM_CHECK"]))
    QTest.qWait(250)
    # Use Qt's dock attribute so show() retains the EWMH type.
    identifier = str(int(panel.winId()))
    for name, value in (("_NET_WM_STRUT", "0, 0, 27, 0"),
                        ("_NET_WM_STRUT_PARTIAL", "0, 0, 27, 0, 0, 0, 0, 0, 0, 1279, 0, 0")):
        subprocess.run(["xprop", "-id", identifier, "-f", name, "32c", "-set", name, value],
                       check=True, stdout=subprocess.DEVNULL)
    panel.show()
    until(lambda: screen.availableGeometry().top() == geometry.top() + 27)
    image = QPixmap(geometry.size())
    image.fill(QColor("white"))
    painter = QPainter(image)
    font = QFont("DejaVu Sans")
    font.setPixelSize(30)
    painter.setFont(font)
    painter.setPen(QColor("black"))
    for y in (80, 420, 800):
        painter.drawText(100, y + 30, "Hello PrismTranslate")
    painter.end()
    selector = RegionSelector(screen, image)
    # Openbox honors explicit placement differently from GNOME. Start in its
    # reserved workarea, then verify fullscreen escapes that area completely.
    selector.setGeometry(screen.availableGeometry())
    selector.show()
    until(lambda: selector.geometry().top() == geometry.top() + 27)
    constrained = selector.geometry()
    selector.showFullScreen()
    until(lambda: selector.geometry() == geometry)
    received = []
    selector.selected.connect(received.append)
    for y in (80, 420, 800):
        for reverse in (False, True):
            first, last = QPoint(90, y - 5), QPoint(450, y + 45)
            if reverse:
                first, last = last, first
            QTest.mousePress(selector, Qt.MouseButton.LeftButton, pos=first)
            QTest.mouseMove(selector, last)
            QTest.mouseRelease(selector, Qt.MouseButton.LeftButton, pos=last)
            assert received[-1].toImage() == image.copy(QRect(90, y - 5, 360, 50)).toImage()
    print(json.dumps({"wm": "Openbox/EWMH", "top_panel": 27,
                      "ordinary_geometry": [constrained.x(), constrained.y(), constrained.width(), constrained.height()],
                      "fullscreen_geometry": [selector.x(), selector.y(), selector.width(), selector.height()],
                      "pixel_comparisons": 6, "result": "passed"}))
    verification = Path("/verification")
    if verification.is_dir():
        selector.grab().save(str(verification / "top-panel-fullscreen.png"))
    selector.close()
finally:
    panel.close()
    manager.terminate()
    manager.wait(timeout=5)
    errors = manager.stderr.read().decode(errors="replace")
    if errors:
        print("WM stderr:", errors)
