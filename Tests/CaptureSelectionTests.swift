import AppKit
import ScreenCaptureKit
import Combine

private final class CaptureTranslationFixture: URLProtocol {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "capture-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"清晰的文字，干净的截图。"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct CaptureSelectionTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    @MainActor static func pause(_ seconds: Double = 0.12) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor static func member<T>(_ value: Any, _ label: String) -> T {
        Mirror(reflecting: value).children.first { $0.label == label }!.value as! T
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try geometry()
                try await nativeSelection()
                print("Capture selection tests passed")
                exit(0)
            } catch {
                print("FAILED: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func geometry() throws {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let rect = CGRect(x: 200, y: 200, width: 300, height: 200)
        let pointer = CGPoint(x: rect.maxX, y: rect.minY)
        func layout(_ selection: CGRect, wasVisible: Bool = false, recovering: Bool = false,
                    hasPet: Bool = true) -> CaptureDecorationLayout.Layout {
            CaptureDecorationLayout.layout(selection: selection, pointer: pointer, screen: screen,
                                           readoutSize: CGSize(width: 110, height: 28), hasPet: hasPet,
                                           wasVisible: wasVisible, recovering: recovering)
        }
        try check(layout(rect).showsPet, "Normal selection shows the pet")
        try check(!layout(CGRect(x: 200, y: 300, width: 79.9, height: 50)).showsPet,
                  "Width below 80 pt hides the entire pet")
        try check(!layout(CGRect(x: 200, y: 300, width: 100, height: 39.9)).showsPet,
                  "Height below 40 pt hides the entire pet")
        try check(layout(CGRect(x: 200, y: 300, width: 80, height: 40)).showsPet,
                  "80 x 40 pt may show a pet initially")
        try check(!layout(CGRect(x: 200, y: 300, width: 83.9, height: 44), recovering: true).showsPet,
                  "Size recovery requires 84 pt")
        try check(!layout(CGRect(x: 200, y: 300, width: 84, height: 43.9), recovering: true).showsPet,
                  "Size recovery requires 44 pt")
        try check(layout(CGRect(x: 200, y: 300, width: 84, height: 44), recovering: true).showsPet,
                  "84 x 44 pt restores the pet")
        try check(!layout(rect, hasPet: false).showsPet, "Classic never shows a pet")
        try check(!layout(CGRect(x: 21.9, y: 200, width: 300, height: 200)).showsPet,
                  "Envelope plus 4 pt outside the left edge hides the pet")
        try check(layout(CGRect(x: 22, y: 200, width: 300, height: 200)).showsPet,
                  "22 pt left margin is sufficient initially")
        try check(!layout(CGRect(x: 22, y: 200, width: 300, height: 200), recovering: true).showsPet,
                  "Envelope recovery requires another 4 pt")
        try check(layout(CGRect(x: 26, y: 200, width: 300, height: 200), recovering: true).showsPet,
                  "26 pt left margin restores the pet")
        try check(!layout(CGRect(x: 200, y: 540, width: 300, height: 200)).showsPet,
                  "60 pt top margin is insufficient")
        try check(layout(CGRect(x: 200, y: 539, width: 300, height: 200)).showsPet,
                  "61 pt top margin is sufficient")
        let corner = CGPoint(x: rect.minX, y: rect.maxY)
        let crowded = CaptureDecorationLayout.layout(selection: rect, pointer: corner, screen: screen,
                                                      readoutSize: CGSize(width: 130, height: 28), hasPet: true,
                                                      wasVisible: true, recovering: false)
        try check(!crowded.showsPet, "Pet gives way when all four readout positions collide")
        let avoidance = CaptureDecorationLayout.layout(selection: rect,
                                                       pointer: CGPoint(x: corner.x + 120, y: corner.y), screen: screen,
                                                       readoutSize: CGSize(width: 130, height: 28), hasPet: true,
                                                       wasVisible: true, recovering: false)
        try check(avoidance.showsPet && !avoidance.readout.intersects(
            CaptureDecorationLayout.envelope(at: corner).insetBy(dx: -8, dy: -8)), "Readout avoids the pet by 8 pt")
        try check(screen.insetBy(dx: 8, dy: 8).contains(avoidance.readout), "Readout stays inside screen")

        let retina = CaptureGeometry.Surface(frame: CGRect(x: -1200, y: -100, width: 1200, height: 800),
                                             pixelWidth: 2400, pixelHeight: 1600)
        let crop = CaptureGeometry.pixelRect(selection: CGRect(x: -1100, y: 500, width: 80, height: 40),
                                              surface: retina)
        try check(crop == CGRect(x: 200, y: 320, width: 160, height: 80),
                  "Negative display origin, AppKit y-up and Retina pixels convert correctly")
        let fractional = CaptureGeometry.pixelRect(selection: CGRect(x: -1099.75, y: 500.25, width: 80, height: 40),
                                                    surface: retina)
        try check(fractional == CGRect(x: 200, y: 319, width: 161, height: 81),
                  "Outward pixel rounding retains partial edge pixels")
        let oddDensity = CaptureGeometry.Surface(frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                 pixelWidth: 1500, pixelHeight: 1600)
        try check(CaptureGeometry.pixelRect(selection: CGRect(x: 100, y: 500, width: 80, height: 40), surface: oddDensity)
                  == CGRect(x: 150, y: 520, width: 120, height: 80), "Use actual x/y image ratios independently")
        let left = CaptureGeometry.Surface(frame: CGRect(x: -100, y: 0, width: 100, height: 100),
                                           pixelWidth: 100, pixelHeight: 100)
        let right = CaptureGeometry.Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            pixelWidth: 200, pixelHeight: 200)
        let plan = CaptureGeometry.plan(selection: CGRect(x: -20, y: 20, width: 40, height: 40), surfaces: [left, right])!
        try check(plan.width == 80 && plan.height == 80 && plan.crops.count == 2, "Cross-screen output uses highest density")
        try check(plan.crops[0].source == CGRect(x: 80, y: 40, width: 20, height: 40), "1x source uses its own ratio")
        try check(plan.crops[1].source == CGRect(x: 0, y: 80, width: 40, height: 80), "2x source uses its own ratio")
        let gap = CaptureGeometry.Surface(frame: CGRect(x: 10, y: 0, width: 100, height: 100),
                                          pixelWidth: 100, pixelHeight: 100)
        try check(CaptureGeometry.plan(selection: CGRect(x: -20, y: 20, width: 40, height: 40),
                                      surfaces: [left, gap]) == nil, "Display gaps cannot submit")
        try check(CaptureGeometry.plan(selection: .zero, surfaces: [left]) == nil, "Zero area cannot submit")
        try check(CaptureGeometry.selection(from: CGPoint(x: 50, y: 70), to: CGPoint(x: 10, y: 20))
                  == CGRect(x: 10, y: 20, width: 40, height: 50), "Reverse drag normalizes")
        let composited = try CaptureSelectionController.crop(frames: [
            CapturedScreen(displayID: 1, frame: left.frame, image: colorImage(width: 100, height: 100, color: .red)),
            CapturedScreen(displayID: 2, frame: right.frame, image: colorImage(width: 200, height: 200, color: .blue))
        ], plan: plan)
        let rgba = [UInt8](pixels(composited))
        let leftPixel = (20 * composited.width + 20) * 4
        let rightPixel = (20 * composited.width + 60) * 4
        try check(rgba[leftPixel] > 240 && rgba[leftPixel + 2] < 10, "Mixed-density left segment remains red")
        try check(rgba[rightPixel] < 10 && rgba[rightPixel + 2] > 240, "Mixed-density right segment remains blue")
        let directional = try fixture(size: CGSize(width: 200, height: 200),
                                      selection: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1)
        let surface = CaptureGeometry.Surface(frame: CGRect(x: -200, y: 50, width: 200, height: 200),
                                              pixelWidth: 200, pixelHeight: 200)
        let upperPlan = CaptureGeometry.plan(selection: CGRect(x: -200, y: 150, width: 200, height: 100),
                                            surfaces: [surface])!
        let upperImage = try CaptureSelectionController.crop(frames: [
            CapturedScreen(displayID: 1, frame: surface.frame, image: directional)
        ], plan: upperPlan)
        let directTop = directional.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 100))!
        try check(pixels(upperImage) == pixels(directTop), "Top AppKit region crops top image rows without a vertical flip")
        print("Passed: small selections, envelope overflow, recovery, readout avoidance, pixel mapping and mixed-density plans")
    }

    @MainActor static func nativeSelection() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let permission = CGPreflightScreenCaptureAccess()
        print("Screen recording permission: \(permission)")
        print("Native AppKit panels and NSEvents; frozen input is an explicit test fixture. Translation uses URLProtocol.")
        let screen = NSScreen.main!
        let frame = screen.frame
        let selection = CGRect(x: frame.minX + 220, y: frame.maxY - 420, width: 520, height: 240)
        let source = try fixture(size: frame.size, selection: selection.offsetBy(dx: -frame.minX, dy: -frame.minY), scale: 2)
        let captured = CapturedScreen(displayID: 0, frame: frame, image: source)
        let controller = CaptureSelectionController()
        let expectedPlan = CaptureGeometry.plan(selection: selection, surfaces: [captured.surface])!
        let expected = try CaptureSelectionController.crop(frames: [captured], plan: expectedPlan)
        try save(expected, to: output.appendingPathComponent("ocr-expected.png"))

        for skin in BallSkin.allCases {
            let task = Task { @MainActor in try await controller.select(screens: [captured], skin: skin) }
            await pause()
            guard let panel = controller.panels.first, let view = panel.contentView as? CaptureSelectionView else {
                throw Failure(description: "Native selection panel did not appear")
            }
            try check(panel.isVisible, "Selection panel is live on WindowServer")
            try check(view.hasPet == (skin != .classic), "Classic creates no pet/head view")
            send(.leftMouseDown, point: CGPoint(x: selection.minX, y: selection.maxY), panel: panel)
            send(.leftMouseDragged, point: CGPoint(x: selection.maxX, y: selection.minY), panel: panel)
            send(.mouseMoved, point: CGPoint(x: selection.minX + 100, y: selection.maxY - 40), panel: panel)
            await pause()
            try check(view.selection == selection, "Hover events cannot overwrite a held-button drag rectangle")
            try check(view.showsPet == (skin != .classic), "Native normal-selection decoration matches skin")
            try await screenshot(panel: panel, output: output.appendingPathComponent("selection-\(skin.rawValue).png"),
                                 permission: permission)
            send(.leftMouseUp, point: CGPoint(x: selection.maxX, y: selection.minY), panel: panel)
            let actual = try await task.value
            try check(!panel.isVisible && controller.panels.isEmpty, "All panels close before image delivery")
            try check(pixels(actual) == pixels(expected), "OCR image contains only unchanged source pixels")
            try save(actual, to: output.appendingPathComponent("ocr-\(skin.rawValue).png"))
            let recognized = try await OCRService.recognize(image: actual, languages: ["en-US"])
            try check(recognized.contains("Clear text") && recognized.contains("clean capture"),
                      "Real Vision recognizes the actual selection crop")
        }
        for (name, rect) in [
            ("small", CGRect(x: frame.minX + 220, y: frame.maxY - 220, width: 60, height: 30)),
            ("top-left-edge", CGRect(x: frame.minX, y: frame.maxY - 200, width: 300, height: 200))
        ] {
            let task = Task { @MainActor in try await controller.select(screens: [captured], skin: .cat) }
            await pause()
            let panel = controller.panels[0]
            let view = panel.contentView as! CaptureSelectionView
            send(.leftMouseDown, point: CGPoint(x: rect.minX, y: rect.maxY), panel: panel)
            send(.leftMouseDragged, point: CGPoint(x: rect.maxX, y: rect.minY), panel: panel)
            await pause()
            try check(!view.showsPet, "\(name) hides the whole pet on the live panel")
            try await screenshot(panel: panel, output: output.appendingPathComponent("selection-\(name).png"), permission: permission)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(escape)
            do { _ = try await task.value; throw Failure(description: "Escape returned an image") }
            catch OCRService.OCRError.cancelled {}
            try check(controller.panels.isEmpty, "Escape removes every panel")
        }
        // Use two adjacent synthetic surfaces on the single physical display.
        // This tests session/panel routing, not physical multi-monitor capture.
        let half = frame.width / 2
        let leftFrame = CGRect(x: frame.minX, y: frame.minY, width: half, height: frame.height)
        let rightFrame = CGRect(x: frame.minX + half, y: frame.minY, width: half, height: frame.height)
        let screens = [
            CapturedScreen(displayID: 1, frame: leftFrame,
                           image: colorImage(width: Int(half), height: Int(frame.height), color: .white)),
            CapturedScreen(displayID: 2, frame: rightFrame,
                           image: colorImage(width: Int(half * 2), height: Int(frame.height * 2), color: .white))
        ]
        let multi = Task { @MainActor in try await controller.select(screens: screens, skin: .cat) }
        await pause()
        try check(controller.panels.count == 2, "One panel is created per frozen surface")
        let firstPanel = controller.panels[0]
        let secondPanel = controller.panels[1]
        let dragStart = CGPoint(x: leftFrame.minX + 100, y: leftFrame.maxY - 150)
        let dragEnd = CGPoint(x: rightFrame.minX + 100, y: rightFrame.maxY - 350)
        send(.leftMouseDown, point: dragStart, panel: firstPanel)
        // A captured drag remains delivered to the press window across screens.
        send(.leftMouseDragged, point: dragEnd, panel: firstPanel)
        let firstView = firstPanel.contentView as! CaptureSelectionView
        let secondView = secondPanel.contentView as! CaptureSelectionView
        try check(firstView.showsPet && !secondView.showsPet, "Pet stays wholly on the geometric top-left display")
        try check(firstView.readout == nil && secondView.readout != nil, "Readout follows pointer onto second display")
        send(.leftMouseUp, point: dragEnd, panel: firstPanel)
        let multiImage = try await multi.value
        try check(multiImage.width == Int((dragEnd.x - dragStart.x) * 2), "Cross-screen native routing uses largest pixel density")
        let topology = Task { @MainActor in try await controller.select(screens: [captured], skin: .cat) }
        await pause()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        do { _ = try await topology.value; throw Failure(description: "Screen topology change returned an image") }
        catch OCRService.OCRError.cancelled {}
        try check(controller.panels.isEmpty, "Screen parameter changes cancel and release panels")
        let cancelledTask = Task { @MainActor in try await controller.select(screens: [captured], skin: .cat) }
        await pause()
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; throw Failure(description: "Task cancellation returned an image") }
        catch OCRService.OCRError.cancelled {}
        try check(controller.panels.isEmpty, "Task cancellation closes every panel")
        try await pipeline(screen: captured, selection: selection, output: output, permission: permission)
        if permission {
            let real = try await ScreenFrameCapture.capture()
            try check(real.count == NSScreen.screens.count, "Real ScreenCaptureKit samples each connected screen")
            // Do not write unrelated desktop contents to evidence.
            print("Actual ScreenCaptureKit desktop sampling passed: \(real.count) display(s)")
        } else {
            do { _ = try await ScreenFrameCapture.capture(); throw Failure(description: "Unauthorized capture returned pixels") }
            catch OCRService.OCRError.permissionDenied {}
            print("NOT VERIFIED: actual desktop sampling and ScreenCaptureKit WindowServer screenshots require screen recording permission.")
            print("selection-*.png are NSView bitmap renders of live native panels, not desktop screenshots.")
        }
    }

    @MainActor static func pipeline(screen: CapturedScreen, selection: CGRect, output: URL, permission: Bool) async throws {
        URLProtocol.registerClass(CaptureTranslationFixture.self)
        defer { URLProtocol.unregisterClass(CaptureTranslationFixture.self) }
        let controller = CaptureSelectionController()
        var captures = 0
        let delegate = AppDelegate(captureOCR: { languages in
            captures += 1
            let image = try await controller.select(screens: [screen], skin: .cat)
            try save(image, to: output.appendingPathComponent("pipeline-ocr-input.png"))
            return try await OCRService.recognize(image: image, languages: languages)
        })
        delegate.settings.provider = .openai
        delegate.settings.baseURL = "https://capture-fixture.invalid/v1"
        delegate.settings.model = "fixture"
        delegate.settings.apiKey = "fixture-only"
        delegate.settings.targetLanguage = "zh-Hans"
        delegate.settings.sourceLanguage = "auto"
        delegate.settings.overlaySeconds = 30
        delegate.settings.showOriginal = false
        delegate.settings.showFloatingBall = false
        delegate.settings.autoWatchClipboard = false
        let overlay: OverlayController = member(delegate, "overlay")
        let model: OverlayModel = member(overlay, "model")

        for translate in [false, true] {
            if translate { delegate.runOCRTranslateNow() } else { delegate.runOCRNow() }
            await pause()
            let panel = controller.panels[0]
            let before = captures
            delegate.runOCRNow()
            delegate.runOCRTranslateNow()
            try check(delegate.isOCRInProgress && captures == before, "Reentry cannot launch another selection")
            send(.leftMouseDown, point: CGPoint(x: selection.minX, y: selection.maxY), panel: panel)
            send(.leftMouseDragged, point: CGPoint(x: selection.maxX, y: selection.minY), panel: panel)
            await pause()
            send(.leftMouseUp, point: CGPoint(x: selection.maxX, y: selection.minY), panel: panel)
            for _ in 0..<40 {
                if !delegate.isOCRInProgress { break }
                await pause(0.1)
            }
            try check(!delegate.isOCRInProgress, "OCR and translation finish and release lock")
            if translate {
                try check(model.translated == "清晰的文字，干净的截图。" && delegate.lastStatus == "已翻译",
                          "OCR translation presents the fixture translation after real Vision")
            } else {
                try check(model.translated.contains("Clear text") && delegate.lastStatus == "已识别",
                          "Plain OCR presents recognized original")
                try check(CaptureTranslationFixture.requests == 0, "Plain OCR makes no translation request")
            }
            let window: NSPanel? = member(overlay, "window")
            if let window {
                try await screenshot(panel: window, output: output.appendingPathComponent(translate ? "subtitle-translated.png" : "subtitle-original.png"),
                                     permission: permission)
            }
        }
        delegate.runOCRTranslateNow()
        await pause()
        let requestCount = CaptureTranslationFixture.requests
        let panel = controller.panels[0]
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        await pause()
        try check(delegate.lastStatus == "已取消" && !delegate.isOCRInProgress, "Esc maps to cancellation and releases lock")
        let window: NSPanel? = member(overlay, "window")
        try check(window?.isVisible != true && !model.isError, "Esc shows neither error nor subtitle")
        try check(CaptureTranslationFixture.requests == requestCount, "Esc makes no translation request")
        print("Passed: native selection events -> real Vision -> original/translated subtitles; Esc silent; reentry launches no second capture")
        overlay.hide()
    }

    @MainActor static func send(_ type: NSEvent.EventType, point: CGPoint, panel: NSPanel) {
        panel.makeKey()
        panel.makeFirstResponder(panel.contentView)
        let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point),
                                       modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        NSApp.sendEvent(event)
    }

    @MainActor static func screenshot(panel: NSPanel, output: URL, permission: Bool) async throws {
        if permission, #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
                throw Failure(description: "Cannot find native test panel in ScreenCaptureKit")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(panel.frame.width * 2)
            config.height = Int(panel.frame.height * 2)
            config.showsCursor = false
            config.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try save(image, to: output)
        } else {
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(description: "Cannot render native panel view")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw Failure(description: "Cannot read panel render") }
            try save(image, to: output)
        }
    }

    @MainActor static func fixture(size: CGSize, selection: CGRect, scale: CGFloat) throws -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Cannot create frozen test content")
        }
        context.scaleBy(x: scale, y: scale)
        let old = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = old }
        NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        NSColor.white.setFill()
        NSBezierPath(rect: selection).fill()
        let title = "Clear text, clean capture."
        (title as NSString).draw(at: CGPoint(x: selection.minX + 36, y: selection.maxY - 84),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium),
                                                 .foregroundColor: NSColor.black])
        ("Only source pixels reach OCR." as NSString).draw(
            at: CGPoint(x: selection.minX + 36, y: selection.maxY - 134),
            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray])
        guard let image = context.makeImage() else { throw Failure(description: "Cannot freeze test content") }
        return image
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func colorImage(width: Int, height: Int, color: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func save(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Cannot encode PNG")
        }
        try data.write(to: url)
    }
}
