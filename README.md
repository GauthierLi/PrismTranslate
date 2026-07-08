# 棱镜翻译 (PrismTranslate)

一个 macOS 菜单栏小工具：把复制的文本通过 AI 接口翻译，并以悬浮字幕的形式显示在屏幕上。支持 OpenAI 与 Anthropic 两种协议，可自定义接口地址、模型与目标语言。

![logo](Resources/logo.png)

## 功能特性

- 双协议支持：OpenAI 兼容接口（`POST {BaseURL}/chat/completions`）与 Anthropic 兼容接口（`POST {BaseURL}/messages`），可填写自定义 Base URL、模型名与 API Key，兼容各类中转端点。
- 一键翻译剪贴板：全局快捷键 `⌘⇧T` 翻译当前剪贴板内容；也可开启“自动监听剪贴板”，复制即译。
- 多语言：目标语言可在菜单栏或设置中切换（简/繁中文、英、日、韩、法、德、西、俄、葡、意、阿、泰、越等），源语言可设为自动检测。
- 本地语言判断：使用 Apple `NaturalLanguage` 框架在本地离线判断，若复制内容已经是目标语言，则直接跳过翻译，不发起网络请求。
- 悬浮字幕：半透明气泡显示在屏幕上，根据文本长度自动计算尺寸并向上扩展，中心锚定保持位置稳定。
- 交互：鼠标悬浮暂停自动消失；右上角图钉按钮（悬浮时出现）可锁定字幕使其常驻；未锁定时可拖动气泡到任意位置，锁定后禁止拖动但仍自适应高度。
- 可调项：字号、停留时长、是否同时显示原文。

## 环境要求

- macOS 13 及以上（Apple Silicon / arm64）。
- 需要 Xcode Command Line Tools（提供 `swiftc`、`iconutil`、`hdiutil` 等）。
- 一个可用的 OpenAI 或 Anthropic 兼容接口及其 API Key。

## 目录结构

```text
PrismTranslate/
├── build.sh                    # 编译为 棱镜翻译.app（含图标注入、ad-hoc 签名）
├── make_dmg.sh                 # 打包为 棱镜翻译.dmg
├── ClipTranslate/              # Swift 源码
│   ├── Main.swift              # @main 程序入口
│   ├── AppDelegate.swift       # 菜单栏、全局快捷键、剪贴板监听、翻译流程编排
│   ├── AppSettings.swift       # 用户设置、持久化、语言与协议定义
│   ├── Translator.swift        # OpenAI / Anthropic 协议请求与解析
│   ├── LanguageDetector.swift  # 本地离线语言检测（跳过同语言翻译）
│   ├── OverlayController.swift # 悬浮字幕窗口：尺寸计算、拖动、pin、自动消失
│   └── SettingsView.swift      # 设置界面（SwiftUI）
└── Resources/
    ├── logo.png                # 原始 Logo
    └── AppIcon.icns            # 应用图标
```

## 构建

```bash
./build.sh        # 产物：build/棱镜翻译.app
./make_dmg.sh     # 产物：build/棱镜翻译.dmg
```

`build.sh` 会用 `swiftc` 直接编译 `ClipTranslate/*.swift`，写入 `Info.plist`（`LSUIElement=true`，即仅菜单栏、无 Dock 图标），复制 `AppIcon.icns`，并做 ad-hoc 代码签名以便本机运行。

如需从 `Resources/logo.png` 重新生成图标，可参考以下步骤生成 `AppIcon.iconset` 后用 `iconutil -c icns` 打包（图标为运行 `build.sh` 的前置资源，已随仓库提供）。

## 使用

1. 打开 `棱镜翻译.app`（或从 `棱镜翻译.dmg` 拖入“应用程序”）。首次打开若被 Gatekeeper 拦截：右键 →“打开”，或在“系统设置 → 隐私与安全性”中点“仍要打开”。
2. 应用仅在菜单栏显示（棱镜图标），无 Dock 图标。
3. 点击菜单 →“设置…”，选择协议，填入 Base URL、模型与 API Key，可用“测试翻译”验证连通性。
4. 复制任意文本，按 `⌘⇧T`（或开启“自动监听剪贴板”）即可翻译并显示字幕。

## 权限与隐私

- 全局快捷键基于 Carbon HotKey，无需辅助功能权限。
- 仅读取系统剪贴板中的文本用于翻译。
- API Key 保存在本地 `UserDefaults`（明文），仅用于向你配置的接口发起请求，不上传到其他任何服务。

## 分发说明

DMG 为 ad-hoc 签名、未做 Apple 公证。本机使用没有问题；分发给他人时对方需右键“打开”放行。若要免警告分发，需要 Apple 开发者账号完成签名与公证。

## 已知限制

- 目标架构为 arm64，未构建 Intel/通用二进制。
- 全局快捷键当前固定为 `⌘⇧T`。
- 本地语言检测对超短文本或中英混排的判断偏保守，命中不确定时会照常翻译而非跳过。
