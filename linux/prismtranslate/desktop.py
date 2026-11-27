"""Linux desktop integration: X11 hotkeys, portal screenshots and local OCR."""

import asyncio
import ctypes
import ctypes.util
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlsplit
import uuid

from PySide6.QtCore import QObject, QSocketNotifier, Signal

from .core import UserError


class CaptureCancelled(UserError):
    pass


def recognize(path, languages):
    if not shutil.which("tesseract"):
        raise UserError("未安装 Tesseract。请安装 tesseract-ocr 和所需语言包。")
    try:
        installed = subprocess.run(["tesseract", "--list-langs"], capture_output=True,
                                   text=True, encoding="utf-8", errors="replace",
                                   timeout=10, check=True).stdout.splitlines()[1:]
        requested = languages.split("+")
        if not requested or any(language not in installed for language in requested):
            raise UserError("缺少 OCR 语言包：" + languages +
                            "。请安装语言包或在设置中选择已安装的语言（如 eng）。")
        result = subprocess.run(["tesseract", str(path), "stdout", "-l", languages],
                                capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=60)
        if result.returncode:
            raise UserError("OCR 识别失败，请检查图片和 Tesseract 语言包。")
        if not result.stdout.strip():
            raise UserError("选区没有识别到文字，请选择清晰的文字区域。")
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError, subprocess.CalledProcessError) as exc:
        raise UserError("OCR 无法完成，请检查 Tesseract 安装或缩小图片。") from exc


async def portal_screenshot():
    # Subscribe before asking to avoid losing a fast backend's Response signal.
    from dbus_next import Message, MessageType, Variant
    from dbus_next.aio import MessageBus

    bus = await MessageBus().connect()
    token = "prism" + uuid.uuid4().hex
    sender = bus.unique_name.lstrip(":").replace(".", "_")
    path = "/org/freedesktop/portal/desktop/request/" + sender + "/" + token
    future = asyncio.get_running_loop().create_future()

    def response(message):
        if (message.message_type == MessageType.SIGNAL and message.path == path
                and message.interface == "org.freedesktop.portal.Request"
                and message.member == "Response" and not future.done()):
            future.set_result(message.body)

    bus.add_message_handler(response)

    async def call(message):
        return await asyncio.wait_for(bus.call(message), timeout=10)

    try:
        match = ("type='signal',interface='org.freedesktop.portal.Request',"
                 "member='Response',path='" + path + "'")
        reply = await call(Message(destination="org.freedesktop.DBus",
                                       path="/org/freedesktop/DBus",
                                       interface="org.freedesktop.DBus", member="AddMatch",
                                       signature="s", body=[match]))
        if reply.message_type == MessageType.ERROR:
            raise UserError("无法订阅系统截屏结果。")
        reply = await call(Message(
            destination="org.freedesktop.portal.Desktop", path="/org/freedesktop/portal/desktop",
            interface="org.freedesktop.portal.Screenshot", member="Screenshot",
            signature="sa{sv}", body=["", {
                "interactive": Variant("b", True), "handle_token": Variant("s", token),
            }]))
        if reply.message_type == MessageType.ERROR:
            raise UserError("系统截屏服务不可用，请安装并启用桌面的 xdg-desktop-portal 后端。")
        if not reply.body or reply.body[0] != path:
            raise UserError("系统截屏服务返回了不支持的请求路径。")
        try:
            code, results = await asyncio.wait_for(future, timeout=120)
        except asyncio.TimeoutError as exc:
            await call(Message(destination="org.freedesktop.portal.Desktop", path=path,
                                   interface="org.freedesktop.portal.Request", member="Close"))
            raise UserError("系统截屏等待超时，请重试。") from exc
        if code == 1:
            raise CaptureCancelled("已取消截图。")
        if code != 0 or "uri" not in results:
            raise UserError("系统截屏未返回图片。")
        uri = urlsplit(results["uri"].value)
        if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
            raise UserError("系统截屏返回的文件地址无效。")
        return Path(unquote(uri.path))
    finally:
        bus.disconnect()


