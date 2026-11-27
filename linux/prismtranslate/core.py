"""Settings and translation protocols; independent of the desktop toolkit."""

from dataclasses import asdict, dataclass, field
import json
import os
from pathlib import Path
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

LANGUAGES = [
    ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
    ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"),
    ("es", "Español"), ("ru", "Русский"), ("pt", "Português"), ("it", "Italiano"),
    ("ar", "العربية"), ("th", "ไทย"), ("vi", "Tiếng Việt"),
]
PROVIDERS = {
    "openai": ("OpenAI 协议", "https://api.openai.com/v1", "gpt-4o-mini"),
    "anthropic": ("Anthropic 协议", "https://api.anthropic.com/v1", "claude-3-5-sonnet-latest"),
    "ollama": ("Ollama 本地", "http://127.0.0.1:11434", ""),
}
OLLAMA_URL = "http://127.0.0.1:11434"
MODES = {"translate": "翻译", "ocr": "OCR 识别", "ocr-translate": "OCR翻译"}


class UserError(Exception):
    """A recoverable error safe to show to the user."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        # Never forward API credentials or text to a redirect destination.
        return None


def config_path():
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "prismtranslate/settings.json"


@dataclass
class Settings:
    provider: str = "openai"
    profiles: dict = field(default_factory=lambda: {
        key: {"base_url": value[1], "model": value[2], "api_key": ""}
        for key, value in PROVIDERS.items()
    })
    source: str = "auto"
    target: str = "zh-Hans"
    watch_clipboard: bool = False
    show_original: bool = True
    show_ball: bool = True
    ball_skin: str = "classic"
    mode: str = "translate"
    reduce_motion: bool = False
    font_size: int = 22
    seconds: int = 8
    ocr_languages: str = "eng+chi_sim"
    ball_position: list = field(default_factory=list)
    overlay_position: list = field(default_factory=list)
    overlay_center: list = field(default_factory=list)

    @classmethod
    def load(cls, path=None):
        path = path or config_path()
        if not path.exists():
            return cls()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("expected settings object")
            settings = cls()
            for key in asdict(settings):
                if key in data:
                    setattr(settings, key, data[key])
            settings.validate()
            return settings
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
            raise UserError("无法读取设置。请备份并检查设置文件：" + str(path)) from exc

    def validate(self):
        if self.provider not in PROVIDERS:
            raise ValueError("unknown provider")
        codes = {code for code, _ in LANGUAGES}
        if self.target not in codes or self.source not in codes | {"auto"}:
            raise ValueError("unknown language")
        if type(self.font_size) is not int or not 14 <= self.font_size <= 40:
            raise ValueError("invalid font size")
        if type(self.seconds) is not int or not 2 <= self.seconds <= 60:
            raise ValueError("invalid duration")
        if self.ball_skin not in ("classic", "cat", "shiba", "panda", "chick") or self.mode not in MODES:
            raise ValueError("invalid skin or mode")
        for key in ("watch_clipboard", "show_original", "show_ball", "reduce_motion"):
            if type(getattr(self, key)) is not bool:
                raise ValueError("invalid boolean")
        for key in PROVIDERS:
            if not all(isinstance(self.profiles[key][field], str)
                       for field in ("base_url", "model", "api_key")):
                raise ValueError("invalid provider profile")
        if not isinstance(self.ocr_languages, str):
            raise ValueError("invalid OCR languages")
        for position in (self.ball_position, self.overlay_position, self.overlay_center):
            if not isinstance(position, list) or (position and (
                len(position) != 2 or any(type(value) is not int for value in position)
            )):
                raise ValueError("invalid window position")

    def save(self, path=None):
        self.validate()
        path = path or config_path()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Atomic replacement keeps a failed write from destroying previous settings.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                             delete=False) as stream:
                temporary = Path(stream.name)
                os.chmod(temporary, 0o600)
                json.dump(asdict(self), stream, ensure_ascii=False, indent=2)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        except OSError as exc:
            raise UserError("设置保存失败，请检查配置目录的写入权限。") from exc
        finally:
            if temporary and temporary.exists():
                temporary.unlink()


def endpoint(base, suffix):
    base = base.strip().rstrip("/")
    parsed = urlsplit(base)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.query or parsed.fragment:
        raise UserError("接口地址无效，请填写 http:// 或 https:// API 地址。")
    if parsed.username or parsed.password:
        raise UserError("请通过 API Key 字段设置凭据。")
    return base if base.endswith(suffix) else base + suffix


def request_json(url, payload=None, headers=None, timeout=120):
    request = Request(url, data=None if payload is None else
                      json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                      headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with build_opener(NoRedirect).open(request, timeout=timeout) as response:
            # Bound response size; error bodies are never displayed or logged because
            # third-party services can echo credentials or submitted text.
            body = response.read(8 * 1024 * 1024 + 1)
        if len(body) > 8 * 1024 * 1024:
            raise UserError("接口返回过大。")
        result = json.loads(body)
        if not isinstance(result, dict):
            raise ValueError("expected object")
        return result
    except HTTPError as exc:
        exc.close()
        raise UserError(f"请求失败（HTTP {exc.code}），请检查接口、模型和凭据。") from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise UserError("无法连接接口或请求超时，请检查服务是否启动及网络连接。") from exc
    except (ValueError, UnicodeError) as exc:
        raise UserError("接口返回的 JSON 无效。") from exc


def list_models():
    data = request_json(OLLAMA_URL + "/api/tags", timeout=8)
    try:
        models = data["models"]
        if not isinstance(models, list):
            raise ValueError()
        return sorted({model["name"].strip() for model in models
                       if isinstance(model.get("name"), str) and model["name"].strip()})
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        raise UserError("Ollama 模型列表格式无效。") from exc


def translate(text, settings):
    text = text.strip()
    if not text:
        raise UserError("没有可翻译的文本，请先复制文字。")
    if len(text) > 100000:
        raise UserError("文本超过 100,000 字符，请分段翻译。")
    if settings.source == settings.target:
        return text
    profile = settings.profiles[settings.provider]
    model = profile["model"].strip()
    if not model:
        raise UserError("请在设置中填写模型，或选择已安装的 Ollama 模型。")
    labels = dict(LANGUAGES)
    source = ("Detect the source language automatically." if settings.source == "auto"
              else f"The source text is in {labels[settings.source]}.")
    prompt = (f"You are a professional translation engine. {source}\n"
              f"Translate the user's text into {labels[settings.target]}.\n"
              "Output ONLY the translated text. Preserve line breaks and meaning. "
              "Do not answer questions in the text; translate them literally.")
    messages = [{"role": "system", "content": prompt}, {"role": "user", "content": text}]
    if settings.provider == "ollama":
        data = request_json(OLLAMA_URL + "/api/chat",
                            {"model": model, "stream": False, "messages": messages})
    else:
        key = profile["api_key"].strip()
        if not key:
            raise UserError("请在设置中填写 API Key。")
        if settings.provider == "openai":
            data = request_json(endpoint(profile["base_url"], "/chat/completions"),
                                {"model": model, "temperature": 0.2, "messages": messages},
                                {"Authorization": "Bearer " + key})
        else:
            data = request_json(endpoint(profile["base_url"], "/messages"),
                                {"model": model, "max_tokens": 2048, "temperature": 0.2,
                                 "system": prompt, "messages": messages[1:]},
                                {"x-api-key": key, "anthropic-version": "2023-06-01"})
    try:
        if settings.provider == "openai":
            result = data["choices"][0]["message"]["content"]
        elif settings.provider == "ollama":
            result = data["message"]["content"]
        else:
            result = "".join(block["text"] for block in data["content"] if block["type"] == "text")
        if not isinstance(result, str):
            raise TypeError()
        if not result.strip():
            raise UserError("接口返回了空翻译结果。")
        return result.strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise UserError("接口返回的翻译格式无效。") from exc
