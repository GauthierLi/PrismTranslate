import AppKit

/// A separate, test-owned regular application provides an actual foreign key
/// window and native full-screen Space. Only gesture input and OCR/HTTP are
/// fixtures; activation, panel ordering and Space membership use WindowServer.
@MainActor
enum BallInactiveApplicationTests {
    private static var peerWindow: NSWindow?
    private static var peerTimer: Timer?

    static func runForegroundPeer(statusURL: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let screen = NSScreen.main!
        let window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 4, dy: 4),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "PrismTranslate regression — foreground app"
        window.collectionBehavior = [.fullScreenPrimary]
        let label = NSTextField(labelWithString: "Another application is in the foreground.\nNative window / native full-screen Space")
        label.alignment = .center
        label.frame = CGRect(x: 20, y: 100, width: 480, height: 100)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        peerWindow = window
        app.activate(ignoringOtherApps: true)
        var requestedFullScreen = false
        peerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !requestedFullScreen,
                   FileManager.default.fileExists(atPath: statusURL.appendingPathExtension("fullscreen").path) {
                    requestedFullScreen = true
                    window.toggleFullScreen(nil)
                }
                let elevated = FileManager.default.fileExists(atPath: statusURL.appendingPathExtension("elevated").path)
                let level: NSWindow.Level = elevated ? .statusBar : .normal
                if window.level != level { window.level = level }
                let state: [String: Any] = [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "active": app.isActive,
                    "key": window.isKeyWindow,
                    "fullScreen": window.styleMask.contains(.fullScreen),
                    "windowNumber": window.windowNumber,
                    "elevated": elevated,
                    "level": window.level.rawValue
                ]
                if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                    try? data.write(to: statusURL, options: .atomic)
                }
            }
        }
        app.run()
    }

    static func run(ball: FloatingBallController, output: URL,
                    verifyAction: (BallQuickAction) throws -> Void) async throws {
        let peerBundle = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ForegroundPeer.app/Contents/MacOS/ForegroundPeer")
        let statusURL = output.appendingPathComponent("foreground-peer.json")
        try? FileManager.default.removeItem(at: statusURL)
        try? FileManager.default.removeItem(at: statusURL.appendingPathExtension("fullscreen"))
        try? FileManager.default.removeItem(at: statusURL.appendingPathExtension("elevated"))
        let previousApp = NSWorkspace.shared.frontmostApplication
        let peer = Process()
        peer.executableURL = peerBundle
        peer.arguments = ["--foreground-peer", statusURL.path]
        try peer.run()
        defer {
            // Reap this exact child before the test runner removes its bundle.
            if peer.isRunning { peer.terminate() }
            peer.waitUntilExit()
            previousApp?.activate(options: [])
        }
        let window: NSPanel = BallInteractionTests.member(ball, "window")
        let view: BallView = BallInteractionTests.member(ball, "ballView")
        let ring: BallSelectionController = BallInteractionTests.member(ball, "selection")
        let savedFrame = window.frame
        defer {
            ring.cancel()
            view.cancelGesture()
            window.setFrame(savedFrame, display: true)
        }

        func state() -> [String: Any] {
            guard let data = try? Data(contentsOf: statusURL),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return state
        }
        func awaitForeground(fullScreen: Bool, elevated: Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                let current = state()
                if current["active"] as? Bool == true,
                   current["key"] as? Bool == true,
                   current["fullScreen"] as? Bool == fullScreen,
                   current["elevated"] as? Bool == elevated,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processIdentifier,
                   !NSApp.isActive {
                    // Let activation cancellation observers and Space animation settle.
                    await BallInteractionTests.pause(fullScreen ? 1 : 0.3)
                    return
                }
                try BallInteractionTests.check(peer.isRunning, "Foreground peer must remain running")
                await BallInteractionTests.pause(0.1)
            }
            throw BallInteractionTests.Failure(description: "Cannot establish foreign foreground app (fullScreen=\(fullScreen)): \(state())")
        }
        func pointer(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
        func onScreen(_ panel: NSWindow) -> Bool {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains {
                ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber
                    && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
            }
        }
        func log(_ context: String, panel: NSWindow) {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] ?? []
            let peerNumber = state()["windowNumber"] as? Int
            let panelIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
            let peerIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == peerNumber }
            print("Inactive regression [\(context)]: appActive=\(NSApp.isActive), foreignPID=\(peer.processIdentifier), "
                  + "peerFullScreen=\(state()["fullScreen"] ?? false), panelVisible=\(panel.isVisible), "
                  + "onScreen=\(onScreen(panel)), activeSpace=\(panel.isOnActiveSpace), "
                  + "alpha=\(panel.alphaValue), frame=\(panel.frame), "
                  + "panelStack=\(String(describing: panelIndex)), peerStack=\(String(describing: peerIndex)), "
                  + "layer=\(panelIndex.map { windows[$0][kCGWindowLayer as String] ?? -1 } ?? -1), "
                  + "ballLevel=\(window.level.rawValue), peerLevel=\(state()["level"] ?? -1)")
        }
        func isAbovePeer(_ panel: NSWindow) -> Bool {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] ?? []
            guard let peerNumber = state()["windowNumber"] as? Int,
                  let panelIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }),
                  let peerIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == peerNumber }) else { return false }
            return panelIndex < peerIndex
        }

        var failures: [String] = []
        for (fullScreen, elevated) in [(false, false), (false, true), (true, false), (true, true)] {
            let scene = (fullScreen ? "full-screen Space" : "ordinary foreign app") + (elevated ? " / elevated key window" : " / normal key window")
            if fullScreen { try Data().write(to: statusURL.appendingPathExtension("fullscreen")) }
            let elevationURL = statusURL.appendingPathExtension("elevated")
            if elevated {
                try Data().write(to: elevationURL)
            } else {
                try? FileManager.default.removeItem(at: elevationURL)
            }
            try await awaitForeground(fullScreen: fullScreen, elevated: elevated)
            let screen = NSScreen.main!
            let press = CGPoint(x: screen.visibleFrame.maxX - 29, y: screen.visibleFrame.midY)
            window.setFrameOrigin(CGPoint(x: press.x - BallView.ballCenter.x, y: press.y - BallView.ballCenter.y))
            ball.show()
            for action in BallQuickAction.allCases {
                pointer(.leftMouseDown, at: press)
                await BallInteractionTests.pause(0.65)
                let gesture: BallGesture.State = BallInteractionTests.member(view, "gesture")
                let panel: NSPanel = BallInteractionTests.member(ring, "panel")
                log("\(scene) / \(action)", panel: panel)
                let isOnScreen = onScreen(panel)
                if gesture.phase != .selecting || !ring.isVisible || !isOnScreen
                    || !panel.isOnActiveSpace || !screen.visibleFrame.contains(panel.frame)
                    || panel.alphaValue < 0.99 || NSApp.isActive || !isAbovePeer(panel) {
                    failures.append("\(scene) / \(action): completed hold must show ring above the foreign window on the current screen without activation")
                    ring.cancel()
                    view.cancelGesture()
                    continue
                }
                // Keep the point outside the original press dead zone after edge shifting.
                let point: CGPoint
                switch action {
                case .ocr: point = CGPoint(x: ring.center.x - 43, y: ring.center.y + 43)
                case .ocrTranslate: point = CGPoint(x: ring.center.x + 10, y: ring.center.y + 67)
                case .clipboardWatch: point = CGPoint(x: ring.center.x, y: ring.center.y - 58)
                }
                pointer(.leftMouseDragged, at: point)
                try BallInteractionTests.check(ring.selected == action, "\(scene): \(action) must be selectable")
                await BallInteractionTests.pause(0.65)
                let bubble: NSPanel = BallInteractionTests.member(ring, "bubblePanel")
                log("\(scene) / \(action) bubble", panel: bubble)
                try BallInteractionTests.check(ring.bubbleIsVisible && onScreen(bubble)
                                               && bubble.isOnActiveSpace && screen.visibleFrame.contains(bubble.frame)
                                               && isAbovePeer(bubble),
                                               "\(scene): delayed bubble must be on screen")
                try BallInteractionTests.check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processIdentifier,
                                               "Ring and bubble must retain the foreign app's focus")
                try BallInteractionTests.captureScene(ball: window, ring: ring,
                                                      to: output.appendingPathComponent("inactive-\(fullScreen ? "fullscreen" : "ordinary")-\(elevated ? "elevated" : "normal")-\(action).png"))
                pointer(.leftMouseUp, at: point)
                await BallInteractionTests.pause(0.65)
                try BallInteractionTests.check(!ring.isVisible && !ring.bubbleIsVisible,
                                               "Action must run after both panels hide")
                try verifyAction(action)
                print("Passed inactive action [\(scene)]: \(action)")
            }
        }
        try BallInteractionTests.check(failures.isEmpty, failures.joined(separator: "; "))
        print("Passed: inactive application, native foreign full-screen Space, completed hold, WindowServer visibility, bubbles and all 3 actions.")
    }
}
