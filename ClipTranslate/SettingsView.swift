import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onProviderChange: () -> Void = {}

    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("接口协议") {
                    Picker("协议", selection: Binding(
                        get: { settings.provider },
                        set: { newValue in
                            let old = settings.provider
                            settings.provider = newValue
                            if old != newValue { settings.applyProviderDefaults() }
                            onProviderChange()
                        })
                    ) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    labeledField("接口地址 (Base URL)", text: $settings.baseURL)
                    labeledField("模型 (Model)", text: $settings.model)
                    SecureFieldRow(title: "API Key", text: $settings.apiKey)
                    Text(settings.provider == .openai
                         ? "使用 OpenAI 兼容接口：POST {BaseURL}/chat/completions"
                         : "使用 Anthropic 兼容接口：POST {BaseURL}/messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("语言") {
                    Picker("源语言", selection: $settings.sourceLanguage) {
                        ForEach(LanguageOption.all) { lang in
                            Text(lang.label).tag(lang.id)
                        }
                    }
                    Picker("目标语言", selection: $settings.targetLanguage) {
                        ForEach(LanguageOption.all.filter { $0.id != "auto" }) { lang in
                            Text(lang.label).tag(lang.id)
                        }
                    }
                }

                section("字幕显示") {
                    Toggle("同时显示原文", isOn: $settings.showOriginal)
                    Toggle("自动监听剪贴板变化", isOn: Binding(
                        get: { settings.autoWatchClipboard },
                        set: { settings.autoWatchClipboard = $0 })
                    )
                    HStack {
                        Text("字号")
                        Slider(value: $settings.overlayFontSize, in: 14...40, step: 1)
                        Text("\(Int(settings.overlayFontSize))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                    HStack {
                        Text("停留时间")
                        Slider(value: $settings.overlaySeconds, in: 3...30, step: 1)
                        Text("\(Int(settings.overlaySeconds))s")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                section("快捷键") {
                    Text("全局快捷键：⌘⇧T 翻译当前剪贴板内容")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "测试中…" : "测试翻译（Hello, world!）")
                        }
                    }
                    .disabled(testing || !settings.isConfigured)

                    if let testResult {
                        Text(testResult)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(22)
        }
        .frame(minWidth: 460, minHeight: 540)
    }

    private func runTest() {
        testing = true
        testResult = nil
        let translator = Translator(settings: settings)
        let source = settings.sourceLanguage
        let target = settings.targetLanguage
        Task { @MainActor in
            do {
                let out = try await translator.translate("Hello, world!", source: source, target: target)
                testResult = "成功：" + out
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testResult = "失败：" + msg
            }
            testing = false
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
        }
    }
}

private struct SecureFieldRow: View {
    let title: String
    @Binding var text: String
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                if reveal {
                    TextField(title, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                } else {
                    SecureField(title, text: $text)
                        .textFieldStyle(.roundedBorder)
                }
                Button(reveal ? "隐藏" : "显示") { reveal.toggle() }
            }
        }
    }
}
