import AppKit

/// A small draggable, always-on-top circular floating ball. A single click
/// (without dragging) opens a popup menu that lets the user toggle
/// "自动监听粘贴板" and trigger "隐藏字幕". The ball can be dragged anywhere on
/// screen; its position is remembered for the session.
///
/// Click-vs-drag is disambiguated by movement distance: if the pointer moves
/// beyond a small threshold between mouseDown and mouseUp we treat it as a
/// drag, otherwise as a click.
@MainActor
final class FloatingBallController {
    private var window: NSPanel?
    private var ballView: BallView?

    /// Supplies the popup menu shown on a click. The delegate builds it so the
    /// mode/toggle checkmarks always reflect current settings.
    var onRequestMenu: (() -> NSMenu)?

    private let ballSize: CGFloat = 52

    func show() {
        let panel = ensureWindow()
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func ensureWindow() -> NSPanel {
        if let window { return window }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ballSize, height: ballSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = BallView(frame: NSRect(x: 0, y: 0, width: ballSize, height: ballSize))
        view.onClick = { [weak self] in self?.showMenu() }
        panel.contentView = view
        ballView = view
        window = panel

        // Default position: right edge, vertically centered.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let x = vf.maxX - ballSize - 24
            let y = vf.midY - ballSize / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        return panel
    }

    private func showMenu() {
        guard let view = ballView, let menu = onRequestMenu?() else { return }
        // Pop up just below the ball.
        let origin = NSPoint(x: 0, y: -6)
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

/// Custom-drawn circular ball view that handles dragging and click detection.
final class BallView: NSView {
    var onClick: (() -> Void)?

    private var mouseDownScreenPoint: NSPoint = .zero
    private var windowOriginAtDown: NSPoint = .zero
    private var didDrag = false
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 3
        let rect = bounds.insetBy(dx: inset, dy: inset)

        // Radial-ish gradient fill using a diagonal gradient for a glossy look.
        let colors = [
            NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.98, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.92, alpha: 1.0).cgColor
        ] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }

        ctx.saveGState()
        let path = CGPath(ellipseIn: rect, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
        ctx.restoreGState()

        // Subtle outer ring.
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        // Glyph in the center.
        let glyph = "译"
        let font = NSFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: glyph, attributes: attrs)
        let size = text.size()
        let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        text.draw(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowOriginAtDown = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownScreenPoint.x
        let dy = now.y - mouseDownScreenPoint.y
        if !didDrag && (abs(dx) > dragThreshold || abs(dy) > dragThreshold) {
            didDrag = true
        }
        guard didDrag, let window else { return }
        let newOrigin = NSPoint(x: windowOriginAtDown.x + dx, y: windowOriginAtDown.y + dy)
        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            onClick?()
        }
        didDrag = false
    }

}
