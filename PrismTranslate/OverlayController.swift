import AppKit
import SwiftUI

/// Manages a borderless floating panel that shows translated text as a
/// subtitle. The panel size is computed deterministically from the text so
/// tall content grows UPWARD from a fixed bottom edge and never overflows the
/// bubble or leaves the active screen.
///
/// Interaction:
/// - Hovering pauses the auto-hide countdown; leaving resumes it.
/// - The pin button (music-style, appears on hover) locks the subtitle so it
///   stays until unpinned, and disables dragging.
/// - When unpinned the bubble can be dragged anywhere on its current screen.
@MainActor
final class OverlayController {
    private var window: NSPanel?
    private var hostingView: NSHostingView<OverlayView>?
    private var moveObserver: NSObjectProtocol?
    private let model = OverlayModel()
    private var hideTask: Task<Void, Never>?
    private var autoHideSeconds: Double = 0

    // Layout constants shared between measurement and the SwiftUI view.
    private let bubbleInsetH: CGFloat = 22
    private let bubbleInsetV: CGFloat = 14
    private let outerMargin: CGFloat = 12   // room for shadow + pin overhang
    private let textSpacing: CGFloat = 6

    /// User-chosen bubble CENTER (screen coords). nil => default bottom-center.
    /// Anchoring by center keeps the loading bubble and the result bubble
    /// visually centered on the same point.
    private var userCenter: CGPoint?
    private var isProgrammaticMove = false

    init() {
        model.onInteractionChange = { [weak self] in
            guard let self else { return }
            self.rescheduleHide()
            // Pinned subtitles cannot be dragged.
            self.window?.isMovableByWindowBackground = !self.model.isPinned
        }
    }

    func show(original: String?, translated: String, autoHideSeconds: Double, fontSize: Double, showOriginal: Bool) {
        model.original = showOriginal ? original : nil
        model.translated = translated
        model.fontSize = fontSize
        model.isError = false
        model.showPin = true
        model.selectable = true
        present(autoHide: autoHideSeconds)
    }

    func showLoading(_ message: String = "翻译中…", fontSize: Double) {
        model.original = nil
        model.translated = message
        model.fontSize = fontSize
        model.isError = false
        model.showPin = false
        model.selectable = false
        present(autoHide: 0)
    }

    func showError(_ message: String, fontSize: Double) {
        model.original = nil
        model.translated = message
        model.fontSize = fontSize
        model.isError = true
        model.showPin = false
        model.selectable = false
        present(autoHide: 6)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        window?.orderOut(nil)
    }

    private func present(autoHide seconds: Double) {
        autoHideSeconds = seconds
        // Pin persists across updates; only reset the transient hover latch.
        model.isHovering = false
        let panel = ensureWindow()
        panel.isMovableByWindowBackground = !model.isPinned
        layout(panel)
        panel.orderFrontRegardless()
        // Selectable subtitles need to be the key window so drag-select and
        // ⌘C copy are routed to the SwiftUI text; loading/error do not.
        if model.selectable {
            panel.makeKey()
        }
        rescheduleHide()
    }

