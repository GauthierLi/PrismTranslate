"""Linux desktop integration: X11 hotkeys, portal screenshots and local OCR."""

import asyncio
import ctypes
import ctypes.util
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlsplit
import uuid

from PySide6.QtCore import QObject, QPoint, QSocketNotifier, Signal

from .core import UserError


class CaptureCancelled(UserError):
    pass


def show_on_all_workspaces(widget):
    """Request EWMH all-desktop placement for our own X11 floating window."""
    from PySide6.QtWidgets import QApplication

    if (QApplication.platformName() != "xcb" or
            os.environ.get("XDG_SESSION_TYPE") == "wayland"):
        return
    library = ctypes.util.find_library("X11")
    if not library:
        return
    xlib = ctypes.CDLL(library)
    xlib.XOpenDisplay.argtypes, xlib.XOpenDisplay.restype = [ctypes.c_char_p], ctypes.c_void_p
    xlib.XDefaultRootWindow.argtypes, xlib.XDefaultRootWindow.restype = [ctypes.c_void_p], ctypes.c_ulong
    xlib.XInternAtom.argtypes, xlib.XInternAtom.restype = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int], ctypes.c_ulong
    xlib.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong,
                                   ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    xlib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]

    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong),
                    ("send_event", ctypes.c_int), ("display", ctypes.c_void_p),
                    ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]

    display = xlib.XOpenDisplay(None)
    if not display:
        return
    try:
        window = int(widget.winId())
        atom = xlib.XInternAtom(display, b"_NET_WM_DESKTOP", 0)
        cardinal = xlib.XInternAtom(display, b"CARDINAL", 0)
        desktop = (ctypes.c_ulong * 1)(0xffffffff)
        # Initial property is consumed when the window is first mapped.
        xlib.XChangeProperty(display, window, atom, cardinal, 32, 0, desktop, 1)
        storage = (ctypes.c_long * 24)()
        event = ctypes.cast(storage, ctypes.POINTER(ClientMessage)).contents
        event.type, event.send_event, event.display = 33, 1, display
        event.window, event.message_type, event.format = window, atom, 32
        event.data[0], event.data[1] = 0xffffffff, 1
        # Also request the change for windows already managed by the WM.
        xlib.XSendEvent(display, xlib.XDefaultRootWindow(display), 0,
                       (1 << 19) | (1 << 20), storage)
    finally:
        xlib.XCloseDisplay(display)


def system_reduce_motion():
    if not shutil.which("gsettings"):
        return False
    try:
        result = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "enable-animations"],
                                capture_output=True, text=True, timeout=2)
        return result.returncode == 0 and result.stdout.strip() == "false"
    except (OSError, subprocess.TimeoutExpired):
        return False


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


class X11PointerMonitor(QObject):
    """Observe XI2 raw presses without grabbing events from other apps."""

    clicked = Signal(QPoint)

    def __init__(self, parent=None):
        super().__init__(parent)
        library = ctypes.util.find_library("X11")
        if not library:
            raise UserError("X11 鼠标监听不可用。")
        xi_library = ctypes.util.find_library("Xi")
        if not xi_library:
            raise UserError("请安装 libxi6 以支持字幕外部点击关闭。")
        self.xlib = ctypes.CDLL(library)
        self.xi = ctypes.CDLL(xi_library)
        self.xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.xlib.XOpenDisplay.restype = ctypes.c_void_p
        self.xlib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.xlib.XDefaultRootWindow.restype = ctypes.c_ulong
        self.xlib.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                          ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                                          *([ctypes.POINTER(ctypes.c_int)] * 4), ctypes.POINTER(ctypes.c_uint)]
        self.xlib.XQueryPointer.restype = ctypes.c_int
        self.xlib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xlib.XConnectionNumber.argtypes = [ctypes.c_void_p]
        self.xlib.XConnectionNumber.restype = ctypes.c_int
        self.xlib.XPending.argtypes = [ctypes.c_void_p]
        self.xlib.XPending.restype = ctypes.c_int
        self.xlib.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.xlib.XFlush.argtypes = [ctypes.c_void_p]
        self.xi.XIQueryVersion.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]

        class EventMask(ctypes.Structure):
            _fields_ = [("deviceid", ctypes.c_int), ("mask_len", ctypes.c_int),
                        ("mask", ctypes.POINTER(ctypes.c_ubyte))]

        class Cookie(ctypes.Structure):
            _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong),
                        ("send_event", ctypes.c_int), ("display", ctypes.c_void_p),
                        ("extension", ctypes.c_int), ("evtype", ctypes.c_int),
                        ("cookie", ctypes.c_uint), ("data", ctypes.c_void_p)]

        self.cookie_type = Cookie
        self.mask_bytes = (ctypes.c_ubyte * 4)()
        self.mask = EventMask(1, 4, self.mask_bytes)  # XIAllMasterDevices
        self.xi.XISelectEvents.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                         ctypes.POINTER(EventMask), ctypes.c_int]
        self.xi.XISelectEvents.restype = ctypes.c_int
        self.display = self.xlib.XOpenDisplay(None)
        if not self.display:
            raise UserError("无法观察 X11 鼠标。")
        major, minor = ctypes.c_int(2), ctypes.c_int(0)
        if self.xi.XIQueryVersion(self.display, ctypes.byref(major), ctypes.byref(minor)) != 0:
            self.xlib.XCloseDisplay(self.display)
            self.display = None
            raise UserError("桌面未提供 XInput2 鼠标事件。")
        self.root = self.xlib.XDefaultRootWindow(self.display)
        self.notifier = QSocketNotifier(self.xlib.XConnectionNumber(self.display),
                                        QSocketNotifier.Type.Read, self)
        self.notifier.activated.connect(self.read_events)
        self.set_active(False)

    def set_active(self, active):
        if not self.display:
            return
        self.mask_bytes[1] = 0x80 if active else 0  # XI_RawButtonPress = 15
        self.xi.XISelectEvents(self.display, self.root, ctypes.byref(self.mask), 1)
        self.xlib.XFlush(self.display)
        self.notifier.setEnabled(active)

    def read_events(self, *_):
        event = (ctypes.c_long * 24)()
        while self.display and self.xlib.XPending(self.display):
            self.xlib.XNextEvent(self.display, ctypes.byref(event))
            cookie = ctypes.cast(ctypes.byref(event), ctypes.POINTER(self.cookie_type)).contents
            if cookie.type == 35 and cookie.evtype == 15:  # GenericEvent
                self.query_position()

    def query_position(self):
        root, child = ctypes.c_ulong(), ctypes.c_ulong()
        rx, ry, wx, wy = (ctypes.c_int() for _ in range(4))
        mask = ctypes.c_uint()
        if self.xlib.XQueryPointer(self.display, self.root, ctypes.byref(root), ctypes.byref(child),
                                  ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy),
                                  ctypes.byref(mask)):
            self.clicked.emit(QPoint(rx.value, ry.value))

    def close(self):
        self.notifier.setEnabled(False)
        if self.display:
            self.xlib.XCloseDisplay(self.display)
            self.display = None
