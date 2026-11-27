import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The real drop target is System Settings. Only macOS can grant access.
@MainActor
final class ScreenRecordingGuide {
    private var panel: NSPanel?

    func show() {
        let appURL = Bundle.main.bundleURL
        let guide = PermissionCard(appURL: appURL)
        let window = panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 252),
                                      styleMask: [.titled, .closable, .utilityWindow],
                                      backing: .buffered, defer: false)
        window.title = "授予录屏权限"
        window.contentView = NSHostingView(rootView: guide)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let frame = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - window.frame.width - 16, y: frame.maxY - 48))
        }
        panel = window
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        window.orderFrontRegardless()
    }
}

private struct PermissionCard: View {
    let appURL: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("将应用拖入系统权限列表").font(.headline)
            Text("系统设置 → 隐私与安全性 → 录屏与系统录音（或「屏幕录制」）")
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable().frame(width: 36, height: 36)
                Text("拖动棱镜翻译 →")
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .onDrag { NSItemProvider(item: appURL as NSURL, typeIdentifier: UTType.fileURL.identifier) }
            Text("拖入后开启开关，并按系统提示退出重开。如果不能拖入，可点列表下方的「+」选择此应用。")
            Button("在 Finder 中显示此应用") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
        }
        .font(.callout).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
