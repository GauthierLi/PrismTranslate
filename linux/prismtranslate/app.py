"""Application lifecycle, user actions and single-instance IPC."""

import argparse
from copy import deepcopy
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

from PySide6.QtCore import QObject, QLockFile, QRunnable, QThreadPool, QTimer, Signal, Slot
from PySide6.QtGui import QIcon, QKeySequence, QShortcut
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import QApplication, QFileDialog, QMenu, QMessageBox, QSystemTrayIcon

from .core import Settings, UserError, config_path, list_models, translate
from .desktop import CaptureCancelled, X11Hotkey, capture_wayland, recognize
from .views import FloatingBall, RegionSelector, STYLE, SettingsWindow, Subtitle


class JobSignals(QObject):
    finished = Signal(str, object, object)


class Job(QRunnable):
    def __init__(self, function):
        super().__init__()
        self.identifier = uuid.uuid4().hex
        self.function = function
        self.signals = JobSignals()

    def run(self):
        try:
            result = self.function()
            self.signals.finished.emit(self.identifier, result, None)
        except Exception as exc:
            error = exc if isinstance(exc, UserError) else UserError("操作失败，请检查服务和配置后重试。")
            self.signals.finished.emit(self.identifier, None, error)


class Controller(QObject):
    def __init__(self, app, settings, server):
        super().__init__()
        self.app, self.settings, self.server = app, settings, server
        self.wayland = (os.environ.get("XDG_SESSION_TYPE") == "wayland" or
                        app.platformName().startswith("wayland"))
        self.pool = QThreadPool(self)
        self.pool.setMaxThreadCount(2)
        self.jobs = {}
        self.busy = False
        self.quitting = False
        self.selectors = []
        self.capture_restore = []
        self.icon = QIcon(str(Path(__file__).parent / "logo.png"))
        if self.icon.isNull():
            self.icon = QIcon(str(Path(__file__).resolve().parents[2] / "Resources/logo.png"))
        app.setWindowIcon(self.icon)
        self.window = SettingsWindow(settings)
        self.subtitle = Subtitle(settings)
        self.ball = FloatingBall(settings, self.icon)
        self.menu = QMenu()
        self.menu.addAction("翻译剪贴板 · Ctrl+Shift+T", self.translate_clipboard)
        self.menu.addAction("截图识别 (OCR)", lambda: self.capture(False))
        self.menu.addAction("截图识别并翻译", lambda: self.capture(True))
        self.menu.addAction("从图片识别… · Ctrl+O", self.open_image)
        self.menu.addSeparator()
        self.menu.addAction("设置…", self.show_settings)
        self.menu.addAction("退出棱镜翻译 · Ctrl+Q", self.quit)
        self.open_shortcut = QShortcut(QKeySequence("Ctrl+O"), self.window)
        self.open_shortcut.activated.connect(self.open_image)
        self.quit_shortcut = QShortcut(QKeySequence("Ctrl+Q"), self.window)
        self.quit_shortcut.activated.connect(self.quit)
        self.tray = QSystemTrayIcon(self.icon, self)
        self.tray.setToolTip("棱镜翻译")
        self.tray.setContextMenu(self.menu)
        self.tray.activated.connect(self.tray_clicked)
        has_tray = QSystemTrayIcon.isSystemTrayAvailable()
        app.setProperty("has_tray", has_tray)
        if has_tray:
            self.tray.show()
        self.ball.menu_requested.connect(self.menu.popup)
        self.window.save_requested.connect(self.save)
        self.window.translate_requested.connect(self.translate_text)
        self.window.clipboard_requested.connect(self.translate_clipboard)
        self.window.capture_requested.connect(self.capture)
        self.window.models_requested.connect(self.refresh_models)
        QApplication.clipboard().dataChanged.connect(self.clipboard_changed)
        self.last_clipboard = QApplication.clipboard().text()
        self.clipboard_timer = QTimer(self)
        self.clipboard_timer.setSingleShot(True)
        self.clipboard_timer.setInterval(450)
        self.clipboard_timer.timeout.connect(self.auto_translate)
        self.hotkey = None
        if sys.platform == "linux" and app.platformName() == "xcb" and not self.wayland:
            try:
                self.hotkey = X11Hotkey(self)
                self.hotkey.activated.connect(self.translate_clipboard)
            except UserError as exc:
                self.window.status.setText(str(exc))
        elif self.wayland:
            self.window.status.setText("Wayland：请在系统设置绑定全局快捷键；截图使用系统授权对话框。")
        self.menu.actions()[0].setText("翻译剪贴板" + (" · Ctrl+Shift+T" if self.hotkey else ""))
        if settings.show_ball:
            self.ball.show()
        self.server.newConnection.connect(self.accept_connection)
        self.app.aboutToQuit.connect(self.cleanup)
        self.window.show()
        if settings.provider == "ollama":
            self.refresh_models()

    def show_settings(self):
        self.window.show()
        self.window.raise_()
        self.window.activateWindow()

    def tray_clicked(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.show_settings()

    def save(self):
        self.window.apply()
        try:
            self.settings.save()
        except UserError as exc:
            self.show_error(exc)
            return False
        self.ball.setVisible(self.settings.show_ball)
        self.window.status.setText("设置已保存")
        return True

    def set_busy(self, busy, status="就绪"):
        self.busy = busy
        self.window.set_busy(busy)
        self.ball.busy = busy
        self.ball.update()
        for action in self.menu.actions()[:4]:
            action.setEnabled(not busy)
        self.window.status.setText(status)

    def start_job(self, function, callback):
        job = Job(function)
        self.jobs[job.identifier] = (job, callback)
        job.signals.finished.connect(self.job_finished)
        self.pool.start(job)

    @Slot(str, object, object)
    def job_finished(self, identifier, result, error):
        _, callback = self.jobs.pop(identifier)
        if not self.quitting:
            callback(result, error)
        if self.quitting and not self.jobs:
            self.app.quit()

    def show_error(self, error):
        self.window.status.setText(str(error))
        self.subtitle.show_result("", str(error), error=True)

    def translate_clipboard(self):
        self.translate_text(QApplication.clipboard().text())

    def translate_text(self, text):
        if self.busy or self.quitting:
            return
        if not text.strip():
            self.show_error(UserError("没有可翻译的文字，请先复制或输入文本。"))
            return
        if not self.save():
            return
        settings = deepcopy(self.settings)
        self.set_busy(True, "正在翻译…")

        def completed(result, error):
            self.set_busy(False, "翻译完成" if not error else str(error))
            if error:
                self.show_error(error)
            else:
                self.subtitle.show_result(text, result)
                self.suppress_clipboard = result

        self.start_job(lambda: translate(text, settings), completed)

    def clipboard_changed(self):
        text = QApplication.clipboard().text()
        if text == self.last_clipboard:
            return
        self.last_clipboard = text
        if text == getattr(self, "suppress_clipboard", None):
            self.clipboard_timer.stop()
            return
        if self.settings.watch_clipboard and text.strip():
            self.clipboard_timer.start()

    def auto_translate(self):
        if self.settings.watch_clipboard and not self.quitting:
            if self.busy:
                self.clipboard_timer.start()
            else:
                self.translate_text(self.last_clipboard)

    def refresh_models(self):
        if not self.window.refresh.isEnabled() or self.quitting:
            return
        self.window.refresh.setEnabled(False)
        self.window.model_status.setText("正在读取本机模型…")

        def completed(models, error):
            self.window.refresh.setEnabled(True)
            if self.window.current_provider != "ollama":
                return
            self.window.model_status.setText(str(error) if error else
                                             ("没有已安装的模型，请先在 Ollama 安装模型。" if not models
                                              else f"找到 {len(models)} 个本机模型"))
            if not error:
                selected = self.window.model.currentText()
                self.window.model.clear()
                self.window.model.addItems(models)
                self.window.model.setEditText(selected)

        self.start_job(list_models, completed)

    def capture(self, translate_result):
        if self.busy or self.quitting or not self.save():
            return
        settings = deepcopy(self.settings)
        self.set_busy(True, "请选择截图区域 · Esc 取消")
        self.capture_restore = [widget for widget in (self.window, self.ball, self.subtitle) if widget.isVisible()]
        for widget in self.capture_restore:
            if widget is self.subtitle and self.subtitle.timer.isActive():
                self.subtitle.remaining = max(1, self.subtitle.timer.remainingTime())
                self.subtitle.timer.stop()
            widget.hide()
        QTimer.singleShot(250, lambda: self.begin_capture(settings, translate_result))

    def begin_capture(self, settings, translate_result):
        if self.quitting:
            return
        if self.wayland:
            self.start_job(lambda: self.ocr_pipeline(capture_wayland(settings.ocr_languages),
                                                    settings, translate_result), self.capture_completed)
            return
        try:
            for screen in QApplication.screens():
                screenshot = screen.grabWindow(0)
                if screenshot.isNull():
                    raise UserError("无法截取屏幕。请使用“从图片识别”，或检查桌面截屏权限。")
                selector = RegionSelector(screen, screenshot)
                selector.selected.connect(lambda image: self.region_selected(image, settings, translate_result))
                selector.cancelled.connect(self.cancel_capture)
                self.selectors.append(selector)
                selector.show()
                selector.raise_()
                selector.activateWindow()
        except UserError as exc:
            self.capture_completed(None, exc)

    def close_selectors(self):
        for selector in self.selectors:
            selector.close()
            selector.deleteLater()
        self.selectors.clear()

    def restore_capture_windows(self):
        self.close_selectors()
        for widget in self.capture_restore:
            widget.show()
            if widget is self.subtitle and not self.subtitle.pinned and not self.subtitle.underMouse():
                self.subtitle.timer.start(self.subtitle.remaining)
        self.capture_restore.clear()

    def cancel_capture(self):
        self.restore_capture_windows()
        self.set_busy(False, "已取消截图")

    def region_selected(self, image, settings, translate_result):
        self.close_selectors()
        self.set_busy(True, "正在识别文字…")
        temporary = tempfile.TemporaryDirectory(prefix="prismtranslate-")
        path = Path(temporary.name) / "capture.png"
        if not image.save(str(path), "PNG"):
            temporary.cleanup()
            self.capture_completed(None, UserError("截图保存失败。"))
            return

        def operation():
            try:
                return self.ocr_pipeline(recognize(path, settings.ocr_languages), settings, translate_result)
            finally:
                temporary.cleanup()

        self.start_job(operation, self.capture_completed)

    @staticmethod
    def ocr_pipeline(text, settings, translate_result):
        return (text if translate_result else "", translate(text, settings) if translate_result else text)

    def capture_completed(self, result, error):
        self.restore_capture_windows()
        self.set_busy(False, "已取消截图" if isinstance(error, CaptureCancelled) else
                      ("识别完成" if not error else str(error)))
        if isinstance(error, CaptureCancelled):
            return
        if error:
            self.show_error(error)
        else:
            original, text = result
            self.subtitle.show_result(original, text)
            self.suppress_clipboard = text

    def open_image(self):
        if self.busy or self.quitting:
            return
        path, _ = QFileDialog.getOpenFileName(self.window, "选择要识别的图片", "",
                                              "图片 (*.png *.jpg *.jpeg *.tif *.tiff *.bmp)")
        if path and self.save():
            languages = self.settings.ocr_languages
            self.set_busy(True, "正在识别图片…")
            self.start_job(lambda: self.ocr_pipeline(recognize(path, languages), self.settings, False),
                           self.capture_completed)

    def action(self, action):
        if action == "translate":
            self.translate_clipboard()
        elif action in ("ocr", "ocr-translate"):
            self.capture(action == "ocr-translate")
        else:
            self.show_settings()

    def accept_connection(self):
        while self.server.hasPendingConnections():
            socket = self.server.nextPendingConnection()
            socket.setProperty("buffer", b"")
            socket.readyRead.connect(lambda socket=socket: self.read_command(socket))
            socket.disconnected.connect(socket.deleteLater)
            if socket.bytesAvailable():
                self.read_command(socket)

    def read_command(self, socket):
        buffer = socket.property("buffer") + bytes(socket.readAll())
        if len(buffer) > 64:
            socket.disconnectFromServer()
            return
        socket.setProperty("buffer", buffer)
        if b"\n" in buffer:
            action = buffer.split(b"\n", 1)[0].decode("ascii", errors="ignore")
            if action in ("settings", "translate", "ocr", "ocr-translate"):
                self.action(action)
            socket.disconnectFromServer()

    def quit(self):
        self.quitting = True
        self.close_selectors()
        self.clipboard_timer.stop()
        if self.jobs:
            self.window.status.setText("等待当前请求结束后退出…")
            self.window.setEnabled(False)
            self.window.show()
        else:
            self.app.quit()

    def cleanup(self):
        if self.hotkey:
            self.hotkey.close()
        self.server.close()
        try:
            self.settings.save()
        except UserError as exc:
            print(str(exc), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="棱镜翻译 Linux 桌面端")
    parser.add_argument("--action", choices=("settings", "translate", "ocr", "ocr-translate"), default="settings")
    parser.add_argument("--smoke-test", action="store_true", help="创建窗口后退出，不调用真实翻译服务")
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    app.setApplicationName("PrismTranslate")
    app.setQuitOnLastWindowClosed(False)
    app.setStyleSheet(STYLE)
    if args.smoke_test:
        settings = Settings()
        window = SettingsWindow(settings)
        subtitle = Subtitle(settings)
        subtitle.show_result("Hello <b>world</b>", "你好 <b>世界</b>\nLinux 字幕测试")
        window.show()
        app.processEvents()
        assert subtitle.result.toPlainText() == "你好 <b>世界</b>\nLinux 字幕测试"
        assert window.minimumWidth() == 480
        print(json.dumps({"platform": app.platformName(), "python": sys.version.split()[0],
                          "windows": "settings, subtitle", "result": "passed"}))
        return 0
    try:
        settings = Settings.load()
    except UserError as exc:
        QMessageBox.critical(None, "无法读取设置", str(exc))
        return 1
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", config_path().parent))
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    server_name = str(runtime / "prismtranslate.sock")
    lock = QLockFile(server_name + ".lock")
    if not lock.tryLock(0):
        socket = QLocalSocket()
        socket.connectToServer(server_name)
        if not socket.waitForConnected(2000):
            print("已有实例正在启动或无响应，请稍后重试。", file=sys.stderr)
            return 1
        socket.write((args.action + "\n").encode("ascii"))
        socket.waitForBytesWritten(2000)
        socket.disconnectFromServer()
        return 0
    QLocalServer.removeServer(server_name)
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
    if not server.listen(server_name):
        print("无法创建本机操作入口：" + server.errorString(), file=sys.stderr)
        return 1
    controller = Controller(app, settings, server)
    if args.action != "settings":
        QTimer.singleShot(0, lambda: controller.action(args.action))
    try:
        return app.exec()
    finally:
        lock.unlock()


if __name__ == "__main__":
    sys.exit(main())
