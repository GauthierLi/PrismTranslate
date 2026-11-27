import AppKit

/// Expression of the floating ball, driven by the translate / OCR flow so the
/// ball reacts to what the app is doing.
enum BallMood {
    case idle
    case busy   // spinner ring until the next mood change
    case happy  // short bounce, then back to idle
    case sad    // short shake, then back to idle
}

/// A small draggable, always-on-top floating ball. A left or right click
/// (without dragging) opens a popup menu built by the delegate. The ball can be
/// dragged anywhere on screen; a drop near a side edge snaps to that edge, and
/// the final position is remembered across launches.
///
/// Moving before the hold threshold drags the ball; a stationary hold opens
/// the quick-action ring. Releasing in its dead zone cancels the action.
@MainActor
final class FloatingBallController {
    private var window: NSPanel?
    private var ballView: BallView?
    private var screenObserver: NSObjectProtocol?
    private var cancellationObservers: [NSObjectProtocol] = []
    private var escapeMonitor: Any?
    private let selection = BallSelectionController()

    /// Supplies the popup menu shown on a click. The delegate builds it so the
    /// mode/toggle checkmarks always reflect current settings.
    var onRequestMenu: (() -> NSMenu)?
    var onQuickAction: ((BallQuickAction) -> Void)?
    var watchingClipboard = false {
        didSet {
            ballView?.wearingHeadphones = watchingClipboard
            selection.update(watching: watchingClipboard, ocrBusy: ocrBusy)
        }
    }
    var ocrBusy = false {
        didSet { selection.update(watching: watchingClipboard, ocrBusy: ocrBusy) }
    }

    var skin: BallSkin = .classic {
        didSet { ballView?.skin = skin }
    }

    private let originDefaultsKey = "floatingBallOrigin"
    /// A drop closer than this to a side edge snaps the ball onto that edge.
    private let snapDistance: CGFloat = 48
    /// Gap kept between the ball and the screen edge.
    private let edgeMargin: CGFloat = 6

    func show() {
        let panel = ensureWindow()
        panel.orderFrontRegardless()
        ballView?.startAnimating()
    }

