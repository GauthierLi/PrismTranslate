import AppKit

/// Owns one frozen selection session and one panel per physical display.
/// Selection is global AppKit geometry; each screen retains its own density.
@MainActor
final class CaptureSelectionController {
    private(set) var panels: [NSPanel] = []
    private var views: [CaptureSelectionView] = []
    private var frames: [CapturedScreen] = []
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var start: CGPoint?
    private var pointer = CGPoint.zero
    private var petWasVisible = false
    private var petNeedsRecovery = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var cancelled = false
    private var samplingTask: Task<[CapturedScreen], Error>?
    private var previousApplication: NSRunningApplication?

    func capture(skin: BallSkin) async throws -> CGImage {
        cancelled = false
        installCancellation()
        defer { cleanUp() }
        let task = Task { @MainActor in try await ScreenFrameCapture.capture() }
        samplingTask = task
        let screens = try await task.value
        samplingTask = nil
        guard !cancelled else { throw OCRService.OCRError.cancelled }
        return try await select(screens: screens, skin: skin)
    }

    /// Explicit frozen-frame input also allows native tests to exercise the
    /// exact selection/output boundary without reading unrelated app windows.
    func select(screens: [CapturedScreen], skin: BallSkin) async throws -> CGImage {
        guard !screens.isEmpty, continuation == nil, panels.isEmpty else {
            throw OCRService.OCRError.captureFailed
        }
        if monitor == nil { cancelled = false; installCancellation() }
        defer { cleanUp() }
        frames = screens
        start = nil
        pointer = NSEvent.mouseLocation
        petWasVisible = false
        petNeedsRecovery = false
        previousApplication = NSWorkspace.shared.frontmostApplication
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                for screen in screens {
                    let panel = CaptureSelectionPanel(contentRect: screen.frame, styleMask: [.borderless],
                                                      backing: .buffered, defer: false)
                    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
                    panel.isOpaque = true
                    panel.hasShadow = false
                    panel.backgroundColor = .black
                    panel.hidesOnDeactivate = false
                    panel.isReleasedWhenClosed = false
                    panel.acceptsMouseMovedEvents = true
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                    let view = CaptureSelectionView(screen: screen, skin: skin)
                    view.onPointer = { [weak self] phase, point in self?.handle(phase, at: point) }
                    view.onCancel = { [weak self] in self?.cancel() }
                    panel.contentView = view
                    panel.setFrame(screen.frame, display: false)
                    panels.append(panel)
                    views.append(view)
                    panel.orderFrontRegardless()
                }
                let active = panels.first(where: { $0.frame.contains(pointer) }) ?? panels[0]
                NSApp.activate(ignoringOtherApps: true)
                active.makeKey()
                active.makeFirstResponder(active.contentView)
                refresh()
            }
        }, onCancel: {
            Task { @MainActor in self.cancel() }
        })
    }

    func cancel() {
        cancelled = true
        samplingTask?.cancel()
        finish(.failure(OCRService.OCRError.cancelled))
    }

    private func installCancellation() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancel() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.cancel() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.continuation != nil else { return }
                self?.cancel()
            }
        })
    }

    private func handle(_ phase: CaptureSelectionView.PointerPhase, at point: CGPoint) {
        guard continuation != nil else { return }
        // Hover events can arrive after activation/cursor changes. Only a
        // held-button drag may change an in-progress rectangle.
        if case .hover = phase, start != nil { return }
        pointer = point
        switch phase {
        case .down:
            start = point
            petWasVisible = false
            petNeedsRecovery = false
            refresh()
        case .move:
            refresh()
        case .hover:
            refresh()
        case .up:
            guard let start else { return }
            let selection = CaptureGeometry.selection(from: start, to: point)
            guard !selection.isEmpty else { self.start = nil; refresh(); return }
            guard let plan = CaptureGeometry.plan(selection: selection, surfaces: frames.map(\.surface)) else {
                // A display gap has no pixels. Keep the session available for
                // another drag and communicate why this region cannot submit.
                self.start = nil
                views.forEach { $0.hint = "选区跨过了屏幕间空隙，请重新框选 · Esc 取消" }
                refresh()
                return
            }
            do { finish(.success(try Self.crop(frames: frames, plan: plan))) }
            catch { finish(.failure(error)) }
        }
    }

    private func refresh() {
        let selection = start.map { CaptureGeometry.selection(from: $0, to: pointer) }
        let topLeft = selection.map { CGPoint(x: $0.minX, y: $0.maxY) }
        let petScreen = topLeft.flatMap { point in frames.firstIndex(where: { $0.frame.contains(point) }) }
        let pointerScreen = frames.firstIndex(where: { $0.frame.contains(pointer) })
        let plan = selection.flatMap { CaptureGeometry.plan(selection: $0, surfaces: frames.map(\.surface)) }
        let label = plan.map { "\($0.width) × \($0.height) px" } ?? "重新框选"
        let labelSize = CaptureSelectionView.readoutSize(label)
        var showsPet = false
        var labelRect = CGRect.zero
        if let selection, let pointerScreen {
            let screen = frames[pointerScreen].frame
            // A role lives on exactly one display; it never bridges two panels.
            let layout = CaptureDecorationLayout.layout(
                selection: selection, pointer: pointer, screen: screen, readoutSize: labelSize,
                hasPet: views[pointerScreen].hasPet && petScreen == pointerScreen,
                wasVisible: petWasVisible, recovering: petNeedsRecovery)
            showsPet = layout.showsPet
            labelRect = layout.readout
            if let petScreen, petScreen != pointerScreen {
                // The readout is on a different display and cannot collide.
                // Still require the complete pet envelope on its own display.
                showsPet = CaptureDecorationLayout.canShowPet(
                    selection: selection, screen: frames[petScreen].frame, hasPet: views[petScreen].hasPet,
                    wasVisible: petWasVisible, recovering: petNeedsRecovery)
            }
            if !showsPet && !selection.isEmpty { petNeedsRecovery = true }
            if showsPet { petNeedsRecovery = false }
        }
        petWasVisible = showsPet
        for (index, view) in views.enumerated() {
            view.selection = selection
            view.pointer = pointer
            view.showsPet = showsPet && index == petScreen
            view.readout = index == pointerScreen && selection != nil ? labelRect : nil
            view.readoutText = label
            view.setAccessibilityValue(selection == nil ? "尚未选择区域" : label)
            view.needsDisplay = true
        }
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        // orderOut before OCR begins. The image only comes from frozen pixels.
        cleanUp()
        continuation.resume(with: result)
    }

    private func cleanUp() {
        samplingTask?.cancel()
        samplingTask = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        frames.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }

    static func crop(frames: [CapturedScreen], plan: CaptureGeometry.Plan) throws -> CGImage {
        if plan.crops.count == 1, let crop = plan.crops.first,
           let image = frames[crop.surfaceIndex].image.cropping(to: crop.source) {
            return image
        }
        guard let context = CGContext(data: nil, width: plan.width, height: plan.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OCRService.OCRError.noImage
        }
        context.interpolationQuality = .high
        for crop in plan.crops {
            guard let image = frames[crop.surfaceIndex].image.cropping(to: crop.source) else {
                throw OCRService.OCRError.noImage
            }
            let destination = CGRect(x: crop.destination.minX,
                                     y: CGFloat(plan.height) - crop.destination.maxY,
                                     width: crop.destination.width, height: crop.destination.height)
            context.draw(image, in: destination)
        }
        guard let image = context.makeImage() else { throw OCRService.OCRError.noImage }
        return image
    }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptureSelectionView: NSView {
    enum PointerPhase { case down, move, hover, up }
    let screen: CapturedScreen
    let hasPet: Bool
    private var pet: CapturePet?
    var onPointer: ((PointerPhase, CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var selection: CGRect?
    var pointer = CGPoint.zero
    var showsPet = false
    var readout: CGRect?
    var readoutText = ""
    var hint = "拖动框选，松手识别 · Esc 取消"
    private var tracking: NSTrackingArea?

    init(screen: CapturedScreen, skin: BallSkin) {
        self.screen = screen
        hasPet = skin != .classic
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        if hasPet { pet = CapturePet(skin: skin) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("截图选区")
        setAccessibilityHelp("拖动框选，松手识别。按 Escape 取消。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseDown(with event: NSEvent) { emit(.down, event) }
    override func mouseDragged(with event: NSEvent) { emit(.move, event) }
    override func mouseMoved(with event: NSEvent) { emit(.hover, event) }
    override func mouseUp(with event: NSEvent) { emit(.up, event) }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    private func emit(_ phase: PointerPhase, _ event: NSEvent) {
        guard let window else { return }
        onPointer?(phase, window.convertPoint(toScreen: event.locationInWindow))
    }

    static func readoutSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        return CGSize(width: ceil(size.width) + 20, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(screen.image, in: bounds)
        let localSelection = selection?.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        context.saveGState()
        context.addRect(bounds)
        if let localSelection { context.addRect(localSelection) }
        context.setFillColor(CGColor(srgbRed: 0.078, green: 0.094, blue: 0.149, alpha: 0.38))
        context.drawPath(using: .eoFill)
        context.restoreGState()
        if let localSelection, !localSelection.isEmpty {
            let corner = CGPoint(x: localSelection.minX, y: localSelection.maxY)
            if showsPet { pet?.drawBack(in: context, at: corner) }
            context.setLineJoin(.miter)
            context.setStrokeColor(CGColor(srgbRed: 0.04, green: 0.06, blue: 0.1, alpha: 0.9))
            context.setLineWidth(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 4 : 3)
            context.stroke(localSelection)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(localSelection)
            if showsPet { pet?.drawFront(in: context, at: corner) }
        }
        if let readout {
            drawLabel(readoutText, rect: readout.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), mono: true)
        }
        let localPointer = CGPoint(x: pointer.x - screen.frame.minX, y: pointer.y - screen.frame.minY)
        if bounds.contains(localPointer) {
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: localPointer.x - 8, y: localPointer.y))
            cross.addLine(to: CGPoint(x: localPointer.x + 8, y: localPointer.y))
            cross.move(to: CGPoint(x: localPointer.x, y: localPointer.y - 8))
            cross.addLine(to: CGPoint(x: localPointer.x, y: localPointer.y + 8))
            context.addPath(cross); context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(3); context.strokePath()
            context.addPath(cross); context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1); context.strokePath()
        }
        // Classic selection has exactly the border/crosshair/readout.
        if hasPet {
            let size = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            let rect = CGRect(x: (bounds.width - size.width - 24) / 2, y: 28,
                              width: size.width + 24, height: 28)
            if readout == nil || !rect.intersects(readout!.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)) {
                drawLabel(hint, rect: rect, mono: false)
            }
        }
    }

    private func drawLabel(_ text: String, rect: CGRect, mono: Bool) {
        NSColor(srgbRed: 0.07, green: 0.09, blue: 0.13, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                        : NSFont.systemFont(ofSize: 12)
        (text as NSString).draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 6),
                                withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
}
