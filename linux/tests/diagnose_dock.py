"""Sample the real X11 session while an existing host gesture test runs.

No Qt import, synthetic dock, window mutation, pointer grab or Shell settings
change. Only the supplied app PID's windows and numeric external focus IDs are
recorded. --command is collected synchronously before this process returns.
"""

import argparse
import ast
import ctypes as C
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


class Rectangle(C.Structure):
    _fields_ = [("x", C.c_short), ("y", C.c_short),
                ("width", C.c_ushort), ("height", C.c_ushort)]


class X11:
    def __init__(self):
        self.lib = C.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
        self.errors = []
        self.atoms = {}
        self.owned = set()
        self.functions = {
            "XOpenDisplay": ([C.c_char_p], C.c_void_p),
            "XDefaultRootWindow": ([C.c_void_p], C.c_ulong),
            "XCloseDisplay": ([C.c_void_p], C.c_int),
            "XSync": ([C.c_void_p, C.c_int], C.c_int),
            "XFree": ([C.c_void_p], C.c_int),
            "XInternAtom": ([C.c_void_p, C.c_char_p, C.c_int], C.c_ulong),
            "XGetAtomName": ([C.c_void_p, C.c_ulong], C.c_void_p),
            "XGetWindowProperty": (
                [C.c_void_p, C.c_ulong, C.c_ulong, C.c_long, C.c_long,
                 C.c_int, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_int),
                 C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.c_void_p)], C.c_int),
            "XQueryTree": ([C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                           C.POINTER(C.c_ulong), C.POINTER(C.c_void_p),
                           C.POINTER(C.c_uint)], C.c_int),
            "XGetInputFocus": ([C.c_void_p, C.POINTER(C.c_ulong),
                               C.POINTER(C.c_int)], C.c_int),
            "XQueryPointer": ([C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong),
                              C.POINTER(C.c_ulong), C.POINTER(C.c_int),
                              C.POINTER(C.c_int), C.POINTER(C.c_int),
                              C.POINTER(C.c_int), C.POINTER(C.c_uint)], C.c_int),
        }
        for name, (arguments, result) in self.functions.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result
        # A window may disappear between discovery and a query. Keep the
        # diagnostic alive and report the X error instead of exiting silently.
        callback_type = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_void_p)
        self.error_handler = callback_type(self.on_error)
        self.lib.XSetErrorHandler.argtypes = [callback_type]
        self.lib.XSetErrorHandler(self.error_handler)
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("Cannot open the current X11 DISPLAY")
        self.root = self.lib.XDefaultRootWindow(self.display)
        self.shape = C.CDLL(ctypes.util.find_library("Xext") or "libXext.so.6")
        self.shape.XShapeGetRectangles.argtypes = [
            C.c_void_p, C.c_ulong, C.c_int, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.shape.XShapeGetRectangles.restype = C.POINTER(Rectangle)

    def on_error(self, display, event):
        self.errors.append("X11 query failed (window may have been unmapped/destroyed)")
        return 0

    def property(self, window, name):
        if name not in self.atoms:
            self.atoms[name] = self.lib.XInternAtom(self.display, name.encode(), 0)
        actual_type, count, remaining = C.c_ulong(), C.c_ulong(), C.c_ulong()
        actual_format, data = C.c_int(), C.c_void_p()
        status = self.lib.XGetWindowProperty(
            self.display, window, self.atoms[name], 0, 4096, 0, 0,
            C.byref(actual_type), C.byref(actual_format), C.byref(count),
            C.byref(remaining), C.byref(data))
        try:
            if status or not data.value:
                return []
            if actual_format.value == 32:
                return list(C.cast(data, C.POINTER(C.c_ulong))[:count.value])
            return C.string_at(data, count.value).decode("utf-8", errors="replace")
        finally:
            if data.value:
                self.lib.XFree(data)

    def atom_names(self, values):
        names = []
        for value in values:
            data = self.lib.XGetAtomName(self.display, value)
            if data:
                names.append(C.string_at(data).decode("utf-8", errors="replace"))
                self.lib.XFree(data)
        return names

    def children(self):
        root, parent, count, data = C.c_ulong(), C.c_ulong(), C.c_uint(), C.c_void_p()
        self.lib.XQueryTree(self.display, self.root, C.byref(root), C.byref(parent),
                            C.byref(data), C.byref(count))
        try:
            return list(C.cast(data, C.POINTER(C.c_ulong))[:count.value]) if data.value else []
        finally:
            if data.value:
                self.lib.XFree(data)

    def input_shape(self, window):
        count, order = C.c_int(), C.c_int()
        rectangles = self.shape.XShapeGetRectangles(
            self.display, window, 2, C.byref(count), C.byref(order))
        try:
            return ([[r.x, r.y, r.width, r.height] for r in rectangles[:count.value]]
                    if rectangles else [])
        finally:
            if rectangles:
                self.lib.XFree(rectangles)

    def snapshot(self, pid):
        focused, revert = C.c_ulong(), C.c_int()
        self.lib.XGetInputFocus(self.display, C.byref(focused), C.byref(revert))
        root, child, mask = C.c_ulong(), C.c_ulong(), C.c_uint()
        rx, ry, wx, wy = (C.c_int() for _ in range(4))
        self.lib.XQueryPointer(self.display, self.root, C.byref(root), C.byref(child),
                              C.byref(rx), C.byref(ry), C.byref(wx), C.byref(wy), C.byref(mask))
        stacking = self.property(self.root, "_NET_CLIENT_LIST_STACKING")
        candidates = list(dict.fromkeys(stacking + self.children() + sorted(self.owned)))
        windows = []
        for window in candidates:
            if self.property(window, "_NET_WM_PID") != [pid]:
                self.owned.discard(window)
                continue
            self.owned.add(window)
            properties = {}
            for name in ("_NET_WM_WINDOW_TYPE", "_NET_WM_STATE"):
                properties[name] = self.atom_names(self.property(window, name))
            for name in ("WM_CLASS", "WM_TRANSIENT_FOR", "WM_HINTS", "_NET_WM_DESKTOP",
                         "WM_CLIENT_LEADER", "_NET_WM_USER_TIME"):
                properties[name] = self.property(window, name)
            # xwininfo handles windows disappearing between these queries.
            geometry = subprocess.run(
                ["xwininfo", "-id", str(window)], capture_output=True, text=True, timeout=2)
            lines = ("Absolute upper-left", "Width:", "Height:", "Map State:", "Override Redirect")
            properties["geometry"] = [line.strip() for line in geometry.stdout.splitlines()
                                      if any(label in line for label in lines)]
            properties["input_shape"] = self.input_shape(window)
            windows.append({"xid": window, **properties})
        self.lib.XSync(self.display, 0)
        result = {
            "input_focus": focused.value,
            "ewmh_active": self.property(self.root, "_NET_ACTIVE_WINDOW"),
            "pointer": [rx.value, ry.value],
            "pointer_child": child.value,
            "button_mask": mask.value,
            "app_stacking": [window for window in stacking
                             if any(info["xid"] == window for info in windows)],
            "windows": windows,
            "query_errors": self.errors[:],
        }
        self.errors.clear()
        return result

    def close(self):
        self.lib.XCloseDisplay(self.display)


def shell_state(script):
    reply = subprocess.run([
        "gdbus", "call", "--session", "--dest", "org.gnome.Shell",
        "--object-path", "/org/gnome/Shell", "--method", "org.gnome.Shell.Eval", script,
    ], capture_output=True, text=True, timeout=2)
    if reply.returncode:
        return {"unavailable": reply.stderr.strip()}
    result = ast.literal_eval(reply.stdout.replace("(true,", "(True,", 1)
                              .replace("(false,", "(False,", 1))
    if not result[0]:
        return {"unavailable": "Shell.Eval returned false; unsafe-mode was not changed",
                "detail": result[1]}
    return json.loads(result[1])


def environment(output):
    for name, command in (
        ("gnome-version", ["gnome-shell", "--version"]),
        ("dock-settings", ["gsettings", "list-recursively", "org.gnome.shell.extensions.dash-to-dock"]),
        ("extension-info", ["gnome-extensions", "info", "ubuntu-dock@ubuntu.com"]),
    ):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=3)
            (output / (name + ".txt")).write_text(
                result.stdout + result.stderr, encoding="utf-8")
        except (OSError, subprocess.TimeoutExpired) as error:
            (output / (name + ".txt")).write_text(str(error), encoding="utf-8")
    sources = []
    for origin, base in (("system", Path("/usr/share/gnome-shell/extensions")),
                         ("user", Path.home() / ".local/share/gnome-shell/extensions")):
        for uuid in ("ubuntu-dock@ubuntu.com", "dash-to-dock@micxgx.gmail.com"):
            for name in ("metadata.json", "docking.js", "intellihide.js"):
                path = base / uuid / name
                if path.is_file():
                    data = path.read_bytes()
                    destination = output / (origin + "-" + uuid + "-" + name)
                    destination.write_bytes(data)
                    sources.append({"file": destination.name,
                                    "sha256": hashlib.sha256(data).hexdigest()})
    (output / "sources.json").write_text(json.dumps(sources, indent=2), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True, help="PID of the existing isolated app")
    parser.add_argument("--out", type=Path, required=True, help="New output directory")
    parser.add_argument("--seconds", type=float, default=20, help="Minimum sampling duration")
    parser.add_argument("--interval", type=float, default=.1)
    parser.add_argument("--shell-eval", action="store_true",
                        help="Read Shell internals if Eval is already allowed; never enables it")
    parser.add_argument("--command", nargs=argparse.REMAINDER,
                        help="Existing host test command; waited to completion")
    args = parser.parse_args()
    if args.pid <= 0 or not 0 < args.seconds <= 120 or not .05 <= args.interval <= 2:
        parser.error("Use a positive PID, 0 < seconds <= 120 and .05 <= interval <= 2")
    os.kill(args.pid, 0)
    args.out.mkdir(mode=0o700, parents=True, exist_ok=False)
    environment(args.out)
    native = X11()
    command = None
    try:
        with (args.out / "trace.jsonl").open("w", encoding="utf-8") as trace:
            started = time.monotonic()
            script = Path(__file__).with_name("dock_state.js").read_text(encoding="utf-8")
            use_shell, next_shell = args.shell_eval, 0
            before = native.snapshot(args.pid)
            if use_shell:
                try:
                    before["shell"] = shell_state(script)
                except (OSError, subprocess.TimeoutExpired, ValueError, SyntaxError) as error:
                    before["shell"] = {"unavailable": str(error)}
                use_shell = "unavailable" not in before["shell"]
            trace.write(json.dumps({"elapsed": 0, "label": "before-command", **before}) + "\n")
            trace.flush()
            if args.command:
                command = subprocess.Popen(args.command)
                trace.write(json.dumps({"elapsed": round(time.monotonic() - started, 4),
                                        "label": "command-started", "pid": command.pid}) + "\n")
            while time.monotonic() - started < args.seconds or (
                    command is not None and command.poll() is None):
                tick = time.monotonic()
                sample = {"elapsed": round(tick - started, 4), **native.snapshot(args.pid)}
                if use_shell and tick >= next_shell:
                    try:
                        sample["shell"] = shell_state(script)
                    except (OSError, subprocess.TimeoutExpired, ValueError, SyntaxError) as error:
                        sample["shell"] = {"unavailable": str(error)}
                    if "unavailable" in sample["shell"]:
                        use_shell = False
                    next_shell = time.monotonic() + .25
                sample["sample_ms"] = round((time.monotonic() - tick) * 1000, 2)
                trace.write(json.dumps(sample, ensure_ascii=False) + "\n")
                trace.flush()
                time.sleep(max(0, args.interval - (time.monotonic() - tick)))
            if command:
                code = command.wait()
                trace.write(json.dumps({"elapsed": round(time.monotonic() - started, 4),
                                        "command_exit": code}) + "\n")
                if code:
                    raise RuntimeError("Host command failed with exit code " + str(code))
    finally:
        # An interruption/query error still collects the child before exit.
        if command is not None and command.poll() is None:
            command.wait()
        native.close()
    print("Diagnostic saved:", args.out)


if __name__ == "__main__":
    main()
