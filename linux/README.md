# 棱镜翻译 · Linux

Qt 原生桌面端，支持 Ubuntu **20.04、22.04、24.04**，Python **3.8–3.12**。提供 amd64 和 arm64 打包入口；是否完成对应架构验证以测试报告为准。macOS 仍使用仓库原有 Swift 实现。

Linux 端覆盖三种翻译服务、独立离线语言判断、三种快捷键功能模式、剪贴板监听、悬浮字幕、五种浮球皮肤与动画、长按环形菜单、截图选区宠物、截图 OCR/翻译、跨屏裁剪、图片文件 OCR 和设置持久化。逐项功能 / UI 对照及平台限制见 [PARITY.md](PARITY.md)。

## 安装与启动

推荐使用对应架构的 `.deb`。它包含离线 Python wheels，首次启动在当前用户的数据目录创建运行环境，不访问 pip 仓库。系统库与 Tesseract 由 apt 安装，因此安装系统依赖时仍可能需要网络。

```bash
sudo apt install ./prismtranslate_0.2.0_amd64.deb
prismtranslate
```

应用可从桌面启动器打开。初次打开显示设置页；关闭设置页后仍可通过系统托盘或悬浮棱镜操作。没有托盘时，不允许同时关闭设置页和隐藏棱镜。退出应用使用菜单中的“退出棱镜翻译”。

无需安装 `.deb` 也可解压 tar 包。先准备系统依赖（Ubuntu 三个版本使用同一组包名）：

```bash
sudo apt install python3-venv ca-certificates libgl1 libegl1 libfontconfig1 libdbus-1-3 \
  libgssapi-krb5-2 \
  libxkbcommon-x11-0 libxi6 libxcb-cursor0 libxcb-icccm4 libxcb-image0 \
  libxcb-keysyms1 libxcb-render-util0 libxcb-xinerama0 libxcb-randr0 \
  libxcb-shape0 libxcb-xfixes0 tesseract-ocr tesseract-ocr-eng \
  tesseract-ocr-chi-sim fonts-noto-cjk xdg-desktop-portal
tar -xzf prismtranslate-0.2.0-linux-amd64.tar.gz
./prismtranslate-0.2.0-linux-amd64/bin/prismtranslate
```

`bin/prismtranslate` 可以加入 PATH 或绑定到系统快捷键。tar 包没有注册桌面启动器。

## 翻译与 OCR

1. 在设置页选择协议。远程模式填写 API 地址、API Key、模型；Ollama 模式连接 `127.0.0.1:11434`，点击“刷新本机 Ollama 模型”后选择已安装模型。应用不会安装 Ollama 或下载模型。
2. 选择源/目标语言并保存。在下方输入文字，用“测试翻译”检查服务。
3. 复制文本后点击“翻译剪贴板”。如果本地判断已是目标语言（置信度至少 0.65），不发请求、不显示字幕。字幕出现后悬停可固定，选择文字后 Ctrl+C 复制；未固定时可拖动，鼠标停留时暂停自动关闭。
4. “截图识别”只做本地 OCR，“截图翻译”会将识别文字发送到所选翻译接口。X11 使用框选；Wayland 使用系统截屏授权界面，可用的区域/窗口选择由桌面 portal 后端决定。
5. OCR 默认使用 `eng+chi_sim`。其他语言需要安装对应 Tesseract 数据包，并在设置中填写语言代码；`tesseract --list-langs` 可检查本机语言。设置窗口中可用 `Ctrl+O` 打开图片 OCR、`Ctrl+Q` 退出。
6. 设置或菜单可切换五种皮肤。单击浮球打开菜单；按下后移动超过 5px 进入拖动，保持 0.4秒进入环形菜单。移动到左上 OCR、右上 OCR翻译、下方自动监听分区后释放执行；中央释放、Esc、失去活动状态取消。监听开启时显示耳机；任务触发表情，减少动态效果可关闭连续动画。
7. 设置自动保存，接口和模式使用分段选项。Ctrl+Shift+T 执行所选模式，不总是翻译剪贴板。

### 桌面会话差异

