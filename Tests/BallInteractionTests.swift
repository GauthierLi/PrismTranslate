import AppKit
import ApplicationServices
import SwiftUI

/// AppKit runs in an isolated test bundle. OCR and HTTP use explicit fixtures;
/// system capture permissions and pointer/keyboard access are never requested.
private final class FixtureProtocol: URLProtocol {
    static var requestCount = 0
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.fail ? 500 : 200,
                                       httpVersion: nil, headerFields: nil)!
        let body = Self.fail ? #"{"error":"fixture failure"}"#
            : #"{"choices":[{"message":{"content":"你好，世界！"}}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct BallInteractionTests {
    @MainActor static func main() {
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--foreground-peer" {
            BallInactiveApplicationTests.runForegroundPeer(statusURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("Ball interaction tests passed")
                exit(0)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    @MainActor static func pause(_ seconds: Double = 0.23) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor static func member<T>(_ instance: Any, _ name: String) -> T {
        Mirror(reflecting: instance).children.first { $0.label == name }!.value as! T
    }

    @MainActor static func run() async throws {
        try geometryAndGestures()
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let outputURL = URL(fileURLWithPath: output)
        print("Permissions: accessibility=\(AXIsProcessTrusted()), screenCapture=\(CGPreflightScreenCaptureAccess())")
        print("System Reduce Transparency: \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        print("Evidence: WindowServer captures of test-owned panels, offscreen skin atlas and application events; OCR/HTTP fixtures.")
        URLProtocol.registerClass(FixtureProtocol.self)

        var captureCount = 0
        var capturedText = "Hello, world!"
        var captureError: OCRService.OCRError?
        var captureDelay = 0.15
        var capturedWhileRingVisible = false
        var controller: FloatingBallController?
        let delegate = AppDelegate(captureOCR: { _ in
            captureCount += 1
            if let controller {
                let ring: BallSelectionController = member(controller, "selection")
                capturedWhileRingVisible = capturedWhileRingVisible || ring.isVisible
            }
            await pause(captureDelay)
            if let captureError { throw captureError }
            return capturedText
        })
        // Standard defaults are isolated by the test bundle's identifier.
        delegate.settings.autoWatchClipboard = false
        delegate.settings.appMode = .ocr
        delegate.settings.provider = .openai
        delegate.settings.showFloatingBall = true
        delegate.settings.ballSkin = .cat
        delegate.settings.apiKey = "fixture"
        delegate.settings.baseURL = "https://fixture.invalid/v1"
        delegate.settings.model = "fixture"
        delegate.settings.targetLanguage = "zh-Hans"
        delegate.settings.showOriginal = true
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        controller = member(delegate, "floatingBall")
        let ball = controller!
        let window: NSPanel = member(ball, "window")
        let view: BallView = member(ball, "ballView")
        let ring: BallSelectionController = member(ball, "selection")
        let overlay: OverlayController = member(delegate, "overlay")
        let overlayModel: OverlayModel = member(overlay, "model")
        let initialStatus: NSStatusItem = member(delegate, "statusItem")
        try check(!initialStatus.menu!.items.contains { $0.title == "隐藏字幕" }, "Menu bar removes hide-subtitle action")
        try check(!ball.onRequestMenu!().items.contains { $0.title == "隐藏字幕" }, "Ball menu removes hide-subtitle action")
        defer {
            overlay.hide()
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }

        var expectedCaptures = captureCount
        var expectedWatching = false
        try await BallInactiveApplicationTests.run(ball: ball, output: outputURL) { action in
            switch action {
            case .ocr:
                expectedCaptures += 1
                try check(captureCount == expectedCaptures && !capturedWhileRingVisible,
                          "Inactive OCR executes exactly once after ring hides")
                try check(overlayModel.translated == "Hello, world!" && overlayModel.original == nil,
                          "Inactive OCR shows recognized original")
            case .ocrTranslate:
                expectedCaptures += 1
                try check(captureCount == expectedCaptures && !capturedWhileRingVisible,
                          "Inactive OCR translation executes exactly once after ring hides")
                try check(overlayModel.translated == "你好，世界！" && overlayModel.original == "Hello, world!",
                          "Inactive OCR translation shows the translated fixture")
            case .clipboardWatch:
                expectedWatching.toggle()
                let enabled = delegate.settings.autoWatchClipboard
                let timer: Timer? = member(delegate, "clipTimer")
                try check(enabled == expectedWatching && (timer != nil) == enabled && ball.watchingClipboard == enabled
                          && view.wearingHeadphones == enabled, "Inactive toggle updates polling and headphones")
            }
            try check(!delegate.isOCRInProgress, "Inactive action releases OCR lock")
            overlay.hide()
        }
        try check(captureCount == 8 && !delegate.settings.autoWatchClipboard,
                  "All foreign-app scenarios execute OCR, OCR translation and toggle clipboard watching")
        captureCount = 0

        // Initial off/on accessory atlas: same production drawing, all skins.
        try renderSkins(to: outputURL)
        try await labelsAndGlass(ball: window, screen: NSScreen.main!, to: outputURL)
        try await floatingBubbles(ball: window, screen: NSScreen.main!, to: outputURL)

        func event(_ type: NSEvent.EventType, screen: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func center() -> CGPoint {
            CGPoint(x: window.frame.minX + BallView.ballCenter.x, y: window.frame.minY + BallView.ballCenter.y)
        }
        func down() { view.mouseDown(with: event(.leftMouseDown, screen: center())) }
        func drag(_ point: CGPoint) { view.mouseDragged(with: event(.leftMouseDragged, screen: point)) }
        func up(_ point: CGPoint) { view.mouseUp(with: event(.leftMouseUp, screen: point)) }
        func snap(_ name: String) throws {
            try captureScene(ball: window, ring: ring, to: outputURL.appendingPathComponent(name + ".png"))
        }

        // Default right-edge ring: native panel frame and all sectors visible.
        let screen = NSScreen.main!
        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - 29 - BallView.ballCenter.x,
                                      y: screen.visibleFrame.midY - BallView.ballCenter.y))
        down()
        await pause(0.45)
        try check(ring.isVisible, "Stationary 400 ms press must open ring")
        try check(abs(ring.center.x - (screen.visibleFrame.maxX - 84)) < 0.1, "Right edge must shift ring by 55 pt")
        try snap("default-right-edge")
        let ocrPoint = CGPoint(x: ring.center.x - 43, y: ring.center.y + 43)
        drag(ocrPoint)
        await pause(0.13)
        try check(ring.selected == .ocr, "Upper left selects plain OCR")
        let selectionView: BallSelectionView = member(ring, "view")
        try check(selectionView.labelAction == nil, "Quick OCR release does not need a visible label")
        try snap("01-ocr-selected")
        up(ocrPoint)
        try check(captureCount == 0, "OCR must wait until ring finishes hiding")
        await pause(0.42)
        try check(captureCount == 1 && !capturedWhileRingVisible, "Exactly one capture after orderOut")
        try check(overlayModel.translated == "Hello, world!" && overlayModel.original == nil, "Plain OCR shows only recognized original")
        try check(!delegate.isOCRInProgress, "Success clears OCR task lock")
        await pause(0.3)
        try captureWindow(member(overlay, "window"), to: outputURL.appendingPathComponent("02-ocr-original.png"))

        // OCR translation from the same upper ring.
        down(); await pause(0.45)
        let translationPoint = CGPoint(x: ring.center.x + 10, y: ring.center.y + 67)
        drag(translationPoint); await pause(0.13)
        try check(ring.selected == .ocrTranslate, "Upper right selects OCR translation")
        try snap("03-ocr-translate-selected")
        up(translationPoint); await pause(0.55)
        try check(overlayModel.translated == "你好，世界！", "OCR translation shows translated result")
        try check(overlayModel.original == "Hello, world!", "OCR translation obeys showOriginal")
        await pause(0.3)
        try captureWindow(member(overlay, "window"), to: outputURL.appendingPathComponent("04-ocr-translated.png"))

        // Lower switch: accessories, polling timer and both freshly built menus.
        for (index, enabled) in [(5, true), (7, false)] {
            down(); await pause(0.45)
            let point = CGPoint(x: ring.center.x, y: ring.center.y - 58)
            drag(point); await pause(0.13)
            try check(ring.selected == .clipboardWatch, "Lower half selects clipboard toggle")
            try check(selectionView.labelAction == nil, "Quick toggle release does not need a visible label")
            try snap(String(format: "%02d-watch-selected", index))
            up(point); await pause(0.4)
            try check(delegate.settings.autoWatchClipboard == enabled, "Clipboard switch changes saved state")
            try check(ball.watchingClipboard == enabled && view.wearingHeadphones == enabled, "Headphones follow saved state")
            let timer: Timer? = member(delegate, "clipTimer")
            try check((timer != nil) == enabled, "Clipboard polling starts/stops immediately")
            let status: NSStatusItem = member(delegate, "statusItem")
            let watch = status.menu!.items.first { $0.title == "自动监听粘贴板" }!
            try check(watch.state == (enabled ? .on : .off), "Menu bar checkbox follows switch")
            let ballMenu = ball.onRequestMenu!()
            try check(ballMenu.items.first { $0.title == "自动监听粘贴板" }!.state == watch.state, "Ball menu checkbox follows switch")
            try snap(String(format: "%02d-watch-applied", index + 1))
        }

        // Dead zone and outside cancel without OCR or switch side effects.
        let countBeforeCancel = captureCount
        down(); await pause(0.45)
        drag(ocrPoint); await pause(0.12)
        drag(center()); await pause(0.06)
        try check(ring.selected == nil, "Original press remains dead zone after edge shifting")
        try snap("09-cancel-center")
        up(center()); await pause()
        try check(!ring.isVisible && captureCount == countBeforeCancel, "Dead zone release cancels")
        try snap("09b-cancel-released")
        down(); await pause(0.45)
        let outside = CGPoint(x: ring.center.x - 110, y: ring.center.y)
        drag(outside); await pause(0.1)
        try snap("10-cancel-outside")
        up(outside); await pause()
        try check(!ring.isVisible && captureCount == countBeforeCancel, "Outside release cancels")
        try snap("10b-cancel-released")

        // Movement begins before hold threshold, stays movement after 400 ms.
        let before = window.frame.origin
        let press = center()
        let dragEvidenceFrame = window.frame.union(window.frame.offsetBy(dx: -60, dy: 8)).insetBy(dx: -18, dy: -18)
        try captureScene(ball: window, ring: ring, to: outputURL.appendingPathComponent("11a-before-drag.png"),
                         fixedFrame: dragEvidenceFrame)
        down(); await pause(0.06)
        drag(CGPoint(x: press.x - 60, y: press.y + 8))
        await pause(0.5)
        try check(!ring.isVisible && window.frame.origin != before, "Dragging never opens long-press ring")
        try captureScene(ball: window, ring: ring, to: outputURL.appendingPathComponent("11-drag-held.png"),
                         fixedFrame: dragEvidenceFrame)
        up(CGPoint(x: press.x - 60, y: press.y + 8)); await pause(0.3)
        try captureScene(ball: window, ring: ring, to: outputURL.appendingPathComponent("12-drag-released.png"),
                         fixedFrame: dragEvidenceFrame)

        // OCR task lock blocks both entries/menus while lower toggle remains live.
        captureDelay = 0.8
        delegate.runOCRNow()
        delegate.runOCRTranslateNow()
        delegate.primaryAction()
        try check(delegate.isOCRInProgress, "OCR lock is acquired before Task runs")
        await pause(0.05)
        let inProgressCount = captureCount
        let busyMenu = ball.onRequestMenu!()
        try check(!busyMenu.items[1].isEnabled && !busyMenu.items[2].isEnabled, "Both OCR menu items disabled while busy")
        down(); await pause(0.45)
        drag(CGPoint(x: ring.center.x - 43, y: ring.center.y + 43))
        try check(ring.selected == nil, "Busy OCR sectors cannot be selected")
        try snap("13-ocr-busy")
        drag(CGPoint(x: ring.center.x, y: ring.center.y - 58))
        try check(ring.selected == .clipboardWatch, "Busy OCR does not block lower switch")
        up(center()); await pause(0.55)
        try check(captureCount == inProgressCount, "Reentry launches no extra capture")
        try check(!delegate.isOCRInProgress, "Task lock clears after slow capture")
        captureDelay = 0.05

        // Already-target-language OCR still presents a result without HTTP.
        capturedText = "这是已经识别出的中文原文。"
        let requests = FixtureProtocol.requestCount
        delegate.runOCRTranslateNow(); await pause(0.2)
        try check(delegate.lastStatus == "无需翻译" && overlayModel.translated == capturedText, "Target-language OCR displays recognized text")
        try check(FixtureProtocol.requestCount == requests, "Already-target OCR sends no translation request")

        // Failure/cancellation/no-text all clear the lock; cancellation hides overlay.
        for error in [OCRService.OCRError.cancelled, .noText, .captureFailed] {
            captureError = error
            delegate.runOCRTranslateNow(); await pause(0.2)
            try check(!delegate.isOCRInProgress, "Every capture error clears task lock")
            if case .cancelled = error {
                try check(delegate.lastStatus == "已取消", "Cancelled OCR is not an error")
                let panel: NSPanel? = member(overlay, "window")
                try check(panel?.isVisible == false, "Cancellation leaves no subtitle")
            } else {
                try check(overlayModel.isError, "Capture failure/no text show an error")
            }
        }
        captureError = nil
        capturedText = "Hello, world!"
        FixtureProtocol.fail = true
        delegate.runOCRTranslateNow(); await pause(0.25)
        try check(!delegate.isOCRInProgress && overlayModel.isError, "Translation failure clears OCR task lock")
        FixtureProtocol.fail = false
        delegate.settings.showOriginal = false
        delegate.runOCRTranslateNow(); await pause(0.25)
        try check(overlayModel.original == nil && overlayModel.translated == "你好，世界！", "showOriginal off applies to OCR translation")

        delegate.settings.apiKey = ""
        let beforeUnconfigured = captureCount
        delegate.runOCRTranslateNow(); await pause(0.08)
        try check(captureCount == beforeUnconfigured && !delegate.isOCRInProgress, "Unconfigured translation does not launch capture")
        let settingsWindow: NSWindow = member(delegate, "settingsWindow")
        let settingsHost = settingsWindow.contentViewController as! NSHostingController<SettingsView>
        for enabled in [true, false] {
            settingsHost.rootView.settings.autoWatchClipboard = enabled
            settingsHost.rootView.onClipboardWatchChange()
            let pollingTimer: Timer? = member(delegate, "clipTimer")
            try check((pollingTimer != nil) == enabled && ball.watchingClipboard == enabled,
                      "Settings-page callback applies polling and accessory state")
        }
        settingsWindow.orderOut(nil)

        // Hide/screen/session loss cancels selection and any pending action.
        down(); await pause(0.45)
        ball.hide(); up(center()); await pause()
        try check(!ring.isVisible, "Hiding ball cancels ring")
        ball.show()
        down(); await pause(0.45)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await pause(0.05)
        try check(!ring.isVisible, "Screen change cancels ring")
        down(); await pause(0.45)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await pause(0.05)
        try check(!ring.isVisible, "Session loss cancels ring")

        // No-motion branch is directly exercised without changing system prefs.
        ring.show(ballCenter: center(), press: center(), screen: screen, aboveWindow: window,
                  watching: false, ocrBusy: false, reduceMotion: true)
        ring.update(point: CGPoint(x: ring.center.x - 43, y: ring.center.y + 43))
        try check(ring.selected == .ocr, "Reduced-motion ring still selects")
        try snap("14-reduced-motion")
        var finishedImmediately = false
        ring.finish { finishedImmediately = !ring.isVisible }
        try check(finishedImmediately, "Reduced motion finishes with no animation delay")

        print("Passed: gestures, 9 edge/corner geometries, menus, accessory sync, OCR lock, plain/translated subtitles, cancellation/failures, reduced-motion branch.")
        print("System screencapture, user pointer/keyboard operation and actual OS Reduce Motion toggle remain manual checks.")
    }

    @MainActor static func labelsAndGlass(ball: NSWindow, screen: NSScreen, to output: URL) async throws {
        // Own the visual fixture independently of the application's global
        // session/menu cancellation observers. Those are tested below.
        let ring = BallSelectionController()
        let savedFrame = ball.frame
        let backdropFrame = CGRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.midY - 155,
                                   width: 420, height: 310)
        let backdrop = NSPanel(contentRect: backdropFrame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        backdrop.level = .statusBar
        backdrop.hidesOnDeactivate = false
        backdrop.ignoresMouseEvents = true
        let background = GlassTestBackground(frame: CGRect(origin: .zero, size: backdropFrame.size))
        backdrop.contentView = background
        let center = CGPoint(x: backdropFrame.midX, y: backdropFrame.midY - 8)
        ball.setFrameOrigin(CGPoint(x: center.x - BallView.ballCenter.x, y: center.y - BallView.ballCenter.y))
        defer {
            ring.cancel()
            backdrop.orderOut(nil)
            let panel: NSPanel = member(ring, "panel")
            panel.appearance = nil
            ball.setFrame(savedFrame, display: true)
        }

        func show(reduceMotion: Bool = false) {
            ring.show(ballCenter: center, press: center, screen: screen, aboveWindow: ball,
                      watching: false, ocrBusy: false, reduceMotion: reduceMotion)
            let panel: NSPanel = member(ring, "panel")
            panel.appearance = NSAppearance(named: .aqua)
            backdrop.order(.below, relativeTo: panel.windowNumber)
        }
        func snap(_ name: String) throws {
            let panel: NSPanel = member(ring, "panel")
            try check(ring.isVisible && panel.alphaValue > 0.99, "Screenshot requires a fully visible ring")
            // Only test-owned windows are composited by WindowServer. The
            // backdrop is behind the live visual-effect view, not added later.
            // CoreGraphics expects raw CGWindowID values in this CFArray,
            // rather than retained NSNumber objects.
            let ids = CFArrayCreateMutable(nil, 0, nil)!
            for window in [ball, panel, backdrop] {
                CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: window.windowNumber))
            }
            let bubble: NSPanel? = member(ring, "bubblePanel")
            if let bubble, bubble.isVisible {
                CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: bubble.windowNumber))
            }
            guard let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: ids,
                                      imageOption: [.boundsIgnoreFraming, .bestResolution]) else {
                throw Failure(description: "Cannot capture native glass over test background")
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        show()
        let view: BallSelectionView = member(ring, "view")
        let material: NSVisualEffectView = member(view, "material")
        try check(material.material == .popover && material.blendingMode == .behindWindow && material.state == .active,
                  "Glass uses active system material behind the native window")
        try check(BallSelectionView.labelDelay == 0.5, "Label dwell is 500 ms")
        await pause(0.2)
        try check(view.labelAction == nil, "New ring contains icons only")
        try snap("round2-01-icons-only")
        try snap("round2-05-glass-light")

        let upper = CGPoint(x: center.x - 43, y: center.y + 43)
        let lower = CGPoint(x: center.x, y: center.y - 58)
        let hoverStart = CACurrentMediaTime()
        ring.update(point: upper)
        await pause(0.25)
        try check(ring.selected == .ocr && view.labelAction == nil,
                  "Selection before dwell: visible=\(ring.isVisible), selected=\(String(describing: ring.selected)), label=\(String(describing: view.labelAction)), elapsed=\(CACurrentMediaTime() - hoverStart)")
        try snap("round2-02-upper-before-500ms")
        // Movement within the same wedge must not restart the dwell.
        ring.update(point: CGPoint(x: upper.x - 1, y: upper.y + 1))
        await pause(0.4)
        try check(view.labelAction == .ocr && view.labelOpacity == 1, "Upper label appears after 500 ms despite pointer jitter")
        try snap("round2-03-upper-after-500ms")
        ring.update(point: lower)
        try check(view.labelAction == nil, "Leaving upper wedge hides its label immediately")
        await pause(0.25)
        try check(view.labelAction == nil, "New wedge has a fresh dwell")
        try snap("round2-04a-upper-left-lower-before-500ms")
        await pause(0.4)
        try check(view.labelAction == .clipboardWatch && !view.watching, "Lower title and current on/off state appear together")
        try snap("round2-04-lower-after-500ms")

        ring.update(point: center)
        try check(view.labelAction == nil, "Returning to center hides labels")
        ring.update(point: upper)
        await pause(0.25)
        ring.update(point: lower)
        await pause(0.3)
        try check(view.labelAction == nil, "A departed wedge's delayed callback cannot reveal text")
        ring.cancel()
        await pause(0.3)
        try check(view.labelAction == nil && !ring.isVisible, "Cancellation invalidates pending label")

        show(reduceMotion: true)
        ring.update(point: upper)
        await pause(0.25)
        try check(view.labelAction == nil, "Reduced motion keeps the 500 ms dwell")
        await pause(0.3)
        try check(view.labelAction == .ocr && view.labelOpacity == 1, "Reduced motion reveals text with no fade")
        try snap("round2-07-reduced-motion")
        // Seam hysteresis and outer tolerance retain the action but hide text.
        ring.update(point: CGPoint(x: center.x + 1, y: center.y + 60))
        try check(ring.selected == .ocr && view.labelAction == nil, "Seam retains action but hides departed wedge label")
        ring.update(point: CGPoint(x: center.x - 62, y: center.y + 62))
        try check(ring.selected == .ocr && view.hoveredForLabel == nil, "Outer tolerance acts without a label hover")
        ring.cancel()

        background.dark = true
        show()
        await pause(0.2)
        try snap("round2-06-glass-dark")
        let panel: NSPanel = member(ring, "panel")
        panel.appearance = NSAppearance(named: .darkAqua)
        await pause(0.2)
        try snap("round2-06b-glass-dark-appearance")
        ring.update(point: lower)
        await pause(0.65)
        try snap("round2-06c-dark-lower-label")
        var finished = false
        ring.finish { finished = !ring.isVisible }
        try check(view.labelAction == .clipboardWatch, "Visible label is retained through release confirmation")
        await pause(0.25)
        try check(finished, "Normal release still finishes after hiding the ring")

        show()
        ring.update(point: upper)
        await pause(0.1)
        ring.finish {}
        await pause(0.55)
        try check(view.labelAction == nil && !ring.isVisible, "Fast release cannot reveal a late label")
        show()
        ring.update(point: upper)
        ring.update(watching: true, ocrBusy: true)
        await pause(0.55)
        try check(ring.selected == nil && view.labelAction == nil, "Disabling OCR invalidates its pending label")
        ring.cancel()

        // Supplemental same-material preview. Legacy WindowServer window
        // captures can flatten behind-window effects; this native within-window
        // composition records the material without needing desktop access.
        let preview = BallSelectionView(frame: CGRect(x: backdropFrame.width / 2 - 84,
                                                      y: backdropFrame.height / 2 - 92,
                                                      width: 168, height: 168))
        preview.reduceMotion = true
        let previewMaterial: NSVisualEffectView = member(preview, "material")
        previewMaterial.blendingMode = .withinWindow
        background.wantsLayer = true
        background.addSubview(preview)
        defer { preview.removeFromSuperview() }
        for dark in [false, true] {
            background.dark = dark
            backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await pause(0.2)
            let ids = CFArrayCreateMutable(nil, 0, nil)!
            for window in [ball, backdrop] {
                CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: window.windowNumber))
            }
            guard let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: ids,
                                      imageOption: [.boundsIgnoreFraming, .bestResolution]) else {
                throw Failure(description: "Cannot capture supplementary native material preview")
            }
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(
                to: output.appendingPathComponent("round2-preview-material-\(dark ? "dark" : "light").png"))
        }
        print("Passed: 500 ms labels, jitter, sector leave/reentry, stale timers, quick release, seam/tolerance, reduced motion; native glass on light/dark test backgrounds.")
    }

    @MainActor static func floatingBubbles(ball: NSWindow, screen: NSScreen, to output: URL) async throws {
        let ring = BallSelectionController()
        let savedFrame = ball.frame
        let visible = screen.visibleFrame
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        defer {
            ring.cancel()
            ball.setFrame(savedFrame, display: true)
        }
        func show(at point: CGPoint, reduceMotion: Bool = true) {
            ring.cancel()
            ball.setFrameOrigin(CGPoint(x: point.x - BallView.ballCenter.x,
                                       y: point.y - BallView.ballCenter.y))
            ring.show(ballCenter: point, press: point, screen: screen, aboveWindow: ball,
                      watching: false, ocrBusy: false, reduceMotion: reduceMotion)
        }
        func hover(_ action: BallQuickAction) {
            let icon = BallSelectionGeometry.iconCenter(for: action)
            ring.update(point: CGPoint(x: ring.center.x + icon.x, y: ring.center.y + icon.y))
        }
        func snap(_ name: String) throws {
            try captureScene(ball: ball, ring: ring, to: output.appendingPathComponent(name + ".png"))
        }
        func checkBubble(_ action: BallQuickAction, watching: Bool = false) throws {
            try check(ring.selected == action && ring.bubbleIsVisible, "Dwell reveals the current sector bubble")
            guard let frame = ring.visibleBubbleFrame else { throw Failure(description: "Missing bubble frame") }
            try check(visible.contains(frame), "Actual bubble panel remains inside screen visibleFrame")
            for iconAction in BallQuickAction.allCases {
                let icon = BallSelectionGeometry.iconCenter(for: iconAction)
                let iconRect = CGRect(x: ring.center.x + icon.x * 1.06 - 10,
                                      y: ring.center.y + icon.y * 1.06 - 10, width: 20, height: 20)
                try check(!frame.intersects(iconRect), "Bubble never covers an animated icon")
            }
            let panel: NSPanel = member(ring, "bubblePanel")
            let bubbleView: NSView = member(ring, "bubbleView")
            let material: NSVisualEffectView = member(bubbleView, "material")
            let title: NSTextField = member(bubbleView, "title")
            try check(title.stringValue == action.title(watching: watching), "Bubble contains function and current on/off state")
            try check(title.frame.width >= title.intrinsicContentSize.width, "Bubble fits the complete function title")
            try check(material.material == .popover && material.blendingMode == .behindWindow && material.state == .active,
                      "Bubble uses the same active glass as the ring")
            try check(panel.ignoresMouseEvents && !panel.canBecomeKey, "Bubble cannot steal the held-pointer gesture or focus")
        }

        show(at: middle, reduceMotion: false)
        await pause(0.2)
        try check(!ring.bubbleIsVisible, "Unhovered ring has no bubble")
        try snap("round3-01-centered-icons")
        hover(.ocr)
        await pause(0.25)
        try check(!ring.bubbleIsVisible, "No bubble before 500 ms")
        try snap("round3-02-before-500ms")
        await pause(0.4)
        try checkBubble(.ocr)
        try snap("round3-03-ocr-bubble")
        let bubble: NSPanel = member(ring, "bubblePanel")
        try check(bubble.alphaValue == 1, "Normal bubble finishes its fade")
        hover(.ocrTranslate)
        try check(!ring.bubbleIsVisible, "Changing wedge immediately hides the previous bubble")
        await pause(0.65)
        try checkBubble(.ocrTranslate)
        try snap("round3-04-translation-bubble")
        hover(.clipboardWatch)
        await pause(0.65)
        try checkBubble(.clipboardWatch)
        try snap("round3-05-watch-off-bubble")
        ring.update(watching: true, ocrBusy: false)
        await pause(0.05)
        try checkBubble(.clipboardWatch, watching: true)
        try snap("round3-05a-watch-on-bubble")
        ring.update(point: middle)
        try check(!ring.bubbleIsVisible, "Leaving the wedge hides the bubble immediately")
        try snap("round3-06-left-wedge")

        // Default right edge: all three real native bubble frames, with the
        // original ring translation and all icons still fully visible.
        let right = CGPoint(x: visible.maxX - 29, y: visible.midY)
        for action in BallQuickAction.allCases {
            show(at: right)
            try check(abs(ring.center.x - (visible.maxX - 84)) < 0.1, "Bubble does not alter ring edge translation")
            hover(action)
            await pause(0.55)
            try checkBubble(action)
            try snap("round3-right-edge-\(action)")
        }
        for (name, point) in [
            ("top-left", CGPoint(x: visible.minX + 29, y: visible.maxY - 29)),
            ("top-right", CGPoint(x: visible.maxX - 29, y: visible.maxY - 29)),
            ("bottom-left", CGPoint(x: visible.minX + 29, y: visible.minY + 29)),
            ("bottom-right", CGPoint(x: visible.maxX - 29, y: visible.minY + 29))
        ] {
            for action in BallQuickAction.allCases {
                show(at: point)
                // At corners the original press dead zone can cover a symbol;
                // choose an actual visible point in the wedge outside that zone.
                for degrees in stride(from: 5, to: 360, by: 5) {
                    let angle = CGFloat(degrees) * .pi / 180
                    let candidate = CGPoint(x: ring.center.x + cos(angle) * 70,
                                            y: ring.center.y + sin(angle) * 70)
                    if BallSelectionGeometry.action(at: candidate, center: ring.center, press: point,
                                                    previous: nil, ocrBusy: false) != action { continue }
                    ring.update(point: candidate)
                    if ring.selected == action { break }
                }
                await pause(0.55)
                try checkBubble(action)
                try snap("round3-\(name)-\(action)")
            }
        }

        show(at: middle)
        hover(.ocr)
        await pause(0.25)
        try check(!ring.bubbleIsVisible, "Reduced motion still waits 500 ms")
        await pause(0.3)
        try checkBubble(.ocr)
        try check(bubble.alphaValue == 1, "Reduced motion reveals the bubble immediately without a fade")
        var completed = false
        ring.finish { completed = !ring.isVisible && !ring.bubbleIsVisible }
        try check(completed, "Both panels hide before reduced-motion action")

        show(at: middle, reduceMotion: false)
        hover(.ocrTranslate)
        await pause(0.65)
        ring.finish { completed = !ring.isVisible && !ring.bubbleIsVisible }
        completed = false
        await pause(0.25)
        try check(completed, "Both panels hide before normal action")
        show(at: middle)
        hover(.ocr)
        await pause(0.2)
        ring.cancel()
        await pause(0.4)
        try check(!ring.isVisible && !ring.bubbleIsVisible, "Cancellation cannot leave or reveal an orphan bubble")
        print("Passed: centered icons, native bubbles, dwell/leave, state text, right edge, all corners, glass, focus transparency, both-panel completion.")
    }

    @MainActor static func geometryAndGestures() throws {
        var state = BallGesture.State()
        state.begin(at: .zero, time: 0)
        state.update(at: CGPoint(x: 4, y: 4), time: 0.1)
        try check(state.phase == .dragging, "Diagonal Euclidean movement exceeds 5 pt")
        state.update(at: .zero, time: 1)
        try check(state.phase == .dragging, "Returning to origin does not rearm long press")
        state.begin(at: .zero, time: 0)
        state.update(at: CGPoint(x: 3, y: 2), time: 0.399)
        try check(state.phase == .pressing, "Hold must reach 400 ms")
        state.update(at: CGPoint(x: 3, y: 2), time: 0.401)
        try check(state.phase == .selecting, "Small jitter allows hold")
        state.update(at: CGPoint(x: 100, y: 100), time: 2)
        try check(state.phase == .selecting, "Selection movement never drags ball")

        let frame = CGRect(x: -1920, y: 61, width: 1920, height: 989)
        for x in [frame.minX + 29, frame.midX, frame.maxX - 29] {
            for y in [frame.minY + 29, frame.midY, frame.maxY - 29] {
                let press = CGPoint(x: x, y: y)
                let center = BallSelectionGeometry.center(ball: press, visibleFrame: frame)
                let ring = CGRect(x: center.x - 84, y: center.y - 84, width: 168, height: 168)
                try check(frame.contains(ring), "All edge/corner rings fit their screen")
                try check(BallSelectionGeometry.action(at: press, center: center, press: press,
                                                      previous: .ocr, ocrBusy: false) == nil, "Shifted press stays dead zone")
                for action in BallQuickAction.allCases {
                    var reachable = false
                    for degrees in stride(from: 0, to: 360, by: 5) {
                        let angle = CGFloat(degrees) * .pi / 180
                        let point = CGPoint(x: center.x + cos(angle) * 63, y: center.y + sin(angle) * 63)
                        if BallSelectionGeometry.action(at: point, center: center, press: press,
                                                        previous: nil, ocrBusy: false) == action { reachable = true }
                    }
                    try check(reachable, "Every sector remains selectable at every edge/corner")
                }
            }
        }
        for frame in [
            frame,
            CGRect(x: 0, y: -1080, width: 1280, height: 720),
            CGRect(x: -320, y: 0, width: 640, height: 480)
        ] {
            for x in [frame.minX + 29, frame.midX, frame.maxX - 29] {
                for y in [frame.minY + 29, frame.midY, frame.maxY - 29] {
                    let center = BallSelectionGeometry.center(ball: CGPoint(x: x, y: y), visibleFrame: frame)
                    for action in BallQuickAction.allCases {
                        let bubble = BallSelectionGeometry.bubbleFrame(for: action, size: CGSize(width: 156, height: 34),
                                                                       center: center, visibleFrame: frame)
                        try check(frame.contains(bubble), "Bubble stays on its own display, including negative origins")
                        let nearest = CGPoint(x: min(max(center.x, bubble.minX), bubble.maxX),
                                              y: min(max(center.y, bubble.minY), bubble.maxY))
                        try check(hypot(nearest.x - center.x, nearest.y - center.y) >= 84,
                                  "Clamped bubble remains outside the animated ring")
                    }
                }
            }
        }
        for action in BallQuickAction.allCases {
            let icon = BallSelectionGeometry.iconCenter(for: action)
            let radius = hypot(icon.x, icon.y)
            try check(abs((radius - BallSelectionGeometry.innerRadius)
                          - (BallSelectionGeometry.outerRadius - radius)) < 0.01,
                      "Icons have equal space toward the inner and outer ring edges")
            try check(BallSelectionGeometry.path(for: action).contains(icon), "Centered icon lies inside its wedge")
        }
        let center = CGPoint.zero
        try check(BallSelectionGeometry.action(at: CGPoint(x: 1, y: 60), center: center, press: center,
                                              previous: .ocr, ocrBusy: false) == .ocr, "Boundary seam retains previous sector")
        try check(BallSelectionGeometry.action(at: CGPoint(x: -70, y: 60), center: center, press: center,
                                              previous: nil, ocrBusy: false) == .ocr, "76–96 pt outer tolerance is selectable")
        try check(BallSelectionGeometry.action(at: CGPoint(x: -100, y: 0), center: center, press: center,
                                              previous: .ocr, ocrBusy: false) == nil, "Outside cancels")
        try check(BallSelectionView.contrastingText(for: .yellow) == .black, "Yellow accent uses black text")
        try check(BallSelectionView.contrastingText(for: .black) == .white, "Dark accent uses white text")
        try check(AppMode(rawValue: "translate") == .translate && AppMode(rawValue: "ocr") == .ocr,
                  "Persisted old modes keep their semantics")
    }

    @MainActor static func overlayView(_ overlay: OverlayController) -> NSView {
        let panel: NSPanel = member(overlay, "window")
        return panel.contentView!
    }
    @MainActor static func bitmap(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    @MainActor static func captureView(_ view: NSView, to url: URL) throws {
        try bitmap(view).representation(using: .png, properties: [:])!.write(to: url)
    }
    @MainActor static func windowImage(_ window: NSWindow) throws -> NSImage {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
            throw Failure(description: "Cannot capture test-owned WindowServer panel")
        }
        return NSImage(cgImage: image, size: window.frame.size)
    }
    @MainActor static func captureWindow(_ window: NSWindow, to url: URL) throws {
        let image = try windowImage(window)
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
    @MainActor static func renderSkins(to directory: URL) throws {
        let atlas = NSImage(size: CGSize(width: 680, height: 390))
        atlas.lockFocus()
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: 680, height: 390).fill()
        NSAttributedString(string: "自动监听粘贴板 · 耳机配饰", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.labelColor
        ]).draw(at: CGPoint(x: 26, y: 345))
        for (index, skin) in BallSkin.allCases.enumerated() {
            let x = CGFloat(index) * 130 + 15
            NSAttributedString(string: skin.label, attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: x + 16, y: 310))
            for (row, watching) in [false, true].enumerated() {
                let view = BallView(frame: CGRect(origin: .zero, size: BallView.canvasSize))
                view.skin = skin
                view.setHeadphonesInitially(watching)
                let image = NSImage(size: BallView.canvasSize)
                image.addRepresentation(bitmap(view))
                let y = row == 0 ? 190.0 : 45.0
                image.draw(in: CGRect(x: x, y: y, width: 115, height: 115))
                NSAttributedString(string: watching ? "开 · 耳机" : "关 · 无配饰",
                                   attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
                    .draw(at: CGPoint(x: x + 20, y: y - 18))
                try captureView(view, to: directory.appendingPathComponent("\(skin.rawValue)-\(watching ? "on" : "off").png"))
            }
        }
        atlas.unlockFocus()
        let rep = NSBitmapImageRep(data: atlas.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("accessory-atlas.png"))
    }
    @MainActor static func captureScene(ball: NSWindow, ring: BallSelectionController, to url: URL,
                                       fixedFrame: CGRect? = nil) throws {
        let panel: NSPanel? = member(ring, "panel")
        let bubble: NSPanel? = member(ring, "bubblePanel")
        var contentFrame = panel?.isVisible == true ? ball.frame.union(panel!.frame) : ball.frame
        if let bubble, bubble.isVisible { contentFrame = contentFrame.union(bubble.frame) }
        let frame = fixedFrame ?? contentFrame.insetBy(dx: -18, dy: -18)
        let image = NSImage(size: frame.size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        CGRect(origin: .zero, size: frame.size).fill()
        var windows = panel?.isVisible == true ? [panel!, ball] : [ball]
        if let bubble, bubble.isVisible { windows.append(bubble) }
        for window in windows {
            let content = try windowImage(window)
            content.draw(in: CGRect(x: window.frame.minX - frame.minX, y: window.frame.minY - frame.minY,
                                    width: window.frame.width, height: window.frame.height),
                         from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

/// Controlled wallpaper window owned by the test process, so screenshots never
/// include the user's desktop contents or require Screen Recording permission.
private final class GlassTestBackground: NSView {
    var dark = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: dark ? 0.09 : 0.95, alpha: 1).setFill()
        bounds.fill()
        let colors = dark
            ? [NSColor(red: 0.13, green: 0.20, blue: 0.32, alpha: 1),
               NSColor(red: 0.21, green: 0.13, blue: 0.28, alpha: 1)]
            : [NSColor(red: 0.76, green: 0.87, blue: 0.93, alpha: 1),
               NSColor(red: 0.91, green: 0.81, blue: 0.70, alpha: 1)]
        colors[0].setFill()
        CGRect(x: 0, y: 0, width: bounds.midX, height: bounds.height - 58).fill()
        colors[1].setFill()
        CGRect(x: bounds.midX, y: 0, width: bounds.midX, height: bounds.height - 58).fill()
        for index in 0..<20 {
            NSColor(calibratedWhite: dark ? 0.04 : 1, alpha: 0.25).setFill()
            CGRect(x: CGFloat(index) * 24, y: 0, width: 12, height: bounds.height - 58).fill()
        }
        NSAttributedString(string: dark ? "深色测试背景" : "浅色测试背景", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: dark ? NSColor.white : NSColor.black
        ]).draw(at: CGPoint(x: 22, y: bounds.height - 36))
    }
}
