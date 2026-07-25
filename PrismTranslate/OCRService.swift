import AppKit
import Vision

/// Captures an interactive screen selection via `screencapture -i` and runs
/// Apple's Vision text recognition on the result. Recognized lines are joined
/// into a single line (line breaks removed) for display as a subtitle.
///
/// Requires "Screen Recording" permission (System Settings → Privacy & Security
/// → Screen Recording) for `screencapture` to capture other apps' windows.
enum OCRService {
    enum OCRError: LocalizedError {
        case cancelled
        case captureFailed
        case noImage
        case noText

        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消截图。"
            case .captureFailed: return "截图失败，请确认已授予“屏幕录制”权限。"
            case .noImage: return "无法读取截图内容。"
            case .noText: return "未在截图中识别到文本。"
            }
        }
    }

    /// Launch interactive region capture, then OCR it. Returns joined single-line text.
    /// Runs the blocking parts off the main actor.
    static func captureAndRecognize(languages: [String]) async throws -> String {
        let tmp = NSTemporaryDirectory() + "prismtranslate-ocr-\(UUID().uuidString).png"
        let url = URL(fileURLWithPath: tmp)
        defer { try? FileManager.default.removeItem(at: url) }

        try await runScreencapture(to: tmp)

        guard FileManager.default.fileExists(atPath: tmp) else {
            // User pressed Esc: screencapture exits 0 but writes nothing.
            throw OCRError.cancelled
        }
        guard let image = NSImage(contentsOfFile: tmp),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.noImage
        }

        let lines = try recognizeText(in: cgImage, languages: languages)
        let joined = joinLines(lines)
        guard !joined.isEmpty else { throw OCRError.noText }
        return joined
    }

    /// Invoke the system screenshot tool for interactive region selection.
    private static func runScreencapture(to path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i interactive, -x no sound.
            proc.arguments = ["-i", "-x", path]
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: OCRError.captureFailed)
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: OCRError.captureFailed)
            }
        }
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