| 能力 | X11 | Wayland |
| --- | --- | --- |
| 剪贴板、字幕、设置、文件 OCR | 支持 | 支持；剪贴板是否允许后台读取取决于合成器 |
| 全局快捷键 | 自动注册 Ctrl+Shift+T 执行所选模式，冲突时显示提示 | 在系统设置绑定下方命令 |
| 截图 OCR | Qt 截屏后拖动框选，Esc 取消 | xdg-desktop-portal 系统交互截屏，取消恢复原窗口 |
| 窗口置顶/位置 | 向窗口管理器请求置顶与位置 | 合成器可能限制置顶和程序定位 |
| 系统托盘 | 依桌面支持 | 依桌面支持；GNOME 可能需 AppIndicator 扩展 |

```bash
prismtranslate --action translate       # 翻译剪贴板
prismtranslate --action primary         # 执行设置中选定的模式
prismtranslate --action ocr             # 截图 OCR
prismtranslate --action ocr-translate   # 截图翻译
```

这些命令通过仅当前用户可访问的 Unix socket 调用现有实例。没有运行实例时启动应用并执行操作，不会启动多个剪贴板监听器。

## 数据位置与移除

- 配置：`${XDG_CONFIG_HOME:-~/.config}/prismtranslate/settings.json`，原子保存，文件权限 `600`。远程 API Key 在本地保存但**未加密**；不会记录到日志。不要共享此文件。
- Python 环境：`${XDG_DATA_HOME:-~/.local/share}/prismtranslate/runtime-*`，按打包内容和 Python 版本区分，升级不会覆盖正在使用的环境。
- IPC：`$XDG_RUNTIME_DIR/prismtranslate.sock`；未设置时使用配置目录。路径超过 Linux Unix socket 的 107 字节限制时，使用 `/tmp/prismtranslate-<用户 ID>-<原目录哈希>/ipc.sock`，该目录仅当前用户可访问（`700`）。锁文件位于 socket 同目录；退出后 socket 和锁文件删除，短路径空目录保留。
- X11 临时截屏在 OCR 后删除；Wayland 返回的图片由系统截屏服务管理。
- 卸载程序：`sudo apt remove prismtranslate`。配置和用户环境保留；退出应用后可手工删除上述用户目录。

## 构建

```bash
python3 linux/build.py --arch amd64
# 或：python3 linux/build.py --arch arm64
```

产物在 `build-linux/`：`.deb`、`.tar.gz` 和带 SHA-256 的 manifest。打包器可在 macOS/Linux 运行，它只组装源代码和预编译 wheels，不在构建机上编译 Linux 二进制。默认从当前 pip 源下载依赖；可通过 `PIP_INDEX_URL` 切换包源，或用 `--wheel-dir` 指定已有 wheel 目录。

固定 `PySide6-Essentials==6.6.3.1` 与 `shiboken6==6.6.3.1`：Python 下限 3.8，amd64 wheel 的 glibc 下限 2.28，arm64 下限 2.31。Ubuntu 20.04 的 glibc 为 2.31。包内带 `pip==24.3.1`，先离线更新 venv 中的 pip，解决 20.04 自带旧 pip 不能识别现代 manylinux 标签的问题。不要改用较新 Qt wheel 或在 24.04 冻结为二进制后声称兼容 20.04。

独立语言判断使用 `langdetect==1.0.9` 与 `six==1.17.0`。构建器将纯 Python 源码和随包语言模型组装为 `py3-none-any` wheel，不生成新的平台二进制。首次运行不联网下载模型。Apple NaturalLanguage / Vision 在 Linux 不可用，识别概率和 OCR 结果不保证与 Apple 引擎逐字一致。

