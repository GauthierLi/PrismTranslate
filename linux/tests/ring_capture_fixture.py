"""Ring capture against Openbox, a compositor and an auto-hiding bottom dock.

The dock hides only after the selector is actually active/fullscreen. Capturing
before mapping the selector therefore bakes its red icons into the OCR frame.
This models the reported ordering bug; it does not replace GNOME regression.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from unittest.mock import patch

from PySide6.QtCore import QPoint, QRect, Qt, QTimer
from PySide6.QtGui import QColor, QCursor, QImage, QPainter, QPixmap
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QWidget

from prismtranslate.app import Controller
from prismtranslate.core import Settings
from prismtranslate.desktop import x11_compositing_active

app = QApplication([])
app.setQuitOnLastWindowClosed(False)
processes = []


def until(condition, seconds=5):
    deadline = time.monotonic() + seconds
    while not condition() and time.monotonic() < deadline:
        QTest.qWait(20)
    if not condition():
        ball = controller.ball if controller else None
        if ball:
            print("gesture state:", ball.phase, "busy:", ball.busy,
                  "ring visible:", ball.ring.isVisible(), "selected:", ball.ring.selected,
                  "cursor:", QCursor.pos(), "ring:", ball.ring.pos(),
                  "press:", ball.ring.press, flush=True)
        raise AssertionError("ring capture fixture timed out")


def pointer(*arguments):
    subprocess.run(["xdotool", *map(str, arguments)], check=True, timeout=3)


def mapped_at(widget, origin):
    details = subprocess.check_output(["xwininfo", "-id", str(int(widget.winId()))],
                                      text=True, timeout=3)
    return "IsViewable" in details and all(re.search(
        r"Absolute upper-left " + axis + r":\s+" + str(value) + r"\b", details)
        for axis, value in (("X", origin.x()), ("Y", origin.y())))


def same_pixels(actual, expected):
    return actual.convertToFormat(QImage.Format.Format_RGB32) == expected.convertToFormat(
        QImage.Format.Format_RGB32)


with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
    "XDG_CONFIG_HOME": temporary, "XDG_SESSION_TYPE": "x11",
}):
    controller = None
    try:
        for command in (["openbox"], ["xcompmgr", "-n"]):
            processes.append(subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                              stderr=subprocess.PIPE))
        until(lambda: b"_NET_SUPPORTING_WM_CHECK(WINDOW)" in subprocess.check_output(
            ["xprop", "-root", "_NET_SUPPORTING_WM_CHECK"]))
        QTest.qWait(250)
        until(x11_compositing_active)
        screen = app.primaryScreen()
        geometry = screen.geometry()
        image = QPixmap(geometry.size())
        painter = QPainter(image)
        for y in range(image.height()):
            painter.fillRect(0, y, image.width(), 1, QColor(y % 127, 180, 210))
        painter.end()
        # An ordinary page keeps Openbox from independently hiding the dock
        # when the ball is hidden; only the selector's fullscreen handoff may
        # cover it. This makes the old capture-before-map order observable.
        page = QLabel(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Window)
        page.setPixmap(image)
        page.setGeometry(geometry)
        page.show()
        server = QLocalServer()
        endpoint = str(Path(temporary) / "fixture.sock")
        assert server.listen(endpoint)
        controller = Controller(app, Settings(provider="openai", ball_skin="classic"), server)
        controller.window.hide()
        ball = controller.ball
        ball.move(geometry.center() - QPoint(36, 39))
        # GNOME Dock is a shell overlay, outside normal client stacking. An
        # override-redirect window models that until the shell policy below
        # hides it when the selector becomes active/fullscreen.
        dock = QWidget(None, Qt.WindowType.FramelessWindowHint |
                       Qt.WindowType.WindowStaysOnTopHint |
                       Qt.WindowType.X11BypassWindowManagerHint)
        dock.setAttribute(Qt.WidgetAttribute.WA_X11NetWmWindowTypeDock)
        dock.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        dock.setWindowFlag(Qt.WindowType.WindowDoesNotAcceptFocus)
        dock.setGeometry(geometry.x(), geometry.bottom() - 89, geometry.width(), 90)
        dock.setStyleSheet("background: #ff0033")
        dock_timer = QTimer()
        dock_timer.setInterval(20)
        dock_timer.timeout.connect(lambda: dock.hide() if any(
            selector.isFullScreen() and selector.isActiveWindow()
            for selector in controller.selectors) else None)
        dock_timer.start()
        crops = []
        controller.region_selected = lambda frame, settings, translate_result: crops.append(
            (frame, translate_result))
        comparisons = 0
        for action in ("ocr", "ocr-translate"):
            for reverse in (False, True):
                print("ring:", action, "reverse:", reverse, flush=True)
                page.raise_()
                page.activateWindow()
                ball.show()
                ball.raise_()
                ball.activateWindow()
                until(ball.isActiveWindow)
                until(lambda: mapped_at(ball, geometry.center() - QPoint(36, 39)))
                dock.show()
                dock.raise_()
                QTest.qWait(100)
                dirty = app.primaryScreen().grabWindow(0).toImage()
                probe = QPoint(160, geometry.height() - 40)
                assert dirty.pixelColor(probe) == QColor("#ff0033"), "dock was not exposed"
                center = ball.mapToGlobal(QPoint(36, 39))
                pointer("mousemove", center.x(), center.y(), "mousedown", 1)
                until(lambda: ball.ring.isVisible())
                # QWidget visibility precedes Openbox's MapRequest/configure.
                # Its transient (0,0) position must not become our test target.
                until(lambda: mapped_at(ball.ring, center - QPoint(84, 84)))
                target = center + QPoint(-40 if action == "ocr" else 40, -40)
                pointer("mousemove", target.x(), target.y())
                until(lambda: ball.ring.selected == action)
                pointer("mouseup", 1)
                until(lambda: bool(controller.selectors))
                selector = controller.selectors[0]
                until(lambda: not selector.screenshot.isNull())
                until(lambda: not dock.isVisible() and selector.isActiveWindow() and selector.isFullScreen())
                assert not dock.isVisible(), "dock did not hide after fullscreen"
                assert selector.isActiveWindow() and selector.isFullScreen()
                assert selector.mapToGlobal(QPoint(0, 0)) == geometry.topLeft()
                assert selector.size() == geometry.size()
                assert selector.screenshot.toImage().pixelColor(probe) == image.toImage().pixelColor(probe)
                # Clear preview pixels and the actual OCR crop must agree with
                # the controlled page, including the bottom dock strip.
                for y in (35, geometry.height() // 2, geometry.height() - 75):
                    rectangle = QRect(100, y, 650, 50)
                    first, last = rectangle.topLeft(), rectangle.topLeft() + QPoint(650, 50)
                    if reverse:
                        first, last = last, first
                    QTest.mousePress(selector, Qt.MouseButton.LeftButton, pos=first)
                    QTest.mouseMove(selector, last)
                    QTest.qWait(30)
                    interior = QRect(110, y + 10, 620, 25)
                    assert same_pixels(selector.grab().toImage().copy(interior),
                                       image.toImage().copy(interior)), ("preview", action, y, reverse)
                    QTest.mouseRelease(selector, Qt.MouseButton.LeftButton, pos=last)
                    frame, translated = crops[-1]
                    assert translated == (action == "ocr-translate")
                    assert same_pixels(frame.toImage(), image.copy(rectangle).toImage()), (action, y, reverse)
                    comparisons += 1
                destination = Path("/verification")
                if destination.is_dir():
                    selector.grab().save(str(destination / ("ring-" + action + "-bottom.png")))
                    crops[-1][0].save(str(destination / ("ring-" + action + "-crop.png")))
                controller.cancel_capture()
                assert not controller.busy and ball.isVisible()
                QTest.qWait(50)

        # The three existing entry points still freeze before showing the
        # selector. Keep the dock hidden as in their original regression.
        dock_timer.stop()
        dock.hide()
        for entry in ("IPC", "menu", "hotkey"):
            page.raise_()
            page.activateWindow()
            QTest.qWait(100)
            if entry == "IPC":
                socket = QLocalSocket()
                socket.connectToServer(endpoint)
                assert socket.waitForConnected(1000)
                socket.write(b"ocr\n")
                assert socket.waitForBytesWritten(1000)
            elif entry == "menu":
                controller.menu.actions()[1].trigger()
            else:
                controller.settings.mode = "ocr"
                pointer("key", "ctrl+shift+t")
            until(lambda: bool(controller.selectors))
            selector = controller.selectors[0]
            until(lambda: selector.isActiveWindow() and selector.isFullScreen() and
                  mapped_at(selector, geometry.topLeft()))
            assert not selector.testAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
            rectangle = QRect(100, geometry.height() - 75, 650, 50)
            QTest.mousePress(selector, Qt.MouseButton.LeftButton, pos=rectangle.topLeft())
            QTest.mouseRelease(selector, Qt.MouseButton.LeftButton,
                               pos=rectangle.topLeft() + QPoint(650, 50))
            assert same_pixels(crops[-1][0].toImage(), image.copy(rectangle).toImage()), entry
            controller.cancel_capture()
            if entry == "IPC":
                socket.close()
            QTest.qWait(50)

        # Cancel before the frame is frozen; the pending timer must not revive
        # the closed selector or start OCR.
        controller.quick_action("ocr")
        until(lambda: bool(controller.selectors))
        assert controller.selectors[0].screenshot.isNull()
        QTest.keyClick(controller.selectors[0], Qt.Key.Key_Escape)
        QTest.qWait(700)
        assert not controller.selectors and not controller.busy and ball.isVisible()
        # Busy gestures stay ignored at the common capture guard.
        controller.busy = True
        controller.quick_action("ocr")
        QTest.qWait(700)
        assert not controller.selectors
        controller.busy = False
        # The same ring request on a desktop without a compositor must use the
        # original path instead of freezing a black transparent window.
        compositor = processes.pop()
        compositor.terminate()
        compositor.wait(timeout=5)
        until(lambda: not x11_compositing_active())
        page.raise_()
        page.activateWindow()
        controller.quick_action("ocr")
        until(lambda: bool(controller.selectors))
        selector = controller.selectors[0]
        assert not selector.testAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        assert selector.screenshot.toImage().pixelColor(probe) == image.toImage().pixelColor(probe)
        controller.cancel_capture()
        print(json.dumps({"wm": "Openbox", "compositor": "xcompmgr",
                          "exposed_bottom_dock": 90, "ring_entries": 4,
                          "preview_and_crop_comparisons": comparisons,
                          "existing_entries": ["IPC", "menu", "hotkey"],
                          "cancel_before_freeze": "passed", "busy_guard": "passed",
                          "no_compositor_fallback": "passed",
                          "result": "passed"}))
    finally:
        if controller:
            controller.cleanup()
        for widget in app.topLevelWidgets():
            widget.hide()
        for process in reversed(processes):
            process.terminate()
            process.wait(timeout=5)
            errors = process.stderr.read().decode(errors="replace")
            if errors:
                print(errors)
