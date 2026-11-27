# LIWE-16：GNOME 长按环与 Dock 诊断

`06f5141` 在 5080 的 D1–D9 回归失败；死区松手再走 IPC 也有 Dock。当前还没有证据把根因归到某个窗口属性。此诊断不调整截图等待时间，也不代表 D 已修复。

先在 **5080 原 GNOME 42.9 / X11 会话**中复用 `06f5141` 的隔离应用、公开测试页和上一轮脚本。采样器不启动另一个应用、不改变窗口/焦点/指针、不修改 GNOME 配置，不需要 sudo 或额外 Python 包。它只记录指定 PID 的原生窗口属性、输入区域、栈顺序及外部焦点的数字 ID；不采集私人窗口标题、剪贴板、API 配置或截图。

将 `diagnose_dock.py` 和 `dock_state.js` 放到同一目录。`APP_PID` 是已有隔离应用的主 Python 进程 PID；用该会话已有的 Python 3.8+ 运行。输出目录必须尚不存在。示例（将 `hosttest3` 替换成既有脚本所在目录）：

```bash
python3 diagnose_dock.py --pid "$APP_PID" --out ./D1-native \
  --seconds 25 --command bash hosttest3/run.sh D1 100 1350 650 85 forward ring-ocr
```

命令在前台运行并收集测试脚本的退出码。采样时长是最低时长；脚本尚未结束时继续采样，最终等待脚本结束。JSONL 有实际采样耗时，不假定 100ms 采样精度。正常采样不会执行 Shell 的 JS。`xwininfo` 必須可用（上一轮已有）；还需要当前桌面的 libX11 和 libXext。

分别采集以下对照，每次先让原测试页恢复活动、用此前的像素判据确认 Dock 为 0 行；若无法恢复，记录并停止，不能把后一个用例的初始污染当成它的结果：

1. **短按/普通菜单**和 **IPC OCR**：作为 0 行基线。
2. **长按中央死区松手，不截图**：保持指针在浮球附近，采集至少 10 秒，再单独采集后续 IPC OCR。
3. **长按 OCR**、**长按 OCR翻译**：选中分区时停留超过 500ms，让标签实际显示；松手后把指针停在中部，采集至少 10 秒。
4. **同样两个长按入口，选中后立即松手**：不等标签显示，区分环窗口与延迟标签。

保留原测试截图和 Dock 行数时间线，注明按下、环出现、分区选中、标签出现、松手、选择器出现、Dock 首次出现时刻。`trace.jsonl` 中重点检查 `_NET_WM_WINDOW_TYPE`、`WM_TRANSIENT_FOR`、`WM_HINTS`、`_NET_WM_DESKTOP`、`_NET_WM_STATE`、实际几何、`input_shape`、焦点和 app 栈顺序。空 `input_shape` 才表示原生输入区域为空；Qt 的 `WA_TransparentForMouseEvents` 本身不足以证明这一点。

若此会话已经允许只读 `org.gnome.Shell.Eval`，加上 `--shell-eval` 同步记录 Dock 的 `state`、`slide`、`hover`、`ignoreHover`、`requiresVisibility`、intellihide `overlap`、`topApp`、`focusApp` 和当前焦点的类型/矩形。Eval 被拒绝就记录 unavailable，不启用 unsafe-mode。也可在已有 Looking Glass 中执行 `dock_state.js` 的表达式，分别记录死区松手前后及 Dock 出现前后结果。空 `docks` 表示该版本的内部入口不匹配，须报告，不能解释成 Dock 已隐藏。

采样器附带收集本机 Dock 设置和实际安装的 `docking.js`、`intellihide.js`、`metadata.json` 及 SHA-256，用于核对 Ubuntu 的补丁版本。当前静态排查参考 dash-to-dock 的 `extensions.gnome.org-v72` 源码：

- `Intellihide._doCheckOverlap()` 会因新窗口、重叠和应用栈变化重新选取 `_topApp`。
- `handledWindowTypes` 包含 `UTILITY`；普通 Qt `Tool` 窗口会进入这类候选。
- `DockedDash._updateDashVisibility()` 在 intellihide 无重叠时显示 Dock；`_onDragStart()`、hover、`dash.requiresVisibility` 等也能要求显示。
- `QuickRing` 和标签当前为两个无 Qt 父窗口的置顶 `Tool`，有独立原生窗口、全工作区请求；应由实机数据判断究竟哪条分支触发。

以上是待验证机制，不是已确认根因。若只拿到 X11 属性而 Shell 状态不可读取，请先回传已有数据和缺项，暂不试改 Dock 配置或加延时。

找到触发链并修复后，仍须使用正式产物在 5080 重跑 D1–D9、死区→IPC 对照及 IPC/菜单/快捷键三入口，要求 Dock 均为 0 行。Openbox 夹具只验证窗口/截图契约，不能判定 GNOME 修复成功。