    private func rescheduleHide() {
        hideTask?.cancel()
        hideTask = nil
        guard autoHideSeconds > 0 else { return }
        guard !model.isPinned, !model.isHovering else { return }
        let seconds = autoHideSeconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.window?.orderOut(nil)
        }
    }

    private func ensureWindow() -> NSPanel {
        if let window { return window }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(model: model))
        panel.contentView = host
        hostingView = host
        window = panel

        // Remember where the user drags the bubble so we can keep it there.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isProgrammaticMove, let w = self.window else { return }
                self.userCenter = CGPoint(x: w.frame.midX, y: w.frame.midY)
            }
        }
        return panel
    }

    // MARK: - Deterministic sizing

    /// Compute the panel size from the text, then place it so the BOTTOM edge
    /// stays fixed (content grows upward), clamped to the active screen.
    private func layout(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame

        let maxBubbleWidth = min(760, visible.width * 0.9 - outerMargin * 2)
        let maxTextWidth = maxBubbleWidth - bubbleInsetH * 2

        let translatedFont = NSFont.systemFont(ofSize: model.fontSize, weight: .semibold)
        let originalFont = NSFont.systemFont(ofSize: max(12, model.fontSize - 6), weight: .regular)

        // First pass: natural single-line widths to allow short text to stay compact.
        var contentWidth: CGFloat = 0
        let translatedNatural = Self.measure(model.translated, font: translatedFont, maxWidth: .greatestFiniteMagnitude).width
        contentWidth = min(maxTextWidth, translatedNatural)
        var originalNatural: CGFloat = 0
        if let original = model.original, !original.isEmpty {
            originalNatural = Self.measure(original, font: originalFont, maxWidth: .greatestFiniteMagnitude).width
            contentWidth = max(contentWidth, min(maxTextWidth, originalNatural))
        }
        contentWidth = max(120, ceil(contentWidth))

        // Second pass: heights at the resolved column width (accounts for wrapping).
        let translatedHeight = Self.measure(model.translated, font: translatedFont, maxWidth: contentWidth).height
        var totalTextHeight = translatedHeight
        if let original = model.original, !original.isEmpty {
            let originalHeight = Self.measure(original, font: originalFont, maxWidth: contentWidth).height
            totalTextHeight += originalHeight + textSpacing
        }

        model.contentWidth = contentWidth

        let bubbleWidth = contentWidth + bubbleInsetH * 2
        let bubbleHeight = ceil(totalTextHeight) + bubbleInsetV * 2
        let panelWidth = bubbleWidth + outerMargin * 2
        // Clamp height so the panel always fits on screen; +2 avoids sub-pixel clip.
        let maxPanelHeight = visible.height * 0.85
        let panelHeight = min(maxPanelHeight, bubbleHeight + outerMargin * 2 + 2)
        let size = NSSize(width: panelWidth, height: panelHeight)

        // Anchor by CENTER: the loading bubble and the result bubble are both
        // centered on the same point, so they visually overlap at the middle
        // and only grow/shrink symmetrically around it.
        let center: CGPoint
        if let c = userCenter {
            center = c
        } else {
            center = CGPoint(
                x: visible.midX,
                y: visible.minY + visible.height * 0.18
            )
        }

        // Convert center -> bottom-left origin, then clamp inside the screen.
        var x = center.x - size.width / 2
        var y = center.y - size.height / 2
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)

        isProgrammaticMove = true
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        isProgrammaticMove = false
    }

    /// Measure a string's rendered size using TextKit, matching SwiftUI wrapping.
    private static func measure(_ string: String, font: NSFont, maxWidth: CGFloat) -> NSSize {
        let attr = NSAttributedString(string: string, attributes: [.font: font])
        let bounds = attr.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(bounds.width) + 1, height: ceil(bounds.height))
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }
}

final class OverlayModel: ObservableObject {
    @Published var original: String?
    @Published var translated: String = ""
    @Published var fontSize: Double = 22
    @Published var isError: Bool = false
    @Published var showPin: Bool = true
    @Published var selectable: Bool = false
    @Published var contentWidth: CGFloat = 320

    @Published var isHovering: Bool = false {
        didSet { onInteractionChange?() }
    }
    @Published var isPinned: Bool = false {
        didSet { onInteractionChange?() }
    }

    var onInteractionChange: (() -> Void)?
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    /// Pin appears on hover, or stays while pinned so it can be toggled off.
    private var pinVisible: Bool {
        model.showPin && (model.isHovering || model.isPinned)
    }

    var body: some View {
        bubble
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.18), value: model.translated)
            .animation(.easeOut(duration: 0.15), value: model.isPinned)
            .animation(.easeInOut(duration: 0.15), value: pinVisible)
    }

    private var bubble: some View {
        VStack(alignment: .center, spacing: 6) {
            if let original = model.original, !original.isEmpty {
                Text(original)
                    .font(.system(size: max(12, model.fontSize - 6), weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(width: model.contentWidth, alignment: .center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(model.translated)
                .font(.system(size: model.fontSize, weight: .semibold))
                .foregroundStyle(model.isError ? Color(red: 1.0, green: 0.72, blue: 0.72) : .white)
                .multilineTextAlignment(.center)
                .frame(width: model.contentWidth, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(model.isPinned ? Color.yellow.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if pinVisible {
                Button {
                    model.isPinned.toggle()
                } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.isPinned ? Color.yellow : .white.opacity(0.85))
                        .padding(6)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(model.isPinned ? "已锁定：点按解锁（锁定后不可拖动）" : "锁定字幕，保持显示")
                .offset(x: 8, y: -8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            model.isHovering = hovering
        }
    }
}

/// A borderless panel that is still allowed to become the key window, so
/// selectable subtitle text can receive drag-select and ⌘C copy commands.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