def capture_wayland(languages):
    try:
        path = asyncio.run(portal_screenshot())
    except (UserError, CaptureCancelled):
        raise
    except Exception as exc:
        raise UserError("无法调用系统截屏，请确认当前桌面有可用的 xdg-desktop-portal。") from exc
    # Portal owns the screenshot file. Do not delete another application's file.
    return recognize(path, languages)


class X11Hotkey(QObject):
    """Own one X connection and Ctrl+Shift+T; release it when the app exits."""

    activated = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.display = None
        library = ctypes.util.find_library("X11")
        if not library:
            raise UserError("X11 快捷键不可用，可在系统设置绑定 prismtranslate --action translate。")
        self.xlib = ctypes.CDLL(library)
        signatures = {
            "XOpenDisplay": ([ctypes.c_char_p], ctypes.c_void_p),
            "XDefaultRootWindow": ([ctypes.c_void_p], ctypes.c_ulong),
            "XConnectionNumber": ([ctypes.c_void_p], ctypes.c_int),
            "XStringToKeysym": ([ctypes.c_char_p], ctypes.c_ulong),
            "XKeysymToKeycode": ([ctypes.c_void_p, ctypes.c_ulong], ctypes.c_uint),
            "XGrabKey": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong,
                          ctypes.c_int, ctypes.c_int, ctypes.c_int], ctypes.c_int),
            "XUngrabKey": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_ulong], ctypes.c_int),
            "XSync": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "XPending": ([ctypes.c_void_p], ctypes.c_int),
            "XNextEvent": ([ctypes.c_void_p, ctypes.c_void_p], ctypes.c_int),
            "XCloseDisplay": ([ctypes.c_void_p], ctypes.c_int),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.xlib, name)
            function.argtypes, function.restype = arguments, result
        self.display = self.xlib.XOpenDisplay(None)
        if not self.display:
            raise UserError("无法连接 X11，系统快捷键未启用。")
        self.root = self.xlib.XDefaultRootWindow(self.display)
        self.key = self.xlib.XKeysymToKeycode(self.display, self.xlib.XStringToKeysym(b"t"))
        self.masks = [5, 7, 21, 23]  # Control+Shift, with CapsLock and NumLock.
        errors = []
        callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
        self.error_handler = callback_type(lambda _display, _event: errors.append(True) or 0)
        self.xlib.XSetErrorHandler.argtypes = [ctypes.c_void_p]
        self.xlib.XSetErrorHandler.restype = ctypes.c_void_p
        previous = self.xlib.XSetErrorHandler(ctypes.cast(self.error_handler, ctypes.c_void_p))
        try:
            for mask in self.masks:
                self.xlib.XGrabKey(self.display, self.key, mask, self.root, 0, 1, 1)
            self.xlib.XSync(self.display, 0)
        finally:
            self.xlib.XSetErrorHandler(previous)
        if errors:
            self.close()
            raise UserError("Ctrl+Shift+T 已被其他程序占用，请通过菜单操作或设置系统快捷键。")
        self.notifier = QSocketNotifier(self.xlib.XConnectionNumber(self.display),
                                        QSocketNotifier.Type.Read, self)
        self.notifier.activated.connect(self.read_events)

    def read_events(self, *_):
        event = (ctypes.c_long * 24)()
        while self.display and self.xlib.XPending(self.display):
            self.xlib.XNextEvent(self.display, ctypes.byref(event))
            if ctypes.cast(ctypes.byref(event), ctypes.POINTER(ctypes.c_int))[0] == 2:
                self.activated.emit()

    def close(self):
        if hasattr(self, "notifier"):
            self.notifier.setEnabled(False)
        if self.display:
            for mask in self.masks:
                self.xlib.XUngrabKey(self.display, self.key, mask, self.root)
            self.xlib.XCloseDisplay(self.display)
            self.display = None
