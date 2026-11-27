"""Render test-owned Qt windows under Xvfb; no real credentials or API calls."""

import sys
from PySide6.QtWidgets import QApplication
from prismtranslate.core import Settings
from prismtranslate.views import SettingsWindow, STYLE, Subtitle

app = QApplication([])
app.setStyleSheet(STYLE)
settings = Settings()
window = SettingsWindow(settings)
window.move(25, 25)
window.sample.setPlainText("Hello, PrismTranslate!\nTranslate clipboard text into floating subtitles.")
window.status.setText("Linux / Xvfb 界面验证示例")
window.show()
subtitle = Subtitle(settings)
subtitle.show_result("Hello, PrismTranslate!", "你好，棱镜翻译！\n让剪贴板与截图文字化作悬浮字幕。")
subtitle.move(650, 240)
app.processEvents()
assert app.primaryScreen().grabWindow(0).save(sys.argv[1])
