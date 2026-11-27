import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

struct CapturedScreen {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage
    var surface: CaptureGeometry.Surface {
        CaptureGeometry.Surface(frame: frame, pixelWidth: image.width, pixelHeight: image.height)
    }
}

/// Only this boundary samples WindowServer. UI is excluded before any overlay
/// opens; the immutable images are shared by preview and the OCR crop.
enum ScreenFrameCapture {
    @MainActor static func capture() async throws -> [CapturedScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw OCRService.OCRError.permissionDenied }
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGFloat)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (number.uint32Value, screen.frame, screen.backingScaleFactor)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            var result: [CapturedScreen] = []
            for (id, frame, density) in screens {
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw OCRService.OCRError.cancelled // topology changed during sampling
                }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Int((frame.width * density).rounded())
                configuration.height = Int((frame.height * density).rounded())
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.scalesToFit = true
                let image: CGImage
                if #available(macOS 14.0, *) {
                    image = try await captureStill(filter: filter, configuration: configuration)
                } else {
                    image = try await FirstScreenFrame.capture(filter: filter, configuration: configuration)
                }
                try Task.checkCancellation()
                result.append(CapturedScreen(displayID: id, frame: frame, image: image))
            }
            guard !result.isEmpty else { throw OCRService.OCRError.captureFailed }
            return result
        } catch let error as NSError where error.domain == SCStreamErrorDomain
                    && error.code == SCStreamError.Code.userDeclined.rawValue {
            throw OCRService.OCRError.permissionDenied
        } catch is CancellationError {
            throw OCRService.OCRError.cancelled
        }
    }

    @available(macOS 14.0, *)
    private static func captureStill(filter: SCContentFilter,
                                     configuration: SCStreamConfiguration) async throws -> CGImage {
        let result = CaptureFrameResult()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                result.install(continuation)
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let error { result.finish(.failure(error)) }
                    else if let image { result.finish(.success(image)) }
                    else { result.finish(.failure(OCRService.OCRError.noImage)) }
                }
                result.scheduleTimeout()
            }
        }, onCancel: { result.finish(.failure(OCRService.OCRError.cancelled)) })
    }
}

/// A callback, cancellation or timeout may race. The first result wins, even
/// when cancellation arrives before the continuation is installed.
private final class CaptureFrameResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var outcome: Result<CGImage, Error>?
    private var timeout: DispatchWorkItem?

    func install(_ continuation: CheckedContinuation<CGImage, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func scheduleTimeout() {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(OCRService.OCRError.captureFailed))
        }
        timeout = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: item)
    }
}

/// macOS 13 fallback: copy a complete frame into an owned CGImage, then stop
/// and remove the stream output before returning. No deprecated CGWindow API.
private final class FirstScreenFrame: NSObject, SCStreamOutput, SCStreamDelegate {
    private let result = CaptureFrameResult()
    private let context = CIContext()

    static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let receiver = FirstScreenFrame()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "prism.capture.frame"))
        do {
            try await stream.startCapture()
            let image = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    receiver.result.install(continuation)
                    receiver.result.scheduleTimeout()
                }
            }, onCancel: { receiver.result.finish(.failure(OCRService.OCRError.cancelled)) })
            try await stream.stopCapture()
            try stream.removeStreamOutput(receiver, type: .screen)
            return image
        } catch {
            // stopCapture may already have been called/failed; never leave a
            // stream or its sample queue attached after an unsuccessful task.
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(receiver, type: .screen)
            throw error
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        result.finish(.failure(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pixels = CIImage(cvPixelBuffer: buffer)
        // createCGImage materializes a copy independent of the stream IOSurface.
        guard let image = context.createCGImage(pixels, from: pixels.extent) else {
            result.finish(.failure(OCRService.OCRError.noImage)); return
        }
        result.finish(.success(image))
    }
}
