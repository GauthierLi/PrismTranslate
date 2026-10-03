import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    private let overlay = OverlayController()
    private let floatingBall = FloatingBallController()
    private let ollamaModelStore = OllamaModelStore()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    // Clipboard polling
    private var clipTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    @Published var lastStatus: String = "就绪"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        setupMainMenu()
        setupStatusItem()
        setupHotkey()
        setupFloatingBall()
        applyClipboardWatch()
        refreshOllamaModelsIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        clipTimer?.invalidate()
        floatingBall.hide()
    }

    // MARK: - Main menu (enables standard ⌘C / ⌘A on selectable subtitles)

    /// An accessory/LSUIElement app has no menu bar by default, so keyboard
    /// shortcuts like ⌘C are never matched. We install a minimal main menu with
    /// an Edit submenu so the standard `copy:` / `selectAll:` commands are
    /// dispatched through the responder chain to the focused subtitle text.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (holds Quit so ⌘Q keeps working).
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 棱镜翻译", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu with the standard editing commands.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func refreshOllamaModelsIfNeeded() {
        guard settings.provider == .ollama, !ollamaModelStore.isRefreshing else { return }

        Task { @MainActor in
            do {
                let discovered = try await ollamaModelStore.refresh()
                let current = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !discovered.contains(where: { $0.name == current }) {
                    settings.model = discovered.first?.name ?? ""
                }
            } catch {
                lastStatus = "Ollama 不可用"
            }
        }
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "翻译")
            button.image?.isTemplate = true
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // Primary action adapts to the current mode.
        if settings.appMode == .ocr {
            let ocrItem = NSMenuItem(title: "截图识别 (OCR)", action: #selector(runOCRNow), keyEquivalent: "t")
            ocrItem.keyEquivalentModifierMask = [.command, .shift]
            ocrItem.target = self
            menu.addItem(ocrItem)
        } else {
            let translateItem = NSMenuItem(title: "翻译剪贴板内容", action: #selector(translateClipboardNow), keyEquivalent: "t")
            translateItem.keyEquivalentModifierMask = [.command, .shift]
            translateItem.target = self
            menu.addItem(translateItem)
        }

        // Mode switch submenu.
        let modeItem = NSMenuItem(title: "功能", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in AppMode.allCases {
            let mi = NSMenuItem(title: mode.label, action: #selector(selectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = (settings.appMode == mode) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let hideItem = NSMenuItem(title: "隐藏字幕", action: #selector(hideOverlay), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        // Target language submenu
        let langItem = NSMenuItem(title: "目标语言", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in LanguageOption.all where lang.id != "auto" {
            let mi = NSMenuItem(title: lang.label, action: #selector(selectTargetLanguage(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = lang.id
            mi.state = (settings.targetLanguage == lang.id) ? .on : .off
            langMenu.addItem(mi)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        let watchItem = NSMenuItem(title: "自动监听剪贴板", action: #selector(toggleWatch), keyEquivalent: "")
        watchItem.target = self
        watchItem.state = settings.autoWatchClipboard ? .on : .off
        menu.addItem(watchItem)

        let ballItem = NSMenuItem(title: "显示悬浮球", action: #selector(toggleFloatingBall), keyEquivalent: "")
        ballItem.target = self
        ballItem.state = settings.showFloatingBall ? .on : .off
        menu.addItem(ballItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        HotkeyManager.shared.onFire = { [weak self] in
            self?.primaryAction()
        }
        HotkeyManager.shared.register()
    }

    // MARK: - Floating ball

    private func setupFloatingBall() {
        floatingBall.onRequestMenu = { [weak self] in
            self?.buildBallMenu() ?? NSMenu()
        }
        applyFloatingBall()
    }

    /// Menu shown when the floating ball is clicked. Mirrors the menu-bar
    /// actions but is scoped to the ball.
    private func buildBallMenu() -> NSMenu {
        let menu = NSMenu()

        // Primary action for the current mode.
        if settings.appMode == .ocr {
            let ocrItem = NSMenuItem(title: "截图识别 (OCR)", action: #selector(runOCRNow), keyEquivalent: "")
            ocrItem.target = self
            menu.addItem(ocrItem)
        } else {
            let translateItem = NSMenuItem(title: "翻译剪贴板内容", action: #selector(translateClipboardNow), keyEquivalent: "")
            translateItem.target = self
            menu.addItem(translateItem)
        }

        // Mode switch.
        let modeItem = NSMenuItem(title: "功能", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in AppMode.allCases {
            let mi = NSMenuItem(title: mode.label, action: #selector(selectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = (settings.appMode == mode) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let watchItem = NSMenuItem(title: "自动监听粘贴板", action: #selector(toggleWatch), keyEquivalent: "")
        watchItem.target = self
        watchItem.state = settings.autoWatchClipboard ? .on : .off
        menu.addItem(watchItem)

        let hideItem = NSMenuItem(title: "隐藏字幕", action: #selector(hideOverlay), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        return menu
    }

    func applyFloatingBall() {
        if settings.showFloatingBall {
            floatingBall.show()
        } else {
            floatingBall.hide()
        }
    }

    // MARK: - Clipboard watching

    func applyClipboardWatch() {
        clipTimer?.invalidate()
        clipTimer = nil
        lastChangeCount = NSPasteboard.general.changeCount
        guard settings.autoWatchClipboard else { return }
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipTimer = timer
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translate(text: text)
    }

    // MARK: - Actions

    @objc func translateClipboardNow() {
        let pb = NSPasteboard.general
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.showError("剪贴板没有可翻译的文本。", fontSize: settings.overlayFontSize)
            return
        }
        translate(text: text)
    }

    @objc func hideOverlay() {
        overlay.hide()
    }

    /// Fired by the hotkey / ball; routes to translate or OCR by mode.
    @objc func primaryAction() {
        if settings.appMode == .ocr {
            runOCRNow()
        } else {
            translateClipboardNow()
        }
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = AppMode(rawValue: raw) else { return }
        settings.appMode = mode
        statusItem?.menu = buildMenu()
    }

    @objc func runOCRNow() {
        let fontSize = settings.overlayFontSize
        let seconds = settings.overlaySeconds
        // Vision recognition languages: bias by target language, always allow
        // English + Simplified/Traditional Chinese which cover the common cases.
        let langs = ocrLanguages(for: settings.targetLanguage)
        overlay.hide()
        Task { @MainActor in
            do {
                let text = try await OCRService.captureAndRecognize(languages: langs)
                // OCR result is shown directly as a selectable subtitle (no
                // translation), line breaks already removed by the service.
                overlay.show(original: nil, translated: text, autoHideSeconds: seconds, fontSize: fontSize, showOriginal: false)
                lastStatus = "已识别"
            } catch OCRService.OCRError.cancelled {
                lastStatus = "已取消"
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                overlay.showError(msg, fontSize: fontSize)
                lastStatus = "错误"
            }
        }
    }

    /// Preferred Vision recognition languages, with sensible fallbacks.
    private func ocrLanguages(for target: String) -> [String] {
        var langs: [String] = []
        switch target {
        case "zh-Hans": langs = ["zh-Hans", "en-US"]
        case "zh-Hant": langs = ["zh-Hant", "en-US"]
        case "ja": langs = ["ja-JP", "en-US"]
        case "ko": langs = ["ko-KR", "en-US"]
        default: langs = ["en-US", "zh-Hans"]
        }
        return langs
    }

    @objc func toggleWatch() {
        settings.autoWatchClipboard.toggle()
        applyClipboardWatch()
        statusItem?.menu = buildMenu()
    }

    @objc func toggleFloatingBall() {
        settings.showFloatingBall.toggle()
        applyFloatingBall()
        statusItem?.menu = buildMenu()
    }

    @objc func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.targetLanguage = code
        statusItem?.menu = buildMenu()
    }

    @objc func openSettings() {
        if let win = settingsWindow {
            refreshOllamaModelsIfNeeded()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        refreshOllamaModelsIfNeeded()
        let view = SettingsView(settings: settings, ollamaModels: ollamaModelStore, onProviderChange: { [weak self] in
            self?.refreshOllamaModelsIfNeeded()
            self?.statusItem?.menu = self?.buildMenu()
        }, onFloatingBallChange: { [weak self] in
            self?.applyFloatingBall()
            self?.statusItem?.menu = self?.buildMenu()
        })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "棱镜翻译 设置"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 480, height: 560))
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Translation flow

    private func translate(text: String) {
        guard settings.isConfigured else {
            let message = settings.provider == .ollama
                ? "请先启动 Ollama，并在设置中选择一个已安装的模型。"
                : "请先在设置中填写 API Key、接口地址和模型。"
            overlay.showError(message, fontSize: settings.overlayFontSize)
            openSettings()
            return
        }
        let target = settings.targetLanguage

        // Local, offline pre-check: if the copied text is already in the target
        // language, skip translation entirely (no network request, no subtitle).
        if LanguageDetector.isAlready(in: target, text: text) {
            overlay.hide()
            lastStatus = "无需翻译"
            return
        }

        overlay.showLoading(fontSize: settings.overlayFontSize)
        let translator = Translator(settings: settings)
        let source = settings.sourceLanguage
        let showOriginal = settings.showOriginal
        let seconds = settings.overlaySeconds
        let fontSize = settings.overlayFontSize

        Task { @MainActor in
            do {
                let result = try await translator.translate(text, source: source, target: target)
                overlay.show(original: text, translated: result, autoHideSeconds: seconds, fontSize: fontSize, showOriginal: showOriginal)
                lastStatus = "已翻译"
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                overlay.showError(msg, fontSize: fontSize)
                lastStatus = "错误"
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {}
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // keep reference; do nothing special
    }
}
