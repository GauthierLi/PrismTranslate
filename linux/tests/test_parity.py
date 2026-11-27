"""Regression evidence for the desktop fixes and product parity."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import QColor, QIcon, QImage, QPainter, QPixmap
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QPushButton

from prismtranslate.app import Controller, ipc_path
from prismtranslate.capture import crop_screens
from prismtranslate.core import Settings, UserError
from prismtranslate.desktop import X11PointerMonitor
from prismtranslate.floating import FloatingBall, ring_action
from prismtranslate.language import is_already
from prismtranslate.pet import SKINS
from prismtranslate.views import RegionSelector, SettingsWindow, Subtitle
from test_desktop import APP, until


class ParityTests(unittest.TestCase):
    def tearDown(self):
        for widget in APP.topLevelWidgets():
            widget.hide()
        APP.processEvents()

    def test_constrained_window_preview_and_crop_use_same_screen_pixels(self):
        screen = APP.primaryScreen()
        geometry = screen.geometry()
        image = QImage(geometry.size(), QImage.Format.Format_RGB32)
        painter = QPainter(image)
        for y in range(image.height()):
            painter.fillRect(0, y, image.width(), 1, QColor(y % 256, (y // 256) % 256, 90))
        painter.end()
        selector = RegionSelector(screen, QPixmap.fromImage(image))
        # The reported GNOME geometry: top bar shifts y by 27 and shrinks h.
        selector.setGeometry(geometry.adjusted(0, 27, 0, 0))
        selector.show()
        APP.processEvents()
        self.assertEqual(selector.mapToGlobal(QPoint(0, 0)).y(), geometry.y() + 27)
        received = []
        selector.selected.connect(received.append)
        for y in (80, selector.height() // 2, selector.height() - 60):
            for reverse in (False, True):
                first, last = QPoint(160, y), QPoint(220, y + 30)
                if reverse:
                    first, last = last, first
                QTest.mousePress(selector, Qt.MouseButton.LeftButton, pos=first)
                QTest.mouseMove(selector, last)
                APP.processEvents()
                # Compare clear pixels INSIDE the preview and crop. This also
                # detects the old 1.9% scaling, not only a 27 px translation.
                preview = selector.grab().toImage()
                self.assertEqual(preview.pixelColor(190, y + 15), image.pixelColor(190, y + 42))
                QTest.mouseRelease(selector, Qt.MouseButton.LeftButton, pos=last)
                self.assertEqual(received[-1].toImage(), image.copy(160, y + 27, 60, 30))
        selector.deleteLater()

    def test_fullscreen_selector_covers_screen_geometry(self):
        screen = APP.primaryScreen()
        selector = RegionSelector(screen, screen.grabWindow(0))
        selector.showFullScreen()
        until(lambda: selector.geometry() == screen.geometry(), 3)
        self.assertTrue(selector.isFullScreen())
        selector.deleteLater()

    def test_mixed_dpi_negative_origin_capture_composition(self):
        left = QPixmap(200, 100)
        left.fill(QColor("red"))
        right = QPixmap(400, 200)
        right.fill(QColor("blue"))
        right.setDevicePixelRatio(2)
        result = crop_screens([(QRect(-200, 40, 200, 100), left),
                               (QRect(0, 40, 200, 100), right)], QRect(-50, 50, 100, 40))
        self.assertEqual(result.size().width(), 200)
        self.assertEqual(result.size().height(), 80)
        self.assertEqual(result.toImage().pixelColor(99, 40), QColor("red"))
        self.assertEqual(result.toImage().pixelColor(100, 40), QColor("blue"))

    @unittest.skipUnless(APP.platformName() == "xcb" and shutil.which("xdotool"), "requires X11")
    def test_real_external_pointer_press_is_observed_without_grab(self):
        monitor = X11PointerMonitor()
        presses = []
        monitor.clicked.connect(presses.append)
        monitor.set_active(True)
        try:
            subprocess.run(["xdotool", "mousemove", "300", "200", "click", "1"], check=True)
            until(lambda: bool(presses), 3)
            self.assertEqual(presses[-1], QPoint(300, 200))
            monitor.set_active(False)
        finally:
            monitor.close()

    def test_offline_language_detection_threshold_and_script_rules(self):
        examples = [("This is a complete English sentence about reading scientific papers.", "en"),
                    ("这是一个完整的中文句子，用来验证离线语言识别功能。", "zh-Hans"),
                    ("這是一個完整的中文句子，用來驗證離線語言識別功能。", "zh-Hant"),
                    ("これは日本語で書かれた文章です。翻訳の機能を確認しています。", "ja"),
                    ("Bonjour, ceci est une phrase française qui explique la traduction.", "fr")]
        for text, language in examples:
            self.assertTrue(is_already(text, language), (text, language))
            self.assertFalse(is_already(text, "de"), (text, "de"))
        for text in ("1", "1234", "!", "A"):
            self.assertFalse(is_already(text, "en"))

    def test_ocr_translation_same_language_keeps_result_without_request(self):
        settings = Settings(target="en")
        text = "This is a complete English sentence about scientific research."
        with patch("prismtranslate.app.translate") as request:
            self.assertEqual(Controller.ocr_pipeline(text, settings, True), ("", text))
            request.assert_not_called()

    def test_product_settings_profiles_skin_mode_and_key_reveal(self):
        settings = Settings(ball_skin="panda", mode="ocr-translate")
        window = SettingsWindow(settings)
        self.assertEqual(window.skin.currentData(), "panda")
        self.assertEqual(window.mode.currentData(), "ocr-translate")
        segment = next(control for control in window.findChildren(QPushButton)
                       if control.text() == "OCR翻译" and control.isCheckable())
        segment.click()
        self.assertTrue(segment.isChecked(), "a selected segment must stay selected")
        changes = []
        window.changed.connect(lambda: changes.append(True))
        window.api_key.setText("test-key")
        window.reveal.click()
        self.assertEqual(window.api_key.echoMode(), window.api_key.EchoMode.Normal)
        window.reveal.click()
        self.assertEqual(window.api_key.echoMode(), window.api_key.EchoMode.Password)
        window.skin.setCurrentIndex(window.skin.findData("chick"))
        self.assertTrue(changes)
        window.apply()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "settings.json"
            settings.save(path)
            self.assertEqual(Settings.load(path).ball_skin, "chick")
            self.assertEqual(Settings.load(path).mode, "ocr-translate")
        window.deleteLater()

    def test_pet_rendering_five_skins_and_task_expressions(self):
        settings = Settings(reduce_motion=True)
        ball = FloatingBall(settings, QIcon())
        images = []
        try:
            ball.show()
            for skin in SKINS:
                settings.ball_skin = skin
                APP.processEvents()
                images.append(ball.grab().toImage())
            self.assertEqual(len({bytes(image.bits()) for image in images}), 5)
            settings.ball_skin = "cat"
            ball.set_mood("happy")
            happy = ball.grab().toImage()
            ball.set_mood("sad")
            self.assertNotEqual(ball.grab().toImage(), happy)
            ball.busy = True
            self.assertNotEqual(ball.grab().toImage(), happy)
            settings.watch_clipboard = True
            self.assertNotEqual(ball.grab().toImage(), images[1])
        finally:
            ball.hide()
            ball.ring.bubble.deleteLater()
            ball.ring.deleteLater()
            ball.deleteLater()

    def test_ring_release_dead_zone_busy_gate_and_edge_press(self):
        center, press = QPoint(100, 100), QPoint(100, 100)
        self.assertIsNone(ring_action(press, center, press))
        self.assertEqual(ring_action(QPoint(60, 60), center, press), "ocr")
        self.assertEqual(ring_action(QPoint(140, 60), center, press), "ocr-translate")
        self.assertEqual(ring_action(QPoint(100, 156), center, press), "watch")
        self.assertIsNone(ring_action(QPoint(60, 60), center, press, busy=True))
        self.assertEqual(ring_action(QPoint(100, 156), center, press, busy=True), "watch")
        self.assertIsNone(ring_action(QPoint(300, 300), center, press))
        self.assertIsNone(ring_action(QPoint(8, 100), center, QPoint(6, 100)))

    def test_real_hold_drag_cancel_and_quick_action(self):
        ball = FloatingBall(Settings(), QIcon())
        actions = []
        ball.quick_action.connect(actions.append)
        ball.show()
        try:
            QTest.mousePress(ball, Qt.MouseButton.LeftButton, pos=QPoint(36, 39))
            QTest.qWait(450)
            self.assertTrue(ball.ring.isVisible())
            ring_image = ball.ring.grab().toImage()
            self.assertGreater(ring_image.pixelColor(44, 44).alpha(), 30)
            self.assertEqual(ring_image.pixelColor(84, 84).alpha(), 0)
            QTest.keyClick(ball, Qt.Key.Key_Escape)
            self.assertFalse(ball.ring.isVisible())
            self.assertFalse(actions)
            QTest.mousePress(ball, Qt.MouseButton.LeftButton, pos=QPoint(36, 39))
            QTest.mouseMove(ball, QPoint(46, 39))
            QTest.qWait(450)
            self.assertEqual(ball.phase, "dragging")
            self.assertFalse(ball.ring.isVisible())
            QTest.mouseRelease(ball, Qt.MouseButton.LeftButton, pos=QPoint(46, 39))
            QTest.mousePress(ball, Qt.MouseButton.LeftButton, pos=QPoint(36, 39))
            QTest.qWait(450)
            target = ball.mapFromGlobal(ball.ring.pos() + QPoint(44, 44))
            QTest.mouseMove(ball, target)
            QTest.mouseRelease(ball, Qt.MouseButton.LeftButton, pos=target)
            self.assertEqual(actions, ["ocr"])
            self.assertFalse(ball.ring.isVisible())
            self.assertFalse(ball.ring.bubble.isVisible())
        finally:
            ball.hide()
            ball.ring.bubble.deleteLater()
            ball.ring.deleteLater()
            ball.deleteLater()

    def test_subtitle_center_anchor_selection_loading_and_outside_click(self):
        settings = Settings(overlay_center=[400, 300])
        subtitle = Subtitle(settings)
        subtitle.show_result("", "A short result")
        center = subtitle.geometry().center()
        subtitle.show_result("", "A much longer result " * 20)
        self.assertLessEqual((subtitle.geometry().center() - center).manhattanLength(), 2)
        subtitle.pin.click()
        subtitle.dismiss_outside(QPoint(-1, -1))
        self.assertTrue(subtitle.isVisible())
        self.assertFalse(subtitle.timer.isActive())
        subtitle.pin.click()
        subtitle.dismiss_outside(QPoint(-1, -1))
        self.assertFalse(subtitle.isVisible())
        subtitle.show_loading("翻译中…")
        self.assertFalse(subtitle.timer.isActive())
        self.assertFalse(subtitle.pin.isVisible())
        subtitle.deleteLater()


class IPCTests(unittest.TestCase):
    def test_byte_length_fallback_permission_lock_and_real_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / ("中" * 40)
            self.assertGreater(len(os.fsencode(runtime / "prismtranslate.sock")), 107)
            endpoint = ipc_path(runtime)
            self.assertLessEqual(len(os.fsencode(endpoint)), 107)
            self.assertEqual(stat.S_IMODE(endpoint.parent.stat().st_mode), 0o700)
            self.assertEqual(ipc_path(runtime), endpoint)
            self.assertNotEqual(ipc_path(runtime / "other"), endpoint)
            server = QLocalServer()
            server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
            self.assertTrue(server.listen(str(endpoint)))
            socket = QLocalSocket()
            try:
                socket.connectToServer(str(endpoint))
                self.assertTrue(socket.waitForConnected(1000))
                socket.write(b"ocr\n")
                self.assertTrue(socket.waitForBytesWritten(1000))
                until(server.hasPendingConnections)
                received = server.nextPendingConnection()
                until(lambda: received.bytesAvailable() > 0)
                self.assertEqual(bytes(received.readAll()), b"ocr\n")
                received.close()
            finally:
                socket.close()
                server.close()
                endpoint.parent.rmdir()
                ipc_path(runtime / "other").parent.rmdir()

    def test_short_path_kept_and_unsafe_fallback_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            normal = Path(temporary)
            self.assertEqual(ipc_path(normal), normal / "prismtranslate.sock")
            runtime = normal / ("long-" * 30)
            endpoint = ipc_path(runtime)
            endpoint.parent.rmdir()
            endpoint.parent.symlink_to(normal, target_is_directory=True)
            try:
                with self.assertRaises(UserError):
                    ipc_path(runtime)
            finally:
                endpoint.parent.unlink()

    @unittest.skipUnless(sys.platform == "linux" and APP.platformName() == "xcb" and shutil.which("xdotool"),
                         "requires Linux X11")
    def test_actual_long_path_startup_second_instance_and_clean_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            runtime = Path(temporary) / ("runtime-" * 20)
            environment = dict(os.environ, XDG_CONFIG_HOME=temporary, XDG_RUNTIME_DIR=str(runtime))
            with tempfile.TemporaryFile() as log:
                process = subprocess.Popen([sys.executable, "-m", "prismtranslate"], env=environment,
                                           stdout=log, stderr=log)
                endpoint = ipc_path(runtime)
                try:
                    until(lambda: endpoint.exists() or process.poll() is not None, 10)
                    self.assertIsNone(process.poll(), "application failed to start")
                    second = subprocess.run([sys.executable, "-m", "prismtranslate", "--action", "settings"],
                                            env=environment, capture_output=True, timeout=10)
                    self.assertEqual(second.returncode, 0, second.stderr.decode())
                    self.assertTrue(Path(str(endpoint) + ".lock").exists())
                    windows = []

                    def settings_visible():
                        identifiers = subprocess.run(["xdotool", "search", "--pid", str(process.pid)],
                                                     text=True, capture_output=True).stdout.split()
                        for identifier in identifiers:
                            name = subprocess.run(["xdotool", "getwindowname", identifier],
                                                  text=True, capture_output=True).stdout
                            if "设置" in name:
                                windows.append(identifier)
                                return True
                        return False

                    until(settings_visible, 5)
                    subprocess.run(["xdotool", "windowfocus", "--sync", windows[0], "key", "ctrl+q"], check=True)
                    self.assertEqual(process.wait(timeout=10), 0)
                    self.assertFalse(endpoint.exists())
                    self.assertFalse(Path(str(endpoint) + ".lock").exists())
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
                    QLocalServer.removeServer(str(endpoint))
                    Path(str(endpoint) + ".lock").unlink(missing_ok=True)
                    endpoint.parent.rmdir()
