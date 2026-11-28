"""Minimize and restore the settings window under Mutter, GNOME's window manager.

Mutter only minimizes NORMAL windows. Openbox does not apply that rule, so this
fixture runs against `mutter --x11`. GNOME Shell and Ubuntu Dock are absent;
restoring from the Dock icon still needs a real GNOME session.
"""

import json
from pathlib import Path
import subprocess
import tempfile
import time

from PySide6.QtCore import Qt
from PySide6.QtNetwork import QLocalServer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from prismtranslate.app import Controller
from prismtranslate.core import Settings

app = QApplication([])
app.setQuitOnLastWindowClosed(False)


def until(condition, seconds=5):
    deadline = time.monotonic() + seconds
    while not condition() and time.monotonic() < deadline:
        QTest.qWait(20)
    assert condition(), "minimize fixture timed out"


def xprop(widget, *names):
    return subprocess.run(["xprop", "-id", str(int(widget.winId())), *names],
                          text=True, capture_output=True, check=True).stdout


def iconic(widget):
    return "Iconic" in xprop(widget, "WM_STATE")


def minimize(widget):
    # xdotool sends WM_CHANGE_STATE(IconicState): Mutter's minimize path, the
    # same one the title bar button uses. A just-restored window can still
    # receive Qt's queued activation, which un-minimizes it, so allow retries.
    for _ in range(5):
        subprocess.run(["xdotool", "windowminimize", str(int(widget.winId()))], check=True)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            QTest.qWait(20)
            if iconic(widget) and widget.isMinimized():
                return
    raise AssertionError("settings window did not minimize")


def restored(widget):
    # Mutter 46 drops a minimize request sent before it has refocused the window.
    return (not iconic(widget) and not widget.isMinimized() and widget.isVisible() and
            "_NET_WM_STATE_FOCUSED" in xprop(widget, "_NET_WM_STATE"))


until(lambda: b"window id" in subprocess.run(
    ["xprop", "-root", "_NET_SUPPORTING_WM_CHECK"], capture_output=True).stdout)
with tempfile.TemporaryDirectory() as temporary:
    server = QLocalServer()
    assert server.listen(str(Path(temporary) / "fixture.sock"))
    controller = Controller(app, Settings(), server)
    window = controller.window
    try:
        until(lambda: "_NET_WM_ALLOWED_ACTIONS(ATOM)" in xprop(window, "_NET_WM_ALLOWED_ACTIONS"))
        properties = xprop(window, "_NET_WM_WINDOW_TYPE", "WM_TRANSIENT_FOR", "_NET_WM_ALLOWED_ACTIONS")
        assert "_NET_WM_WINDOW_TYPE_DIALOG" not in properties, properties
        assert "WM_TRANSIENT_FOR:  not found" in properties, properties
        assert "_NET_WM_ACTION_MINIMIZE" in properties, properties
        minimize(window)
        # Tray, menu and `--action settings` all restore through show_settings.
        controller.show_settings()
        until(lambda: restored(window))
        # Capturing while minimized must not pop the window back afterwards.
        minimize(window)
        controller.capture(False)
        assert window not in controller.capture_restore
        until(lambda: bool(controller.selectors), 3)
        controller.cancel_capture()
        until(lambda: not controller.capturing)
        QTest.qWait(300)
        assert iconic(window) and window.isMinimized()
        controller.show_settings()
        until(lambda: restored(window))
        # Without a tray and ball, closing must still be refused.
        app.setProperty("has_tray", False)
        controller.settings.show_ball = False
        window.close()
        assert window.isVisible()
        print(json.dumps({"wm": "Mutter --x11", "window_type": "NORMAL",
                          "allowed_minimize": True, "minimize": "passed",
                          "restore_show_settings": "passed", "capture_keeps_minimized": "passed",
                          "close_guard_without_tray": "passed", "result": "passed"}))
    finally:
        controller.cleanup()
        for widget in app.topLevelWidgets():
            widget.hide()
