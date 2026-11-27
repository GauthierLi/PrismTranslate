# Linux 版本验证记录

本次使用同一份 `prismtranslate_0.1.0_amd64.deb` 和 tar 包，在三个 Ubuntu amd64 容器中安装、启动并运行检查。容器在本机 Apple Silicon Docker 上通过 Rosetta 执行 amd64 程序，图形会话为 Xvfb / Qt xcb。

| Ubuntu | 容器 Python | 容器 glibc | deb / tar 安装与启动 | 功能检查 |
| --- | --- | --- | --- | --- |
| 20.04 | 3.8.10 | 2.31 | 通过 | 17 / 17，无跳过 |
| 22.04 | 3.10.12 | 2.35 | 通过 | 17 / 17，无跳过 |
| 24.04 | 3.12.3 | 2.39 | 通过 | 17 / 17，无跳过 |

检查覆盖：

- 真实本机 HTTP 服务上的 OpenAI、Anthropic、Ollama 请求、鉴权、模型发现、空响应、失败反馈与禁止转发重定向请求。
- 配置原子保存、文件权限 `600`、损坏配置反馈、协议配置切换。
- Qt 字幕纯文本显示、长文本滚动、固定与复制；小窗口下主要按钮可见。
- 真实 Tesseract 英文识别与缺失语言包反馈；反向框选及模拟两倍 DPI 的像素坐标。
- 真实 X11 全局快捷键事件、异步翻译、剪贴板监听及复制译文后的循环保护。
- 分段发送的单实例 IPC 命令；Wayland 会话下 Qt 使用 xcb 时仍选择 portal 路径。
- 在独立 D-Bus 会话中使用测试 portal 服务检查成功、带空格的 URI 和取消反馈。

安装包先离线更新 venv 中的 pip，再安装固定版本的 Qt wheels；三个版本均无需从 pip 源下载运行依赖。系统依赖由 apt 安装。本次修正了旧 dpkg 不支持 PAX 扩展头、20.04 缺少 `libgssapi-krb5-2`、精简镜像缺少系统 CA 证书的问题。deb 使用 GNU tar 格式，显式声明相关运行依赖。

## 产物校验

```text
4a7f351ff27780a563ae8ed4d18c4ee0cfcc439bee790695bfc67d8932863065  prismtranslate_0.1.0_amd64.deb
0b9b1a4c1e370016b99f63333c48a68d8b6bf305330067bbd61cc260ee48ba4f  prismtranslate-0.1.0-linux-amd64.tar.gz
```

## 复现

构建机需有 Python 和 pip；本次使用独立 Python 环境执行 `linux/build.py --arch amd64`，下载或复用固定 wheels。随后运行：

```bash
./linux/tests/test_ubuntu.sh
```

必要时通过 `PRISM_TEST_REGISTRY` 指定 Ubuntu 镜像仓库，通过 `PRISM_TEST_APT_MIRROR` 指定 apt 镜像。测试脚本可从宿主机标准 CA bundle 引导精简镜像的 HTTPS 软件源，仍验证 TLS；之后安装系统 `ca-certificates`。

日志和 Qt 界面截图生成在 `build-linux/verification/`。截图中的翻译内容是明确标注的界面验证示例；HTTP 翻译检查使用测试服务，未调用付费接口或真实 Ollama 模型。

## 验证边界与剩余验收

- **5080 主机尚未实际安装与测试。** 主机验收步骤见 [Linux 说明](../linux/README.md#5080-主机验收)。主机只有一个 Ubuntu 版本时，另外两版可使用容器脚本；报告应分别注明实机桌面或 Docker / Xvfb。
- Xvfb 和测试 D-Bus 服务不能证明真实 Wayland portal、系统托盘、窗口管理器、多屏、物理 DPI 或后台剪贴板权限行为。
- 真正的远程翻译服务、实际 Ollama 模型和中文截图准确率需要主机验收。
- 本次只验证 amd64。arm64 有打包入口，未构建和运行验证。
- Linux 提供经典棱镜浮球；宠物皮肤、动画与环形菜单尚未移植。自动语言判断交给模型，不使用 Apple NaturalLanguage。
- 额外运行的既有 macOS capture / Ollama 检查通过；ball 检查在建立外部前台窗口时失败，未计作通过。未重新构建 macOS App / DMG。