    func hide() {
        cancelSelection()
        ballView?.stopAnimating()
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func setMood(_ mood: BallMood) {
        ballView?.setMood(mood)
    }

    private func ensureWindow() -> NSPanel {
        if let window { return window }

        let size = BallView.canvasSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The view draws its own soft shadow; a window shadow would lag behind
        // the breathing / hover animation.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = BallView(frame: NSRect(origin: .zero, size: size))
        view.skin = skin
        view.setHeadphonesInitially(watchingClipboard)
        view.onClick = { [weak self] in self?.showMenu() }
        view.onDragEnd = { [weak self] in self?.settleAfterDrag() }
        view.onSelectionBegin = { [weak self] press, still in self?.beginSelection(press: press, still: still) }
        view.onSelectionMove = { [weak self] point in self?.selection.update(point: point) }
        view.onSelectionEnd = { [weak self] in self?.finishSelection() }
        panel.contentView = view
        ballView = view
        window = panel

        panel.setFrameOrigin(restoredOrigin() ?? defaultOrigin())
        // Keep the ball reachable when displays are added, removed or resized.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelSelection()
                self?.clampIntoScreen()
            }
        }
        cancellationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancelSelection() } })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            cancellationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.cancelSelection() } })
        }
        cancellationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.cancelSelection() }
        })
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.selection.isVisible == true {
                self?.cancelSelection()
                return nil
            }
            return event
        }
        return panel
    }

    private func beginSelection(press: CGPoint, still: Bool) {
        guard let window else { return }
        let center = CGPoint(x: window.frame.minX + BallView.ballCenter.x,
                             y: window.frame.minY + BallView.ballCenter.y)
        guard let screen = screen(containing: center) else { return }
        selection.show(ballCenter: center, press: press, screen: screen, aboveWindow: window,
                       watching: watchingClipboard, ocrBusy: ocrBusy, reduceMotion: still)
    }

    private func finishSelection() {
        let action = selection.selected
        selection.finish { [weak self] in
            guard let self, let action else { return }
            self.onQuickAction?(action)
        }
    }

    private func cancelSelection() {
        ballView?.cancelGesture()
        selection.cancel()
    }

    private func showMenu() {
        cancelSelection()
        guard let view = ballView, let menu = onRequestMenu?() else { return }
        // Pop up just below the visible ball.
        let ball = BallView.ballRectInCanvas
        menu.popUp(positioning: nil, at: NSPoint(x: ball.minX, y: ball.minY - 6), in: view)
    }

    // MARK: - Positioning

    /// The ball's on-screen rect when the window sits at `origin`.
    private func ballFrame(forOrigin origin: NSPoint) -> NSRect {
        BallView.ballRectInCanvas.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Window origin that keeps the ball inside `vf` (minus the edge margin),
    /// optionally snapped onto a nearby side edge.
    private func clampedOrigin(_ origin: NSPoint, in vf: NSRect, snap: Bool) -> NSPoint {
        let ball = BallView.ballRectInCanvas
        let minX = vf.minX + edgeMargin - ball.minX
        let maxX = vf.maxX - edgeMargin - ball.maxX
        let minY = vf.minY + edgeMargin - ball.minY
        let maxY = vf.maxY - edgeMargin - ball.maxY
        var x = min(max(origin.x, minX), maxX)
        let y = min(max(origin.y, minY), maxY)
        if snap {
            if x - minX < snapDistance {
                x = minX
            } else if maxX - x < snapDistance {
                x = maxX
            }
        }
        return NSPoint(x: x, y: y)
    }

    /// Default position: right edge, vertically centered.
    private func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.maxX, y: vf.midY - BallView.canvasSize.height / 2)
        return clampedOrigin(origin, in: vf, snap: true)
    }

    private func restoredOrigin() -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: originDefaultsKey) else { return nil }
        let origin = NSPointFromString(raw)
        // Ignore a saved spot on a display that is no longer attached.
        let ball = ballFrame(forOrigin: origin)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(ball) }) else { return nil }
        return clampedOrigin(origin, in: screen.visibleFrame, snap: false)
    }

    private func settleAfterDrag() {
        guard let window else { return }
        let ball = ballFrame(forOrigin: window.frame.origin)
        guard let screen = screen(containing: NSPoint(x: ball.midX, y: ball.midY)) else { return }
        let target = clampedOrigin(window.frame.origin, in: screen.visibleFrame, snap: true)
        move(window, to: target, animated: true)
        UserDefaults.standard.set(NSStringFromPoint(target), forKey: originDefaultsKey)
    }

    private func clampIntoScreen() {
        guard let window else { return }
        let ball = ballFrame(forOrigin: window.frame.origin)
        guard let screen = screen(containing: NSPoint(x: ball.midX, y: ball.midY)) else { return }
        move(window, to: clampedOrigin(window.frame.origin, in: screen.visibleFrame, snap: false), animated: false)
    }

    private func move(_ window: NSWindow, to origin: NSPoint, animated: Bool) {
        guard origin != window.frame.origin else { return }
        let frame = NSRect(origin: origin, size: window.frame.size)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in cancellationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
}

/// Colors that define a skin: head gradient and an accent used by the busy
/// ring and the sleeping "z".
struct SkinPalette {
    let top: CGColor
    let bottom: CGColor
    let accent: CGColor
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

extension BallSkin {
    var palette: SkinPalette {
        switch self {
        case .classic: return SkinPalette(top: rgb(0.36, 0.44, 0.98), bottom: rgb(0.55, 0.30, 0.92), accent: rgb(0.45, 0.38, 0.98))
        case .cat: return SkinPalette(top: rgb(1.00, 0.74, 0.42), bottom: rgb(0.95, 0.55, 0.22), accent: rgb(0.93, 0.48, 0.15))
        case .shiba: return SkinPalette(top: rgb(0.93, 0.62, 0.30), bottom: rgb(0.86, 0.50, 0.22), accent: rgb(0.85, 0.45, 0.18))
        case .panda: return SkinPalette(top: rgb(1.00, 1.00, 1.00), bottom: rgb(0.88, 0.89, 0.91), accent: rgb(0.20, 0.20, 0.22))
        case .chick: return SkinPalette(top: rgb(1.00, 0.91, 0.42), bottom: rgb(1.00, 0.78, 0.22), accent: rgb(0.98, 0.60, 0.10))
        }
    }
}

/// Custom-drawn ball view: renders the selected skin, runs the idle / hover /
/// mood animations, and handles dragging and click detection.
final class BallView: NSView {
    /// Window content size. The ball is smaller than the canvas so that ears,
    /// the busy ring, the hover scale and the soft shadow all fit inside.
    static let canvasSize = NSSize(width: 72, height: 72)
    static let ballRadius: CGFloat = 23
    static let ballCenter = CGPoint(x: 36, y: 33)
    static var ballRectInCanvas: NSRect {
        NSRect(x: ballCenter.x - ballRadius, y: ballCenter.y - ballRadius,
               width: ballRadius * 2, height: ballRadius * 2)
    }

    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onSelectionBegin: ((CGPoint, Bool) -> Void)?
    var onSelectionMove: ((CGPoint) -> Void)?
    var onSelectionEnd: (() -> Void)?
    var wearingHeadphones = false {
        didSet {
            guard oldValue != wearingHeadphones else { return }
            headphoneStart = CACurrentMediaTime()
            headphoneInitialOpacity = headphoneOpacity
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                headphoneOpacity = wearingHeadphones ? 1 : 0
                headphoneStart = 0
            }
            needsDisplay = true
        }
    }
    var skin: BallSkin = .classic {
        didSet { needsDisplay = true }
    }

