import AppKit

/// Distances are screen points, measured from the original press (not path length).
enum BallGesture {
    static let holdDuration: TimeInterval = 0.4
    static let chargeDelay: TimeInterval = 0.15
    static let movementThreshold: CGFloat = 5

    enum Phase { case idle, pressing, dragging, selecting }
    struct State {
        private(set) var phase: Phase = .idle
        private(set) var origin: CGPoint = .zero
        private(set) var beganAt: TimeInterval = 0

        mutating func begin(at point: CGPoint, time: TimeInterval) {
            origin = point
            beganAt = time
            phase = .pressing
        }

        mutating func update(at point: CGPoint, time: TimeInterval) {
            guard phase == .pressing else { return }
            if hypot(point.x - origin.x, point.y - origin.y) > movementThreshold {
                phase = .dragging
            } else if time - beganAt >= holdDuration {
                phase = .selecting
            }
        }

        mutating func cancel() { phase = .idle }
    }
}

enum BallQuickAction: CaseIterable {
    case ocr, ocrTranslate, clipboardWatch

    var symbol: String {
        switch self {
        case .ocr: return "text.viewfinder"
        case .ocrTranslate: return "character.bubble"
        case .clipboardWatch: return "doc.on.clipboard"
        }
    }

    func title(watching: Bool) -> String {
        switch self {
        case .ocr: return "OCR"
        case .ocrTranslate: return "OCR翻译"
        case .clipboardWatch: return "自动监听粘贴板  \(watching ? "开" : "关")"
        }
    }
}

/// Geometry shared by rendering and hit testing, including the press dead zone
/// retained when the ring moves inward at a screen edge.
enum BallSelectionGeometry {
    static let innerRadius: CGFloat = 36
    static let outerRadius: CGFloat = 76
    static let hitRadius: CGFloat = 96
    static let padding: CGFloat = 8
    static let gap: CGFloat = 4
    static let canvasSize = CGSize(width: 168, height: 168)

    static func direction(for action: BallQuickAction) -> CGVector {
        switch action {
        case .ocr: return CGVector(dx: -sqrt(0.5), dy: sqrt(0.5))
        case .ocrTranslate: return CGVector(dx: sqrt(0.5), dy: sqrt(0.5))
        case .clipboardWatch: return CGVector(dx: 0, dy: -1)
        }
    }

    /// Center the symbol on both the angular bisector and the ring thickness.
    static func iconCenter(for action: BallQuickAction) -> CGPoint {
        let direction = direction(for: action)
        let radius = (innerRadius + outerRadius) / 2
        return CGPoint(x: direction.dx * radius, y: direction.dy * radius)
    }

