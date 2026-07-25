import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case openai
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI 协议"
        case .anthropic: return "Anthropic 协议"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-sonnet-latest"
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
            providerRaw = newValue.rawValue
            objectWillChange.send()
        }
    }

    /// Reset base URL + model to provider defaults (used when switching provider).
    func applyProviderDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
