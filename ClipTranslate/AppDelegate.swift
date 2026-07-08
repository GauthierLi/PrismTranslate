import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = AppSettings()
    private let overlay = OverlayController()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    // Clipboard polling
    private var clipTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    @Published var lastStatus: String = "就绪"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        setupStatusItem()
        setupHotkey()
        applyClipboardWatch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregister()
        clipTimer?.invalidate()
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

        let translateItem = NSMenuItem(title: "翻译剪贴板内容", action: #selector(translateClipboardNow), keyEquivalent: "t")
        translateItem.keyEquivalentModifierMask = [.command, .shift]
        translateItem.target = self
        menu.addItem(translateItem)

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
            self?.translateClipboardNow()
        }
        HotkeyManager.shared.register()
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

    @objc func toggleWatch() {
        settings.autoWatchClipboard.toggle()
        applyClipboardWatch()
        statusItem?.menu = buildMenu()
    }

    @objc func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.targetLanguage = code
        statusItem?.menu = buildMenu()
    }

    @objc func openSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(settings: settings, onProviderChange: { [weak self] in
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
            overlay.showError("请先在设置中填写 API Key 与接口地址。", fontSize: settings.overlayFontSize)
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