    private var mouseDownScreenPoint: NSPoint = .zero
    private var windowOriginAtDown: NSPoint = .zero
    private var didDrag = false
    private var isPressed = false
    private var isHovered = false
    private var gesture = BallGesture.State()
    private var holdTimer: Timer?
    private var lastPointerScreenPoint: CGPoint = .zero
    private var reduceGestureMotion = false
    private var chargeProgress: CGFloat = 0
    private var headphoneStart: CFTimeInterval = 0
    private var headphoneInitialOpacity: CGFloat = 0
    private var headphoneOpacity: CGFloat = 0

    func setHeadphonesInitially(_ enabled: Bool) {
        wearingHeadphones = enabled
        headphoneOpacity = enabled ? 1 : 0
        headphoneStart = 0
    }

    // Animation state, advanced by `tick()` at 30 fps while the ball is shown.
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var time: TimeInterval = 0
    private var hover: CGFloat = 0      // eased toward isHovered, 0...1
    private var press: CGFloat = 0      // eased toward a click press, 0...1
    private var lift: CGFloat = 0       // eased toward dragging, 0...1
    private var pupil: CGPoint = .zero  // gaze direction, length 0...1
    private var nextBlink: TimeInterval = 3
    private var blinkStart: TimeInterval = -1
    private var mood: BallMood = .idle
    private var moodStart: TimeInterval = 0
    private var lastInteraction: TimeInterval = 0

    private let blinkDuration: TimeInterval = 0.16
    private let happyDuration: TimeInterval = 1.4
    private let sadDuration: TimeInterval = 1.6
    /// Without hover, clicks or mood changes for this long, the pet dozes off.
    private let sleepAfter: TimeInterval = 90

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("棱镜翻译悬浮球")
        setAccessibilityHelp("单击打开菜单；长按可选择 OCR、OCR翻译或自动监听粘贴板；按住拖动可移动。")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Animation

