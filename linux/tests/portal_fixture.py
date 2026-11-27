"""Exercise the screenshot protocol on a real private D-Bus session."""

import asyncio
from pathlib import Path
import tempfile

from dbus_next import MessageType, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal

from prismtranslate.desktop import CaptureCancelled, portal_screenshot


class Request(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.portal.Request")

    @signal()
    def Response(self, code: "u", results: "a{sv}") -> "ua{sv}":
        return [code, results]


class Screenshot(ServiceInterface):
    def __init__(self, bus, image):
        super().__init__("org.freedesktop.portal.Screenshot")
        self.bus, self.image = bus, image
        self.sender = None
        self.cancel = False
        self.requests = []
        bus.add_message_handler(self.observe)

    def observe(self, message):
        if message.message_type == MessageType.METHOD_CALL and message.member == "Screenshot":
            self.sender = message.sender

    @method()
    def Screenshot(self, parent: "s", options: "a{sv}") -> "o":
        assert options["interactive"].value is True
        assert parent == ""
        sender = self.sender.lstrip(":").replace(".", "_")
        path = "/org/freedesktop/portal/desktop/request/" + sender + "/" + options["handle_token"].value
        request = Request()
        self.requests.append(request)
        self.bus.export(path, request)
        asyncio.get_running_loop().call_later(
            0.05, request.Response, 1 if self.cancel else 0,
            {} if self.cancel else {"uri": Variant("s", self.image.as_uri())})
        return path


async def run():
    with tempfile.TemporaryDirectory() as temporary:
        image = Path(temporary) / "image with spaces.png"
        image.touch()
        bus = await MessageBus().connect()
        service = Screenshot(bus, image)
        bus.export("/org/freedesktop/portal/desktop", service)
        await bus.request_name("org.freedesktop.portal.Desktop")
        try:
            assert await portal_screenshot() == image
            service.cancel = True
            try:
                await portal_screenshot()
            except CaptureCancelled:
                pass
            else:
                raise AssertionError("cancelled portal request must not appear as success")
        finally:
            bus.disconnect()


asyncio.run(run())
print("PASS: D-Bus screenshot protocol success, escaped URI and cancellation")
