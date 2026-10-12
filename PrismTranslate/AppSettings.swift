import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case openai
    case anthropic
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI 协议"
        case .anthropic: return "Anthropic 协议"
        case .ollama: return "Ollama 本地"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .ollama: return OllamaClient.defaultBaseURL
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-sonnet-latest"
        case .ollama: return ""
        }
    }
}

/// Primary function of the app: translate clipboard/text, or OCR from a
/// screenshot selection.
enum AppMode: String, CaseIterable, Identifiable, Codable {
    case translate
    case ocr

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translate: return "翻译"
        case .ocr: return "OCR 识别"
        }
    }
}

/// A single selectable target/source language option.
struct LanguageOption: Identifiable, Hashable {
    let id: String   // stable code we send to the model, e.g. "zh-Hans"
    let label: String

    static let all: [LanguageOption] = [
        LanguageOption(id: "auto", label: "自动检测（仅源语言）"),
        LanguageOption(id: "zh-Hans", label: "简体中文"),
        LanguageOption(id: "zh-Hant", label: "繁体中文"),
        LanguageOption(id: "en", label: "English"),
        LanguageOption(id: "ja", label: "日本語"),
        LanguageOption(id: "ko", label: "한국어"),
        LanguageOption(id: "fr", label: "Français"),
        LanguageOption(id: "de", label: "Deutsch"),
        LanguageOption(id: "es", label: "Español"),
        LanguageOption(id: "ru", label: "Русский"),
        LanguageOption(id: "pt", label: "Português"),
        LanguageOption(id: "it", label: "Italiano"),
        LanguageOption(id: "ar", label: "العربية"),
        LanguageOption(id: "th", label: "ไทย"),
        LanguageOption(id: "vi", label: "Tiếng Việt"),
    ]

    static func label(for code: String) -> String {
        all.first(where: { $0.id == code })?.label ?? code
    }
}

/// Persisted, observable user settings. Backed by UserDefaults.
final class AppSettings: ObservableObject {
    @AppStorage("provider") var providerRaw: String = ProviderKind.openai.rawValue {
        didSet { objectWillChange.send() }
    }
    @AppStorage("baseURL") var baseURL: String = ProviderKind.openai.defaultBaseURL
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("model") var model: String = ProviderKind.openai.defaultModel
    @AppStorage("openaiBaseURL") private var openaiBaseURL: String = ""
    @AppStorage("openaiApiKey") private var openaiApiKey: String = ""
    @AppStorage("openaiModel") private var openaiModel: String = ""
    @AppStorage("anthropicBaseURL") private var anthropicBaseURL: String = ""
    @AppStorage("anthropicApiKey") private var anthropicApiKey: String = ""
    @AppStorage("anthropicModel") private var anthropicModel: String = ""
    @AppStorage("ollamaModel") private var ollamaModel: String = ""
    @AppStorage("sourceLanguage") var sourceLanguage: String = "auto"
    @AppStorage("targetLanguage") var targetLanguage: String = "zh-Hans"

    // Overlay behavior
    @AppStorage("autoWatchClipboard") var autoWatchClipboard: Bool = false
    @AppStorage("overlaySeconds") var overlaySeconds: Double = 8.0
    @AppStorage("overlayFontSize") var overlayFontSize: Double = 22.0
    @AppStorage("showOriginal") var showOriginal: Bool = true

    // Floating ball
    @AppStorage("showFloatingBall") var showFloatingBall: Bool = true

    // Primary mode (translate / ocr)
    @AppStorage("appMode") var appModeRaw: String = AppMode.translate.rawValue {
        didSet { objectWillChange.send() }
    }

    var appMode: AppMode {
        get { AppMode(rawValue: appModeRaw) ?? .translate }
        set {
            appModeRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    var provider: ProviderKind {
        get { ProviderKind(rawValue: providerRaw) ?? .openai }
        set {
            let oldProvider = provider
            guard oldProvider != newValue else { return }
            saveCurrentConfiguration(for: oldProvider)
            providerRaw = newValue.rawValue
            restoreConfiguration(for: newValue)
            objectWillChange.send()
        }
    }

    /// Restore the selected provider's saved configuration, or its defaults on first use.
    func applyProviderDefaults() {
        restoreConfiguration(for: provider)
    }

    private func saveCurrentConfiguration(for provider: ProviderKind) {
        switch provider {
        case .openai:
            openaiBaseURL = baseURL
            openaiApiKey = apiKey
            openaiModel = model
        case .anthropic:
            anthropicBaseURL = baseURL
            anthropicApiKey = apiKey
            anthropicModel = model
        case .ollama:
            ollamaModel = model
        }
    }

    private func restoreConfiguration(for provider: ProviderKind) {
        switch provider {
        case .openai:
            baseURL = openaiBaseURL.nonEmptyValue ?? ProviderKind.openai.defaultBaseURL
            apiKey = openaiApiKey
            model = openaiModel.nonEmptyValue ?? ProviderKind.openai.defaultModel
        case .anthropic:
            baseURL = anthropicBaseURL.nonEmptyValue ?? ProviderKind.anthropic.defaultBaseURL
            apiKey = anthropicApiKey
            model = anthropicModel.nonEmptyValue ?? ProviderKind.anthropic.defaultModel
        case .ollama:
            baseURL = ProviderKind.ollama.defaultBaseURL
            apiKey = ""
            model = ollamaModel
        }
    }

    var isConfigured: Bool {
        Self.isConfigured(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model
        )
    }

    static func isConfigured(
        provider: ProviderKind,
        apiKey: String,
        baseURL: String,
        model: String
    ) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }

        switch provider {
        case .ollama:
            return true
        case .openai, .anthropic:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
