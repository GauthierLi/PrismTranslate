import Foundation
import NaturalLanguage

/// Local, offline language detection using Apple's NaturalLanguage framework.
/// Used to decide whether copied text is already in the target language so we
/// can skip the network translation request entirely.
enum LanguageDetector {

    /// Returns true when `text` is confidently already in `targetCode`
    /// (one of our LanguageOption ids, e.g. "zh-Hans", "en", "ja").
    static func isAlready(in targetCode: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to judge reliably (e.g. a single symbol or number).
        guard trimmed.count >= 2 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let dominant = recognizer.dominantLanguage else { return false }

        let confidence = hypotheses[dominant] ?? 0
        // Require reasonable confidence to avoid false skips on mixed content.
        guard confidence >= 0.65 else { return false }

        return matches(detected: dominant, target: targetCode)
    }

    /// Map an NLLanguage to whether it corresponds to our target code.
    private static func matches(detected: NLLanguage, target: String) -> Bool {
        switch target {
        case "zh-Hans":
            // Treat all Chinese as a match for Simplified target; script differences
            // are handled by the model when translation does run.
            return detected == .simplifiedChinese || detected == .traditionalChinese
        case "zh-Hant":
            return detected == .traditionalChinese || detected == .simplifiedChinese
        case "en": return detected == .english
        case "ja": return detected == .japanese
        case "ko": return detected == .korean
        case "fr": return detected == .french
        case "de": return detected == .german
        case "es": return detected == .spanish
        case "ru": return detected == .russian
        case "pt": return detected == .portuguese
        case "it": return detected == .italian
        case "ar": return detected == .arabic
        case "th": return detected == .thai
        case "vi": return detected == .vietnamese
        default:
            return false
        }
    }
}