依赖元数据：[PySide6 Essentials 6.6.3.1](https://pypi.org/project/PySide6-Essentials/6.6.3.1/)。Wayland 协议：[Screenshot portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Screenshot.html)。

## 验证

源码验证：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r linux/requirements.txt
PYTHONPATH=linux .venv/bin/python -m unittest discover -s linux/tests -v
PYTHONPATH=linux QT_QPA_PLATFORM=offscreen .venv/bin/python -m prismtranslate --smoke-test
```

`tests/test_core.py` 使用真实本机 HTTP 服务检查三种协议、鉴权、错误和模型发现，不调用付费接口。桌面测试覆盖窗口、异步翻译、OCR、顶栏偏移后的预览与裁剪像素、混合 DPI 合成、皮肤、真实长按 / 拖动 / 取消、语言判断和长路径单实例进程。X11 下还检查真实快捷键。`wm_fixture.py` 使用 Openbox 与保留 27px 的顶栏验证真全屏；`ring_capture_fixture.py` 使用 Openbox、xcompmgr 和底部自动隐藏 Dock，验证长按两种 OCR 入口在全屏激活后冻结画面、正反拖选的预览与裁剪、取消恢复，以及 IPC / 菜单 / 快捷键入口。两者均不是 GNOME 实机结果。

三版本容器验证：

```bash
./linux/tests/test_ubuntu.sh
```

此脚本核对 manifest 中正式 `.deb` / tar 的 SHA-256，在每个 Ubuntu 版本安装同一个 amd64 `.deb`，以安装包源码运行测试，执行 Openbox 顶栏夹具和正式 tar smoke。需要 Docker 和网络下载系统依赖。容器使用 Xvfb，**不能证明实际 GNOME、Wayland portal、托盘、多屏或物理 DPI 行为**。实际主机应另外完成下面的手工步骤。

### 5080 主机验收

每个版本都记录 `lsb_release -ds`、`uname -m`、Python 版本、`echo "$XDG_SESSION_TYPE"`。5080 若只装一个版本，另两版运行容器脚本；实际桌面检查至少在主机当前版本完成。

1. 安装 `.deb`，从桌面启动器打开。预期：设置页与悬浮棱镜显示，无启动错误；关闭设置仍能打开菜单。
2. 使用现有 Ollama 模型刷新并选择，或由用户在设置页输入远程接口配置。翻译 `Hello, PrismTranslate!` 到简体中文。预期：字幕显示中文，不出现凭据；错误配置有可读提示，窗口仍可操作。不要在测试报告中粘贴密钥或私人文本。
3. 复制文字，测试菜单、X11 Ctrl+Shift+T 或 Wayland 自定义快捷键；开启自动监听再测试。预期：每次任务只触发一个请求，复制译文不自动循环翻译。
4. 保持 GNOME 顶栏存在，打开含 `Hello PrismTranslate` 和中文的测试页面，在屏幕顶部、中部、底部分别执行截图 OCR/截图翻译，正向和反向拖选、小区域重选、Esc/系统取消。预期：选区窗口全屏覆盖 `screen.geometry()`（包括顶栏），背景不缩放；选区与裁剪像素位置一致，OCR 可复制，截图翻译出中文，取消后窗口恢复，可再次截图。
5. 字幕固定后等待超过设置时间，再取消固定；拖动、复制、长文本滚动。预期：固定时常驻且不拖动，解锁后可拖动，未固定字幕按计时关闭，悬停暂停。
6. 重启应用，确认服务、语言、字幕和浮球位置保持；不同屏幕尺寸检查窗口仍可见。启动第二次或使用 `--action`，预期：复用一个进程。菜单退出后进程和快捷键释放。
7. 切换五种皮肤并重启检查存储；拍摄各皮肤、耳机、忙碌 / 成功 / 错误表情、长按环形菜单和截图宠物。测试短按、长按、拖动、边缘吸附、中心 / Esc / 失焦取消，确认环形标签不挡分区，忙时不可重复 OCR。
8. 对照 `PARITY.md` 检查模式快捷键、菜单勾选、自动保存、API Key显隐、字幕加载 / 固定 / 外部点击关闭和离线同语言判断（应为零网络请求）。若有 Wayland，检查 portal 授权、取消、置顶和托盘；若无该会话，明确标记未测。

## 当前差异

- Linux 实现五种皮肤、动画、环形菜单、选区宠物和独立离线语言判断。系统字体、AppKit 模糊材质及 Apple 识别引擎存在平台差异，详见对照表。
- Wayland 合成器可能限制后台剪贴板与悬浮窗口位置。区域截屏选项由 portal 后端提供；不支持的桌面可用“从图片识别”。
- Python 3.13 及以上未支持。容器测试与实际桌面测试应分开报告。
