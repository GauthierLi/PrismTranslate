import AppKit
import Vision

/// Selects from immutable ScreenCaptureKit frames, then runs Vision off the
/// main actor. Decorative overlay pixels never enter the recognition image.
enum OCRService {
    enum OCRError: LocalizedError {
        case cancelled
        case captureFailed
        case noImage
        case noText
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消截图。"
            case .captureFailed: return "截图失败，请确认已授予“屏幕录制”权限。"
            case .noImage: return "无法读取截图内容。"
            case .noText: return "未在截图中识别到文本。"
            case .permissionDenied: return "请先授予棱镜翻译屏幕录制权限。"
            }
        }
    }

    @MainActor static func captureAndRecognize(languages: [String], skin: BallSkin = .classic) async throws -> String {
        let image = try await CaptureSelectionController().capture(skin: skin)
        return try await recognize(image: image, languages: languages)
    }

    static func recognize(image: CGImage, languages: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSynchronously(image: image, languages: languages)
        }.value
    }

    private static func recognizeSynchronously(image: CGImage, languages: [String]) throws -> String {
        let lines = try recognizeText(in: image, languages: languages)
        let joined = joinLines(lines)
        guard !joined.isEmpty else { throw OCRError.noText }
        return joined
    }

    /// Run Vision text recognition and return per-line strings in reading order.
    private static func recognizeText(in cgImage: CGImage, languages: [String]) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Collapse recognized lines into one line, removing internal line breaks.
    private static func joinLines(_ lines: [String]) -> String {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Remove line breaks: join with a single space, then collapse runs of
        // whitespace so the subtitle stays on one visual flow.
        let joined = cleaned.joined(separator: " ")
        let collapsed = joined
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Collapse multiple spaces.
        let parts = collapsed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.joined(separator: " ")
    }
}
