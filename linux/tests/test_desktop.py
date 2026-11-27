import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from PySide6.QtCore import QPoint, QPointF, QRect, Qt
from PySide6.QtGui import QColor, QFont, QImage, QMouseEvent, QPainter, QPixmap
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from prismtranslate.app import Controller
from prismtranslate.core import Settings, UserError
from prismtranslate.desktop import X11Hotkey, recognize
from prismtranslate.views import RegionSelector, SettingsWindow, Subtitle
import test_core


APP = QApplication.instance() or QApplication([])
APP.setQuitOnLastWindowClosed(False)


def until(condition, seconds=10):
    deadline = time.monotonic() + seconds
    while not condition() and time.monotonic() < deadline:
        APP.processEvents()
        QTest.qWait(10)
    assert condition(), "asynchronous operation timed out"


class DesktopTests(unittest.TestCase):
    def tearDown(self):
        for widget in APP.topLevelWidgets():
            widget.hide()
        APP.processEvents()

    def test_subtitle_plain_text_pin_copy_and_long_content(self):
        overlay = Subtitle(Settings())
        overlay.show_result("source", "<b>not markup</b>\n" + "Long text " * 500)
        self.assertIn("<b>not markup</b>", overlay.result.toPlainText())
        self.assertLessEqual(overlay.height(), APP.primaryScreen().availableGeometry().height())
        overlay.pin.click()
        self.assertTrue(overlay.pinned)
        self.assertFalse(overlay.timer.isActive())
        overlay.copy_result()
        self.assertEqual(APP.clipboard().text(), overlay.result.toPlainText())
        overlay.pin.click()
        self.assertFalse(overlay.pinned)
        overlay.deleteLater()

    def test_provider_profiles_survive_switching(self):
        window = SettingsWindow(Settings())
        window.api_key.setText("openai-test")
        window.model.setEditText("model-one")
        window.provider.setCurrentIndex(window.provider.findData("anthropic"))
        window.api_key.setText("anthropic-test")
        window.provider.setCurrentIndex(window.provider.findData("openai"))
        self.assertEqual(window.api_key.text(), "openai-test")
        self.assertEqual(window.model.currentText(), "model-one")
        window.deleteLater()

    def test_small_settings_window_keeps_primary_actions_visible(self):
        window = SettingsWindow(Settings())
        window.resize(480, 500)
        window.show()
        QTest.qWait(30)
        for widget in (window.clipboard_button, window.save_button, window.test_button):
            rectangle = QRect(widget.mapTo(window, QPoint(0, 0)), widget.size())
            self.assertTrue(window.rect().contains(rectangle))
        window.deleteLater()

    def test_high_dpi_reverse_selection_uses_physical_pixels(self):
        image = QPixmap(800, 600)
        image.fill(QColor("white"))
        image.setDevicePixelRatio(2)
        selector = RegionSelector(APP.primaryScreen(), image)
        selected = []
        selector.selected.connect(selected.append)

        def event(kind, x, y, buttons):
            return QMouseEvent(kind, QPointF(x, y), QPointF(x, y),
                               Qt.MouseButton.LeftButton, buttons, Qt.KeyboardModifier.NoModifier)

        selector.mousePressEvent(event(QMouseEvent.Type.MouseButtonPress, 100, 80, Qt.MouseButton.LeftButton))
        selector.mouseMoveEvent(event(QMouseEvent.Type.MouseMove, 30, 20, Qt.MouseButton.LeftButton))
        selector.mouseReleaseEvent(event(QMouseEvent.Type.MouseButtonRelease, 30, 20, Qt.MouseButton.NoButton))
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].width(), 140)
        self.assertEqual(selected[0].height(), 120)
        selector.deleteLater()

    @unittest.skipUnless(shutil.which("tesseract"), "Tesseract not installed")
    def test_real_tesseract_ocr_and_missing_language(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "text.png"
            image = QImage(1000, 180, QImage.Format.Format_RGB32)
            image.fill(QColor("white"))
            painter = QPainter(image)
            painter.setPen(QColor("black"))
            font = QFont("DejaVu Sans")
            font.setPixelSize(54)
            painter.setFont(font)
            painter.drawText(30, 110, "Hello PrismTranslate")
            painter.end()
            image.save(str(path))
            text = recognize(path, "eng")
            self.assertIn("Hello", text)
            self.assertIn("Prism", text)
            with self.assertRaises(UserError):
                recognize(path, "not_installed")

    @unittest.skipUnless(APP.platformName() == "xcb" and shutil.which("xdotool"),
                         "requires X11 and xdotool")
    def test_real_x11_global_hotkey(self):
        hotkey = X11Hotkey()
        received = []
        hotkey.activated.connect(lambda: received.append(True))
        try:
            subprocess.run(["xdotool", "key", "ctrl+shift+t"], check=True)
            until(lambda: bool(received), 3)
            self.assertEqual(len(received), 1)
        finally:
            hotkey.close()

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("dbus-run-session"),
                         "requires a Linux D-Bus session")
    def test_screenshot_portal_protocol(self):
        subprocess.run(["dbus-run-session", "--", sys.executable,
                        str(Path(__file__).parent / "portal_fixture.py")], check=True, timeout=15)


class ControllerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        test_core.CoreTests.setUpClass()
        cls.url = test_core.CoreTests.url

    @classmethod
    def tearDownClass(cls):
        test_core.CoreTests.tearDownClass()

    def test_async_translation_and_local_command(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            "XDG_CONFIG_HOME": temporary, "XDG_RUNTIME_DIR": temporary,
            "XDG_SESSION_TYPE": "wayland",
        }):
            settings = Settings()
            settings.profiles["openai"] = {"base_url": self.url + "/v1", "api_key": "test-key", "model": "test"}
            server = QLocalServer()
            name = str(Path(temporary) / "test.sock")
            self.assertTrue(server.listen(name))
            controller = Controller(APP, settings, server)
            try:
                controller.translate_text("Hello world")
                self.assertTrue(controller.busy)
                until(lambda: not controller.busy)
                self.assertEqual(controller.subtitle.result.toPlainText(), "你好世界")
                received = []
                controller.action = received.append
                socket = QLocalSocket()
                socket.connectToServer(name)
                self.assertTrue(socket.waitForConnected(1000))
                # Deliberate fragmented IPC input.
                socket.write(b"trans")
                socket.waitForBytesWritten(1000)
                APP.processEvents()
                socket.write(b"late\n")
                socket.waitForBytesWritten(1000)
                until(lambda: bool(received))
                self.assertEqual(received, ["translate"])
                socket.disconnectFromServer()
                # A Wayland session may use Qt's xcb backend through XWayland;
                # screen capture must still use the portal.
                self.assertTrue(controller.wayland)
                with patch("prismtranslate.app.capture_wayland", return_value="screen text") as portal:
                    controller.capture(False)
                    until(lambda: not controller.busy)
                    portal.assert_called_once()
                    self.assertEqual(controller.subtitle.result.toPlainText(), "screen text")
                controller.window.watch.setChecked(True)
                controller.save()
                count = len(test_core.Handler.records)
                APP.clipboard().setText("Live clipboard translation")
                until(lambda: len(test_core.Handler.records) > count and not controller.busy)
                self.assertEqual(len(test_core.Handler.records), count + 1)
                controller.subtitle.copy_result()
                QTest.qWait(600)
                APP.processEvents()
                self.assertEqual(len(test_core.Handler.records), count + 1,
                                 "copying a translation must not start a translation loop")
            finally:
                controller.settings.watch_clipboard = False
                controller.clipboard_timer.stop()
                controller.cleanup()
                for widget in (controller.window, controller.ball, controller.subtitle, controller.menu):
                    widget.deleteLater()
                controller.tray.hide()
                controller.deleteLater()
                APP.processEvents()


if __name__ == "__main__":
    unittest.main()
