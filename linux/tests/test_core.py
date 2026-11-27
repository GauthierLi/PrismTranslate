import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import stat
import tempfile
import threading
import unittest
from unittest.mock import patch

from prismtranslate import core


class Handler(BaseHTTPRequestHandler):
    records = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.reply({"models": [{"name": " test-model "}, {"name": ""}, {"name": "test-model"}]})

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.records.append((self.path, data, {key.lower(): value for key, value in self.headers.items()}))
        if data["model"] == "redirect":
            self.send_response(302)
            self.send_header("Location", "/unexpected")
            self.end_headers()
            return
        if data["model"] == "invalid":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"secret must never be shown")
            return
        if self.path.endswith("/messages"):
            self.reply({"content": [{"type": "text", "text": "你好"}, {"type": "text", "text": "世界"}]})
        elif self.path.endswith("/api/chat"):
            self.reply({"message": {"content": " 你好世界 "}})
        else:
            self.reply({"choices": [{"message": {"content": " 你好世界 "}}]})

    def reply(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever)
        cls.thread.start()
        cls.url = "http://127.0.0.1:" + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def settings(self, provider):
        settings = core.Settings(provider=provider)
        settings.profiles[provider] = {"base_url": self.url + "/v1/", "api_key": "test-key", "model": "test"}
        return settings

    def test_three_protocols_over_http(self):
        for provider in core.PROVIDERS:
            with self.subTest(provider=provider), patch.object(core, "OLLAMA_URL", self.url):
                self.assertEqual(core.translate("Hello world", self.settings(provider)), "你好世界")
                path, data, headers = Handler.records[-1]
                self.assertEqual(data["messages"][-1]["content"], "Hello world")
                if provider == "openai":
                    self.assertEqual(path, "/v1/chat/completions")
                    self.assertEqual(headers["authorization"], "Bearer test-key")
                elif provider == "anthropic":
                    self.assertEqual(headers["x-api-key"], "test-key")
                    self.assertEqual(headers["anthropic-version"], "2023-06-01")
                    self.assertEqual(data["max_tokens"], 2048)
                else:
                    self.assertEqual(path, "/api/chat")
                    self.assertIs(data["stream"], False)
                    self.assertNotIn("authorization", headers)

    def test_model_discovery(self):
        with patch.object(core, "OLLAMA_URL", self.url):
            self.assertEqual(core.list_models(), ["test-model"])

    def test_endpoint_accepts_root_or_full_endpoint(self):
        self.assertEqual(core.endpoint(self.url + "/v1/", "/messages"), self.url + "/v1/messages")
        self.assertEqual(core.endpoint(self.url + "/v1/messages", "/messages"), self.url + "/v1/messages")
        for base in ("file:///etc/passwd", "https://host/path?key=secret", "http://user:pass@host"):
            with self.assertRaises(core.UserError):
                core.endpoint(base, "/messages")

    def test_error_does_not_expose_server_body(self):
        settings = self.settings("openai")
        settings.profiles["openai"]["model"] = "invalid"
        with self.assertRaises(core.UserError) as captured:
            core.translate("hello", settings)
        self.assertIn("401", str(captured.exception))
        self.assertNotIn("secret", str(captured.exception))

    def test_redirect_does_not_forward_credentials_or_text(self):
        settings = self.settings("openai")
        settings.profiles["openai"]["model"] = "redirect"
        count = len(Handler.records)
        with self.assertRaises(core.UserError) as captured:
            core.translate("hello", settings)
        self.assertIn("302", str(captured.exception))
        self.assertEqual(len(Handler.records), count + 1)

    def test_same_explicit_language_skips_request(self):
        settings = core.Settings(source="en", target="en")
        self.assertEqual(core.translate("Hello", settings), "Hello")

    def test_settings_roundtrip_and_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "settings.json"
            settings = self.settings("anthropic")
            settings.ball_position = [20, 40]
            settings.save(path)
            self.assertEqual(core.Settings.load(path), settings)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            settings.provider = "openai"
            settings.save(path)
            self.assertEqual(core.Settings.load(path).profiles["anthropic"]["api_key"], "test-key")
            self.assertEqual(len(list(path.parent.iterdir())), 1)

    def test_corrupt_settings_are_not_silently_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "settings.json"
            for data in ("invalid", "[]", '{"font_size": 900}', '{"profiles": {}}', '{"show_ball": "false"}'):
                path.write_text(data)
                with self.assertRaises(core.UserError):
                    core.Settings.load(path)
                self.assertEqual(path.read_text(), data)

    def test_missing_configuration_and_empty_results(self):
        with self.assertRaises(core.UserError):
            core.translate("", core.Settings())
        with self.assertRaises(core.UserError):
            core.translate("hello", core.Settings())
        with patch.object(core, "request_json", return_value={"choices": [{"message": {"content": ""}}]}):
            with self.assertRaises(core.UserError):
                core.translate("hello", self.settings("openai"))
        with patch.object(core, "request_json", return_value={"choices": []}):
            with self.assertRaises(core.UserError):
                core.translate("hello", self.settings("openai"))


if __name__ == "__main__":
    unittest.main()