    /// Keep the bubble outside the ring, including its selection animation.
    /// Clamping alone can push an edge bubble over a wedge, so fall back to the
    /// nearest free side of the ring without moving the ring or its hit targets.
    static func bubbleFrame(for action: BallQuickAction, size: CGSize, center: CGPoint,
                            visibleFrame: CGRect) -> CGRect {
        let direction = direction(for: action)
        let clearance = outerRadius * 1.06 + 8
        let support = abs(direction.dx) * size.width / 2 + abs(direction.dy) * size.height / 2
        let distance = clearance + support
        let ideal = CGRect(x: center.x + direction.dx * distance - size.width / 2,
                           y: center.y + direction.dy * distance - size.height / 2,
                           width: size.width, height: size.height)
        func clamped(_ frame: CGRect) -> CGRect {
            CGRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width),
                   y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height),
                   width: size.width, height: size.height)
        }
        func clearsRing(_ frame: CGRect) -> Bool {
            let dx = max(frame.minX - center.x, center.x - frame.maxX, 0)
            let dy = max(frame.minY - center.y, center.y - frame.maxY, 0)
            return hypot(dx, dy) >= clearance - 0.01
        }
        let preferred = clamped(ideal)
        if clearsRing(preferred) { return preferred }
        let candidates = [
            CGRect(x: preferred.minX, y: center.y + clearance, width: size.width, height: size.height),
            CGRect(x: preferred.minX, y: center.y - clearance - size.height, width: size.width, height: size.height),
            CGRect(x: center.x - clearance - size.width, y: preferred.minY, width: size.width, height: size.height),
            CGRect(x: center.x + clearance, y: preferred.minY, width: size.width, height: size.height)
        ].map(clamped).filter(clearsRing)
        return candidates.min {
            hypot($0.midX - ideal.midX, $0.midY - ideal.midY)
                < hypot($1.midX - ideal.midX, $1.midY - ideal.midY)
        } ?? preferred
    }

    static func center(ball: CGPoint, visibleFrame: CGRect) -> CGPoint {
        let inset = outerRadius + padding
        return CGPoint(x: min(max(ball.x, visibleFrame.minX + inset), visibleFrame.maxX - inset),
                       y: min(max(ball.y, visibleFrame.minY + inset), visibleFrame.maxY - inset))
    }

    static func action(at point: CGPoint, center: CGPoint, press: CGPoint,
                       previous: BallQuickAction?, ocrBusy: Bool) -> BallQuickAction? {
        guard hypot(point.x - press.x, point.y - press.y) >= innerRadius else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= hitRadius else { return nil }
        // A narrow seam keeps the last selection rather than flickering.
        let nearSeam = abs(dy) < gap / 2 || (dy > 0 && abs(dx) < gap / 2)
        let candidate: BallQuickAction? = nearSeam ? previous
            : (dy < 0 ? .clipboardWatch : (dx < 0 ? .ocr : .ocrTranslate))
        if ocrBusy && candidate != .clipboardWatch { return nil }
        return candidate
    }

    static func path(for action: BallQuickAction) -> CGPath {
        let angles: (CGFloat, CGFloat)
        switch action {
        case .ocr: angles = (.pi / 2, .pi)
        case .ocrTranslate: angles = (0, .pi / 2)
        case .clipboardWatch: angles = (.pi, 2 * .pi)
        }
        let path = CGMutablePath()
        let outerGap = gap / (2 * outerRadius)
        let innerGap = gap / (2 * innerRadius)
        let start = angles.0
        let end = angles.1
        path.addArc(center: .zero, radius: outerRadius, startAngle: start + outerGap,
                    endAngle: end - outerGap, clockwise: false)
        path.addArc(center: .zero, radius: innerRadius, startAngle: end - innerGap,
                    endAngle: start + innerGap, clockwise: true)
        path.closeSubpath()
        return path
    }
}

@MainActor
final class BallSelectionController {
    private var panel: NSPanel?
    private var view: BallSelectionView?
    private var bubblePanel: NSPanel?
    private var bubbleView: BallSelectionBubbleView?
    private var visibleFrame: CGRect = .zero
    private var generation = 0
    private(set) var center: CGPoint = .zero
    private var pressPoint: CGPoint = .zero
    private var reduceMotion = false
    var isVisible: Bool { panel?.isVisible ?? false }
    var selected: BallQuickAction? { view?.selected }
    var bubbleIsVisible: Bool { bubblePanel?.isVisible ?? false }
    var visibleBubbleFrame: CGRect? { bubbleIsVisible ? bubblePanel?.frame : nil }