    func startAnimating() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        lastInteraction = time
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // .common keeps the pet animating while its popup menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        cancelGesture()
        timer?.invalidate()
        timer = nil
    }

    func setMood(_ newMood: BallMood) {
        mood = newMood
        moodStart = time
        lastInteraction = time
        needsDisplay = true
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        time += dt
        if headphoneStart > 0 {
            let duration = wearingHeadphones ? 0.16 : 0.12
            let progress = CGFloat(min(1, (now - headphoneStart) / duration))
            headphoneOpacity = headphoneInitialOpacity + ((wearingHeadphones ? 1 : 0) - headphoneInitialOpacity) * progress
            if progress >= 1 { headphoneStart = 0 }
        }

        isHovered = pointerOverBall()
        if isHovered || isPressed { lastInteraction = time }

        let ease = CGFloat(1 - exp(-dt * 14))
        hover += ((isHovered ? 1 : 0) - hover) * ease
        press += ((isPressed && !didDrag ? 1 : 0) - press) * ease
        lift += ((didDrag ? 1 : 0) - lift) * ease
        let gaze = gazeTarget()
        pupil.x += (gaze.x - pupil.x) * ease
        pupil.y += (gaze.y - pupil.y) * ease

        // Transient moods fall back to idle on their own.
        if mood == .happy && time - moodStart > happyDuration { mood = .idle }
        if mood == .sad && time - moodStart > sadDuration { mood = .idle }

        if time >= nextBlink {
            blinkStart = time
            nextBlink = time + Double.random(in: 2.5...6)
        }
        needsDisplay = true
    }

    /// Ball center in screen coordinates.
    private var screenCenter: CGPoint? {
        guard let window else { return nil }
        return CGPoint(x: window.frame.minX + Self.ballCenter.x, y: window.frame.minY + Self.ballCenter.y)
    }

    /// Hover is computed geometrically every tick; tracking areas miss the
    /// exit event while the popup menu owns the pointer.
    private func pointerOverBall() -> Bool {
        guard let center = screenCenter else { return false }
        let mouse = NSEvent.mouseLocation
        return hypot(mouse.x - center.x, mouse.y - center.y) <= Self.ballRadius + 2
    }

    /// Eyes follow the pointer, or the spinner ring while busy.
    private func gazeTarget() -> CGPoint {
        if mood == .busy {
            return CGPoint(x: cos(spinnerAngle), y: sin(spinnerAngle))
        }
        guard let center = screenCenter else { return .zero }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return .zero }
        let reach = min(1, distance / 160)
        return CGPoint(x: dx / distance * reach, y: dy / distance * reach)
    }

    private var spinnerAngle: CGFloat { CGFloat(-time * 2 * .pi * 0.9) }

    private var isSleeping: Bool {
        mood == .idle && !isHovered && !isPressed && time - lastInteraction > sleepAfter
    }

    private enum EyeStyle { case open, happy, sad, sleep }

    private var eyeStyle: EyeStyle {
        if mood == .sad { return .sad }
        if mood == .happy || press > 0.5 { return .happy }
        if isSleeping { return .sleep }
        return .open
    }

    /// 1 = fully open, dips to 0 in the middle of a blink.
    private var eyeOpenness: CGFloat {
        guard blinkStart >= 0, time - blinkStart < blinkDuration else { return 1 }
        return CGFloat(1 - sin((time - blinkStart) / blinkDuration * .pi))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        cancelGesture()
        didDrag = false
        isPressed = true
        lastInteraction = time
        mouseDownScreenPoint = screenPoint(for: event)
        lastPointerScreenPoint = mouseDownScreenPoint
        windowOriginAtDown = window?.frame.origin ?? .zero
        reduceGestureMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        gesture.begin(at: mouseDownScreenPoint, time: CACurrentMediaTime())
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advanceGesture(at: self.lastPointerScreenPoint)
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard gesture.phase != .idle else { return }
        let now = screenPoint(for: event)
        lastPointerScreenPoint = now
        advanceGesture(at: now)
        if gesture.phase == .selecting {
            onSelectionMove?(now)
            return
        }
        let dx = now.x - mouseDownScreenPoint.x
        let dy = now.y - mouseDownScreenPoint.y
        didDrag = gesture.phase == .dragging
        guard didDrag, let window else { return }
        let newOrigin = NSPoint(x: windowOriginAtDown.x + dx, y: windowOriginAtDown.y + dy)
        window.setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        guard gesture.phase != .idle else { return }
        advanceGesture(at: screenPoint(for: event))
        let phase = gesture.phase
        if phase == .selecting { onSelectionMove?(screenPoint(for: event)) }
        cancelGesture()
        if phase == .dragging {
            onDragEnd?()
        } else if phase == .selecting {
            onSelectionEnd?()
        } else if phase == .pressing {
            onClick?()
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func advanceGesture(at point: CGPoint) {
        let previous = gesture.phase
        let now = CACurrentMediaTime()
        gesture.update(at: point, time: now)
        if gesture.phase == .pressing {
            let elapsed = now - gesture.beganAt
            chargeProgress = reduceGestureMotion ? 0
                : CGFloat(max(0, (elapsed - BallGesture.chargeDelay) / (BallGesture.holdDuration - BallGesture.chargeDelay)))
        } else {
            holdTimer?.invalidate()
            holdTimer = nil
            chargeProgress = 0
        }
        if previous != .selecting && gesture.phase == .selecting {
            onSelectionBegin?(mouseDownScreenPoint, reduceGestureMotion)
        }
        needsDisplay = true
    }

    func cancelGesture() {
        holdTimer?.invalidate()
        holdTimer = nil
        gesture.cancel()
        isPressed = false
        didDrag = false
        chargeProgress = 0
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Self.ballRadius
        let palette = skin.palette
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Overall scale: hover grows, a click press squishes, dragging lifts.
        var scale = 1 + 0.06 * hover - 0.08 * press + 0.04 * lift
        var offset = CGPoint.zero
        if !still {
            let sleeping = isSleeping
            let period = sleeping ? 4.5 : 3.2
            scale += CGFloat(sin(time * 2 * .pi / period)) * (sleeping ? 0.025 : 0.012)
            let t = time - moodStart
            if mood == .happy && t < 0.7 {
                offset.y = CGFloat(abs(sin(t / 0.35 * .pi))) * 3
            } else if mood == .sad && t < 0.5 {
                offset.x = CGFloat(sin(t * 50) * (1 - t / 0.5)) * 2.5
            }
        }

        ctx.saveGState()
        ctx.translateBy(x: Self.ballCenter.x + offset.x, y: Self.ballCenter.y + offset.y)
        ctx.scaleBy(x: scale, y: scale)
        // From here on the ball is drawn around the origin with radius `r`.

        // Silhouette (ears + head + markings) shares one soft shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2 - 3 * lift), blur: 5 + 5 * lift,
                      color: rgb(0, 0, 0, 0.28 + 0.1 * lift))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawBody(ctx, r: r, palette: palette)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        drawFace(ctx, r: r)
        drawHighlight(ctx, r: r)
        if headphoneOpacity > 0 { drawHeadphones(ctx, r: r) }
        if chargeProgress > 0 {
            strokeArc(ctx, center: .zero, radius: r + 9, from: .pi / 2,
                      to: .pi / 2 + 2 * .pi * min(1, chargeProgress),
                      color: NSColor.controlAccentColor.cgColor, width: 1.2)
        }
        if mood == .busy { drawSpinner(ctx, r: r, color: palette.accent) }
        if isSleeping && skin != .classic { drawSleepZ(ctx, r: r, color: palette.accent) }
        ctx.restoreGState()
    }

    private func drawBody(_ ctx: CGContext, r: CGFloat, palette: SkinPalette) {
        switch skin {
        case .classic:
            fillHead(ctx, r: r, palette: palette, diagonal: true)
            ctx.setStrokeColor(rgb(1, 1, 1, 0.25))
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: -r + 0.5, y: -r + 0.5, width: 2 * r - 1, height: 2 * r - 1))
        case .cat:
            for side in [-1, 1] as [CGFloat] {
                drawEar(ctx, angle: side * 38, r: r, tip: 1.36, spread: 24, color: palette.bottom)
                drawEar(ctx, angle: side * 38, r: r, tip: 1.2, spread: 12, color: rgb(1.0, 0.72, 0.75))
            }
            fillHead(ctx, r: r, palette: palette, diagonal: false)
            clipped(toHead: ctx, r: r) {
                // Forehead stripes and a cream muzzle.
                for (x, top) in [(-0.2, 0.86), (0.0, 0.98), (0.2, 0.86)] as [(CGFloat, CGFloat)] {
                    strokeLine(ctx, from: CGPoint(x: x * r, y: top * r), to: CGPoint(x: x * r, y: 0.62 * r),
                               color: rgb(0.86, 0.45, 0.15), width: 0.1 * r)
                }
                fillEllipse(ctx, center: CGPoint(x: 0, y: -0.32 * r), size: CGSize(width: 0.95 * r, height: 0.6 * r),
                            color: rgb(1.0, 0.93, 0.82))
            }
        case .shiba:
            for side in [-1, 1] as [CGFloat] {
                drawEar(ctx, angle: side * 40, r: r, tip: 1.32, spread: 22, color: palette.bottom)
                drawEar(ctx, angle: side * 40, r: r, tip: 1.18, spread: 11, color: rgb(1.0, 0.9, 0.78))
            }
            fillHead(ctx, r: r, palette: palette, diagonal: false)
            clipped(toHead: ctx, r: r) {
                // White muzzle and the shiba's dotted "eyebrows".
                fillEllipse(ctx, center: CGPoint(x: 0, y: -0.45 * r), size: CGSize(width: 1.55 * r, height: 1.0 * r),
                            color: rgb(1.0, 0.97, 0.92))
                for side in [-1, 1] as [CGFloat] {
                    fillEllipse(ctx, center: CGPoint(x: side * 0.3 * r, y: 0.38 * r), size: CGSize(width: 0.17 * r, height: 0.1 * r),
                                color: rgb(1.0, 0.95, 0.86))
                }
            }
        case .panda:
            for side in [-1, 1] as [CGFloat] {
                fillEllipse(ctx, center: polar(side * 42, 0.88 * r), size: CGSize(width: 0.68 * r, height: 0.68 * r),
                            color: rgb(0.15, 0.15, 0.17))
            }
            fillHead(ctx, r: r, palette: palette, diagonal: false)
            for side in [-1, 1] as [CGFloat] {
                // Eye patches droop outward: inner-top to outer-bottom.
                fillEllipse(ctx, center: CGPoint(x: side * 0.36 * r, y: 0), size: CGSize(width: 0.36 * r, height: 0.5 * r),
                            color: rgb(0.15, 0.15, 0.17), rotation: side * 0.45)
            }
        case .chick:
            // Three-feather tuft on top.
            for angle in [-16, 0, 16] as [CGFloat] {
                fillEllipse(ctx, center: polar(angle, 1.04 * r), size: CGSize(width: 0.16 * r, height: 0.38 * r),
                            color: rgb(0.98, 0.72, 0.16), rotation: -angle * .pi / 180)
            }
            fillHead(ctx, r: r, palette: palette, diagonal: false)
        }
    }

    private func drawFace(_ ctx: CGContext, r: CGFloat) {
        let dark = rgb(0.2, 0.14, 0.11)
        switch skin {
        case .classic:
            let font = NSFont.systemFont(ofSize: r * 0.84, weight: .semibold)
            let text = NSAttributedString(string: "译", attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
        case .cat:
            drawBlush(ctx, r: r, y: -0.2, spacing: 0.6)
            drawEyes(ctx, r: r, y: 0.06, spacing: 0.36, color: dark)
            let nose = CGMutablePath()
            nose.move(to: CGPoint(x: -0.07 * r, y: -0.1 * r))
            nose.addLine(to: CGPoint(x: 0.07 * r, y: -0.1 * r))
            nose.addLine(to: CGPoint(x: 0, y: -0.17 * r))
            nose.closeSubpath()
            fillRounded(ctx, path: nose, color: rgb(0.95, 0.5, 0.55), lineWidth: 0.04 * r)
            drawMouth(ctx, r: r, y: -0.2, color: dark)
            let whisker = rgb(0.55, 0.32, 0.18, 0.55)
            for side in [-1, 1] as [CGFloat] {
                strokeLine(ctx, from: CGPoint(x: side * 0.5 * r, y: -0.16 * r), to: CGPoint(x: side * 0.95 * r, y: -0.1 * r),
                           color: whisker, width: 0.035 * r)
                strokeLine(ctx, from: CGPoint(x: side * 0.5 * r, y: -0.25 * r), to: CGPoint(x: side * 0.92 * r, y: -0.32 * r),
                           color: whisker, width: 0.035 * r)
            }
        case .shiba:
            drawBlush(ctx, r: r, y: -0.2, spacing: 0.55)
            drawEyes(ctx, r: r, y: 0.08, spacing: 0.34, color: dark)
            fillEllipse(ctx, center: CGPoint(x: 0, y: -0.15 * r), size: CGSize(width: 0.18 * r, height: 0.12 * r), color: dark)
            drawMouth(ctx, r: r, y: -0.24, color: dark)
        case .panda:
            drawBlush(ctx, r: r, y: -0.34, spacing: 0.62)
            drawEyes(ctx, r: r, y: 0.02, spacing: 0.36, color: rgb(1, 1, 1), pupilColor: dark)
            fillEllipse(ctx, center: CGPoint(x: 0, y: -0.26 * r), size: CGSize(width: 0.15 * r, height: 0.1 * r), color: dark)
            drawMouth(ctx, r: r, y: -0.33, color: dark)
        case .chick:
            drawBlush(ctx, r: r, y: -0.18, spacing: 0.56)
            drawEyes(ctx, r: r, y: 0.1, spacing: 0.34, color: dark)
            // Diamond beak; it opens a little when happy.
            let gap: CGFloat = eyeStyle == .happy ? 0.07 * r : 0
            let upper = CGMutablePath()
            upper.move(to: CGPoint(x: -0.14 * r, y: -0.13 * r))
            upper.addLine(to: CGPoint(x: 0, y: -0.02 * r))
            upper.addLine(to: CGPoint(x: 0.14 * r, y: -0.13 * r))
            upper.closeSubpath()
            let lower = CGMutablePath()
            lower.move(to: CGPoint(x: -0.12 * r, y: -0.13 * r - gap))
            lower.addLine(to: CGPoint(x: 0.12 * r, y: -0.13 * r - gap))
            lower.addLine(to: CGPoint(x: 0, y: -0.24 * r - gap))
            lower.closeSubpath()
            fillRounded(ctx, path: lower, color: rgb(0.93, 0.48, 0.1), lineWidth: 0.04 * r)
            fillRounded(ctx, path: upper, color: rgb(1.0, 0.6, 0.15), lineWidth: 0.04 * r)
        }
    }

    /// Both eyes, centered at `y` and `±spacing` (fractions of `r`). A
    /// `pupilColor` draws light eyes with a moving pupil (panda patches).
    private func drawEyes(_ ctx: CGContext, r: CGFloat, y: CGFloat, spacing: CGFloat,
                          color: CGColor, pupilColor: CGColor? = nil) {
        let w = 0.15 * r
        let h = 0.19 * r
        let cy = y * r
        let look = CGPoint(x: pupil.x * 0.08 * r, y: pupil.y * 0.06 * r)
        let line = 0.065 * r
        for side in [-1, 1] as [CGFloat] {
            let cx = side * spacing * r
            switch eyeStyle {
            case .open:
                let open = eyeOpenness
                if open < 0.3 {
                    strokeLine(ctx, from: CGPoint(x: cx - w * 0.6, y: cy), to: CGPoint(x: cx + w * 0.6, y: cy), color: color, width: line)
                } else if let pupilColor {
                    fillEllipse(ctx, center: CGPoint(x: cx, y: cy), size: CGSize(width: w, height: h * open), color: color)
                    fillEllipse(ctx, center: CGPoint(x: cx + look.x * 0.6, y: cy + look.y * 0.6),
                                size: CGSize(width: w * 0.62, height: w * 0.62 * open), color: pupilColor)
                } else {
                    let eye = CGPoint(x: cx + look.x, y: cy + look.y)
                    fillEllipse(ctx, center: eye, size: CGSize(width: w, height: h * open), color: color)
                    fillEllipse(ctx, center: CGPoint(x: eye.x + w * 0.22, y: eye.y + h * open * 0.22),
                                size: CGSize(width: w * 0.36, height: w * 0.36), color: rgb(1, 1, 1, 0.95))
                }
            case .happy:
                // "^" arc.
                strokeArc(ctx, center: CGPoint(x: cx, y: cy - h * 0.25), radius: w * 0.62,
                          from: 0.15 * .pi, to: 0.85 * .pi, color: color, width: line)
            case .sleep:
                // Closed, relaxed lower arc.
                strokeArc(ctx, center: CGPoint(x: cx, y: cy + h * 0.25), radius: w * 0.62,
                          from: 1.15 * .pi, to: 1.85 * .pi, color: color, width: line)
            case .sad:
                // ">" on the left eye, "<" on the right: squeezed shut.
                let path = CGMutablePath()
                path.move(to: CGPoint(x: cx + side * w * 0.55, y: cy + h * 0.4))
                path.addLine(to: CGPoint(x: cx - side * w * 0.45, y: cy))
                path.addLine(to: CGPoint(x: cx + side * w * 0.55, y: cy - h * 0.4))
                stroke(ctx, path: path, color: color, width: line)
            }
        }
    }

    /// "ω" mouth at `y` (fraction of `r`); open when happy, a frown when sad.
    private func drawMouth(_ ctx: CGContext, r: CGFloat, y: CGFloat, color: CGColor) {
        let cy = y * r
        let line = 0.045 * r
        switch eyeStyle {
        case .happy:
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: 0, y: cy), radius: 0.11 * r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(rgb(0.85, 0.32, 0.38))
            ctx.fillPath()
        case .sad:
            strokeArc(ctx, center: CGPoint(x: 0, y: cy - 0.12 * r), radius: 0.09 * r,
                      from: 0.2 * .pi, to: 0.8 * .pi, color: color, width: line)
        case .open, .sleep:
            for side in [-1, 1] as [CGFloat] {
                strokeArc(ctx, center: CGPoint(x: side * 0.065 * r, y: cy), radius: 0.065 * r,
                          from: .pi, to: 2 * .pi, color: color, width: line)
            }
        }
    }

    private func drawBlush(_ ctx: CGContext, r: CGFloat, y: CGFloat, spacing: CGFloat) {
        let alpha: CGFloat = eyeStyle == .happy ? 0.55 : 0.32
        for side in [-1, 1] as [CGFloat] {
            fillEllipse(ctx, center: CGPoint(x: side * spacing * r, y: y * r), size: CGSize(width: 0.22 * r, height: 0.13 * r),
                        color: rgb(1.0, 0.42, 0.5, alpha))
        }
    }

    /// Soft glossy spot on the upper left.
    private func drawHighlight(_ ctx: CGContext, r: CGFloat) {
        let colors = [rgb(1, 1, 1, skin == .classic ? 0.38 : 0.3), rgb(1, 1, 1, 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        let spot = CGPoint(x: -0.36 * r, y: 0.5 * r)
        clipped(toHead: ctx, r: r) {
            ctx.drawRadialGradient(gradient, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: 0.5 * r, options: [])
        }
    }

    private func drawSpinner(_ ctx: CGContext, r: CGFloat, color: CGColor) {
        let radius = r + 3.5
        ctx.saveGState()
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.copy(alpha: 0.18) ?? color)
        ctx.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
        ctx.addArc(center: .zero, radius: radius, startAngle: spinnerAngle, endAngle: spinnerAngle + 0.6 * .pi, clockwise: false)
        ctx.setStrokeColor(color)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Overlay only: all five original silhouettes and faces stay intact.
    private func drawHeadphones(_ ctx: CGContext, r: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(headphoneOpacity)
        if wearingHeadphones && headphoneStart > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let progress = CGFloat(min(1, (CACurrentMediaTime() - headphoneStart) / 0.16))
            let scale = 0.6 + progress * 0.4
            ctx.scaleBy(x: scale, y: scale)
        }
        let color = rgb(46 / 255, 51 / 255, 64 / 255)
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 1.04 * r,
                   startAngle: -5 * .pi / 180, endAngle: 185 * .pi / 180, clockwise: false)
        // Preserve the chick's original three-feather tuft above the headband.
        if skin == .chick {
            ctx.saveGState()
            let clip = CGMutablePath()
            clip.addRect(CGRect(x: -36, y: -36, width: 72, height: 72))
            for angle in [-16, 0, 16] as [CGFloat] {
                var transform = CGAffineTransform(translationX: polar(angle, 1.04 * r).x,
                                                  y: polar(angle, 1.04 * r).y)
                    .rotated(by: -angle * .pi / 180)
                let feather = CGPath(ellipseIn: CGRect(x: -0.08 * r, y: -0.19 * r,
                                                       width: 0.16 * r, height: 0.38 * r), transform: &transform)
                clip.addPath(feather)
            }
            ctx.addPath(clip)
            ctx.clip(using: .evenOdd)
            stroke(ctx, path: arc, color: rgb(1, 1, 1, 0.6), width: 0.12 * r + 2)
            stroke(ctx, path: arc, color: color, width: 0.12 * r)
            ctx.restoreGState()
        } else {
            stroke(ctx, path: arc, color: rgb(1, 1, 1, 0.6), width: 0.12 * r + 2)
            stroke(ctx, path: arc, color: color, width: 0.12 * r)
        }
        for side in [-1, 1] as [CGFloat] {
            let rect = CGRect(x: side * 1.04 * r - 0.18 * r, y: -0.09 * r - 0.32 * r,
                              width: 0.36 * r, height: 0.64 * r)
            let path = CGPath(roundedRect: rect, cornerWidth: 0.12 * r, cornerHeight: 0.12 * r, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.setStrokeColor(rgb(1, 1, 1, 0.6))
            ctx.setLineWidth(1)
            ctx.drawPath(using: .fillStroke)
        }
        ctx.restoreGState()
    }

    /// Two "z" letters drifting up from the top right while the pet dozes.
    private func drawSleepZ(_ ctx: CGContext, r: CGFloat, color: CGColor) {
        let nsColor = NSColor(cgColor: color) ?? .secondaryLabelColor
        for (index, size) in [0.34, 0.26].enumerated() {
            let phase = (time / 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let alpha = CGFloat(sin(phase * .pi))
            let font = NSFont.systemFont(ofSize: CGFloat(size) * r, weight: .bold)
            let text = NSAttributedString(string: "z", attributes: [.font: font, .foregroundColor: nsColor.withAlphaComponent(alpha)])
            let x = (0.62 + CGFloat(phase) * 0.28) * r
            let y = (0.55 + CGFloat(phase) * 0.4) * r
            text.draw(at: NSPoint(x: x, y: y))
        }
    }

    // MARK: - Drawing primitives (all in ball-local coordinates)

    /// Point at `distance` from the center; `angle` is in degrees from straight
    /// up, positive to the right.
    private func polar(_ angle: CGFloat, _ distance: CGFloat) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: distance * sin(radians), y: distance * cos(radians))
    }

    private func fillHead(_ ctx: CGContext, r: CGFloat, palette: SkinPalette, diagonal: Bool) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [palette.top, palette.bottom] as CFArray, locations: [0, 1]) else { return }
        clipped(toHead: ctx, r: r) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: diagonal ? -r : 0, y: r),
                                   end: CGPoint(x: diagonal ? r : 0, y: -r),
                                   options: [])
        }
    }

    private func clipped(toHead ctx: CGContext, r: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    /// Rounded triangular ear pointing along `angle`; its base hides behind the head.
    private func drawEar(_ ctx: CGContext, angle: CGFloat, r: CGFloat, tip: CGFloat, spread: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        path.move(to: polar(angle - spread, 0.78 * r))
        path.addLine(to: polar(angle, tip * r))
        path.addLine(to: polar(angle + spread, 0.78 * r))
        path.closeSubpath()
        fillRounded(ctx, path: path, color: color, lineWidth: 0.12 * r)
    }

    /// Fills `path` and strokes it in the same color so corners come out round.
    private func fillRounded(_ ctx: CGContext, path: CGPath, color: CGColor, lineWidth: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func fillEllipse(_ ctx: CGContext, center: CGPoint, size: CGSize, color: CGColor, rotation: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    private func stroke(_ ctx: CGContext, path: CGPath, color: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func strokeLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        stroke(ctx, path: path, color: color, width: width)
    }

    /// Counter-clockwise arc from `from` to `to` (radians).
    private func strokeArc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat,
                           color: CGColor, width: CGFloat) {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
        stroke(ctx, path: path, color: color, width: width)
    }
}