    func show(ballCenter: CGPoint, press: CGPoint, screen: NSScreen, aboveWindow: NSWindow,
              watching: Bool, ocrBusy: Bool, reduceMotion: Bool) {
        generation += 1
        self.reduceMotion = reduceMotion
        visibleFrame = screen.visibleFrame
        center = BallSelectionGeometry.center(ball: ballCenter, visibleFrame: screen.visibleFrame)
        pressPoint = press
        let panel = ensurePanel()
        view?.watching = watching
        view?.ocrBusy = ocrBusy
        view?.reduceMotion = reduceMotion
        view?.cancelLabelReveal()
        view?.selected = nil
        view?.outside = false
        view?.confirmation = false
        bubblePanel?.orderOut(nil)
        let half = BallSelectionGeometry.canvasSize.width / 2
        panel.setFrameOrigin(CGPoint(x: center.x - half, y: center.y - half))
        panel.alphaValue = reduceMotion ? 1 : 0
        view?.appearanceScale = reduceMotion ? 1 : 0.9
        panel.order(.below, relativeTo: aboveWindow.windowNumber)
        if !reduceMotion {
            view?.animateAppearance()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func update(point: CGPoint) {
        guard isVisible, let view else { return }
        view.selected = BallSelectionGeometry.action(at: point, center: center, press: pressPoint,
                                                     previous: view.selected, ocrBusy: view.ocrBusy)
        // The selection seam and outer tolerance still allow release to act,
        // but labels only appear while the pointer is inside the visible wedge.
        let local = CGPoint(x: point.x - center.x, y: point.y - center.y)
        view.hoveredForLabel = view.selected.flatMap {
            BallSelectionGeometry.path(for: $0).contains(local) ? $0 : nil
        }
        view.outside = hypot(point.x - center.x, point.y - center.y) > BallSelectionGeometry.hitRadius
    }

    func update(watching: Bool, ocrBusy: Bool) {
        view?.watching = watching
        view?.ocrBusy = ocrBusy
        if ocrBusy && view?.selected != .clipboardWatch {
            view?.selected = nil
            view?.cancelLabelReveal()
        }
        refreshBubble()
    }

    /// Completion runs only after orderOut, never during the fade. Cancellation
    /// invalidates it so hiding the ball or changing screens cannot launch OCR.
    func finish(_ completion: @escaping () -> Void) {
        guard let panel, panel.isVisible else { return }
        view?.cancelLabelReveal(hide: false, clearHover: false)
        generation += 1
        let token = generation
        if reduceMotion {
            bubblePanel?.orderOut(nil)
            panel.orderOut(nil)
            completion()
            return
        }
        view?.confirmation = selected != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (selected == nil ? 0 : 0.08)) { [weak self] in
            guard let self, self.generation == token else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                panel.animator().alphaValue = 0
                self.bubblePanel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.bubblePanel?.orderOut(nil)
                    panel.orderOut(nil)
                    completion()
                }
            })
        }
    }

    func cancel() {
        generation += 1
        bubblePanel?.orderOut(nil)
        panel?.orderOut(nil)
        view?.stopAnimation()
        view?.cancelLabelReveal()
        view?.selected = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let frame = CGRect(origin: .zero, size: BallSelectionGeometry.canvasSize)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // AppKit resets level to .floating when isFloatingPanel changes.
        // Set the shared overlay level last, as the floating ball does.
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BallSelectionView(frame: frame)
        view.onLabelChange = { [weak self] in self?.refreshBubble() }
        panel.contentView = view
        self.view = view
        self.panel = panel
        return panel
    }

    private func refreshBubble() {
        guard isVisible, let view, let action = view.labelAction else {
            bubblePanel?.orderOut(nil)
            return
        }
        let bubble = ensureBubblePanel()
        guard let bubbleView else { return }
        let size = bubbleView.setTitle(action.title(watching: view.watching))
        let frame = BallSelectionGeometry.bubbleFrame(for: action, size: size, center: center,
                                                     visibleFrame: visibleFrame)
        if bubble.frame != frame { bubble.setFrame(frame, display: true) }
        bubble.appearance = panel?.appearance
        bubble.alphaValue = view.labelOpacity
        if !bubble.isVisible { bubble.order(.above, relativeTo: panel!.windowNumber) }
    }

    private func ensureBubblePanel() -> NSPanel {
        if let bubblePanel { return bubblePanel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BallSelectionBubbleView(frame: .zero)
        panel.contentView = view
        bubbleView = view
        bubblePanel = panel
        return panel
    }
}

/// System glass is masked to the three wedges. Labels have their own dwell
/// lifecycle, independent of the immediately available release action.
final class BallSelectionView: NSView {
    static let labelDelay: TimeInterval = 0.5
    private static let labelFadeDuration: TimeInterval = 0.1
    var onLabelChange: (() -> Void)?
    var watching = false { didSet { ink.needsDisplay = true } }
    var ocrBusy = false { didSet { ink.needsDisplay = true } }
    var reduceMotion = false
    var selected: BallQuickAction? {
        didSet {
            if selected != oldValue {
                selectionStart = CACurrentMediaTime()
                startAnimation()
                ink.needsDisplay = true
            }
        }
    }
    var hoveredForLabel: BallQuickAction? {
        didSet {
            guard hoveredForLabel != oldValue else { return }
            cancelLabelReveal(hide: true, clearHover: false)
            guard let action = hoveredForLabel else { return }
            let timer = Timer(timeInterval: Self.labelDelay, repeats: false) { [weak self] _ in
                guard let self, self.hoveredForLabel == action else { return }
                self.labelTimer = nil
                self.labelAction = action
                self.labelStart = CACurrentMediaTime()
                self.ink.needsDisplay = true
                self.onLabelChange?()
                self.startAnimation()
            }
            RunLoop.main.add(timer, forMode: .common)
            labelTimer = timer
        }
    }
    private(set) var labelAction: BallQuickAction?
    var labelOpacity: CGFloat {
        guard labelAction != nil else { return 0 }
        return reduceMotion ? 1
            : CGFloat(min(1, (CACurrentMediaTime() - labelStart) / Self.labelFadeDuration))
    }
    var outside = false { didSet { alphaValue = outside ? 0.4 : 1 } }
    var confirmation = false { didSet { ink.needsDisplay = true } }
    var appearanceScale: CGFloat = 1 { didSet { updateMaterialMask(); ink.needsDisplay = true } }
    private let material = NSVisualEffectView()
    private let ink = BallSelectionInkView()
    private var timer: Timer?
    private var labelTimer: Timer?
    private var labelStart: CFTimeInterval = 0
    private var appearanceStart: CFTimeInterval = 0
    private var selectionStart: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        addSubview(material)
        ink.frame = bounds
        ink.onDraw = { [weak self] in self?.drawContents() }
        addSubview(ink)
        updateMaterialMask()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        timer?.invalidate()
        labelTimer?.invalidate()
    }

    func cancelLabelReveal(hide: Bool = true, clearHover: Bool = true) {
        labelTimer?.invalidate()
        labelTimer = nil
        if clearHover { hoveredForLabel = nil }
        if hide {
            labelAction = nil
            labelStart = 0
            ink.needsDisplay = true
            onLabelChange?()
        }
    }

    func animateAppearance() {
        appearanceStart = CACurrentMediaTime()
        startAnimation()
    }
    private func startAnimation() {
        guard !reduceMotion, timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stopAnimation() { timer?.invalidate(); timer = nil }
    private func tick() {
        let now = CACurrentMediaTime()
        if appearanceStart > 0 {
            let progress = min(1, (now - appearanceStart) / 0.12)
            appearanceScale = 0.9 + CGFloat(progress) * 0.1
            if progress == 1 { appearanceStart = 0 }
        }
        ink.needsDisplay = true
        onLabelChange?()
        if appearanceStart == 0 && now - selectionStart >= 0.1 && (labelAction == nil || labelOpacity == 1) {
            stopAnimation()
        }
    }
    private func scale(for action: BallQuickAction) -> CGFloat {
        guard selected == action, !reduceMotion else { return 1 }
        return 1 + 0.06 * CGFloat(min(1, (CACurrentMediaTime() - selectionStart) / 0.1))
    }
    private func updateMaterialMask() {
        let size = CGSize(width: bounds.width * appearanceScale, height: bounds.height * appearanceScale)
        material.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height)
        guard material.maskImage == nil else { return }
        let path = CGMutablePath()
        let transform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
        for action in BallQuickAction.allCases {
            path.addPath(BallSelectionGeometry.path(for: action), transform: transform)
        }
        // Use the material's native mask so its backdrop sampling stays intact.
        // Cache the bitmap and resize the material for the appearance animation.
        let mask = NSImage(size: bounds.size)
        mask.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        mask.unlockFocus()
        material.maskImage = mask
    }
    static func contrastingText(for color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? .systemBlue
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
    }

    private func drawContents() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: appearanceScale, y: appearanceScale)
        for action in BallQuickAction.allCases {
            ctx.saveGState()
            let scale = scale(for: action)
            ctx.scaleBy(x: scale, y: scale)
            let disabled = ocrBusy && action != .clipboardWatch
            ctx.setAlpha(disabled ? 0.4 : 1)
            let chosen = selected == action
            var fill = NSColor.controlAccentColor
            if chosen && confirmation { fill = fill.blended(withFraction: 0.16, of: .white) ?? fill }
            let path = BallSelectionGeometry.path(for: action)
            if chosen {
                ctx.addPath(path)
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            let color = chosen ? Self.contrastingText(for: fill) : NSColor.labelColor
            let center = BallSelectionGeometry.iconCenter(for: action)
            let symbol = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            if let symbol {
                let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    color.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
            }
            ctx.restoreGState()
        }
    }
}

/// A separate, pointer-transparent panel keeps glass and text outside the ring
/// while preserving its existing frame, edge translation and gesture geometry.
private final class BallSelectionBubbleView: NSView {
    private let material = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "")
    private var titleSize: CGSize = .zero
    private var maskSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byClipping
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ string: String) -> CGSize {
        if title.stringValue != string {
            title.stringValue = string
            titleSize = title.intrinsicContentSize
            needsLayout = true
        }
        return CGSize(width: ceil(titleSize.width) + 24, height: 34)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        material.frame = bounds
        title.frame = CGRect(x: 12, y: (bounds.height - titleSize.height) / 2,
                             width: bounds.width - 24, height: titleSize.height)
        if maskSize != bounds.size {
            maskSize = bounds.size
            // A drawing-handler image avoids starting a focus/layout cycle
            // while AppKit is already laying out this initially empty panel.
            material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
                return true
            }
        }
    }
}

/// AppKit paints child views after their parent's draw(). Keep all ink above
/// the material as a sibling layer so the HUD cannot cover icons and labels.
private final class BallSelectionInkView: NSView {
    var onDraw: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) { onDraw?() }
}
