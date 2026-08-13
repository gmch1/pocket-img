import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: NSObject, CaptureOverlayViewDelegate {
    private struct CapturedDisplay {
        let screen: NSScreen
        let image: CGImage
    }

    private var windows: [CaptureWindow] = []
    private var onFinish: ((UploadPayload, CaptureAction) -> Void)?
    private var onCancel: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var finished = false

    func begin(
        onFinish: @escaping (UploadPayload, CaptureAction) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        cancel(notify: false)
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onError = onError
        finished = false

        let displays = try await captureDisplays()
        guard !displays.isEmpty else {
            throw CaptureError.noDisplays
        }

        windows = displays.map { display in
            let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: display.screen.frame.size))
            view.screenshot = display.image
            view.delegate = self

            let window = CaptureWindow(
                contentRect: display.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: display.screen
            )
            window.contentView = view
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.setFrame(display.screen.frame, display: true)
            return window
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let preferred = windows.first { $0.frame.contains(pointer) } ?? windows.first
        preferred?.makeKeyAndOrderFront(nil)
        preferred?.makeFirstResponder(preferred?.contentView)
    }

    func cancel(notify: Bool = true) {
        guard !finished || !windows.isEmpty else { return }
        finished = true
        closeWindows()
        if notify { onCancel?() }
        onFinish = nil
        onCancel = nil
        onError = nil
    }

    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView) {
        for window in windows where window.contentView !== overlay {
            (window.contentView as? CaptureOverlayView)?.screenshot = nil
            window.orderOut(nil)
        }
        overlay.window?.makeKeyAndOrderFront(nil)
        overlay.window?.makeFirstResponder(overlay)
    }

    func captureOverlayDidCancel(_ overlay: CaptureOverlayView) {
        cancel()
    }

    func captureOverlay(
        _ overlay: CaptureOverlayView,
        didFinish payload: UploadPayload,
        action: CaptureAction
    ) {
        guard !finished else { return }
        finished = true
        closeWindows()
        let completion = onFinish
        onFinish = nil
        onCancel = nil
        onError = nil
        completion?(payload, action)
    }

    func captureOverlay(_ overlay: CaptureOverlayView, didFailWith error: Error) {
        guard !finished else { return }
        finished = true
        closeWindows()
        let completion = onError
        onFinish = nil
        onCancel = nil
        onError = nil
        completion?(error)
    }

    private func closeWindows() {
        let dismissedWindows = windows
        windows.removeAll()

        for window in dismissedWindows {
            (window.contentView as? CaptureOverlayView)?.delegate = nil
            window.orderOut(nil)
        }

        // The delegate callback originates from a toolbar mouse event owned by the
        // capture view. Releasing that view and its window synchronously can tear
        // down the final AppKit window while the event is still being dispatched.
        // Wait until the callback stack has unwound before releasing the windows.
        Task { @MainActor in
            await Task.yield()
            for window in dismissedWindows {
                window.contentView = nil
                window.close()
            }
        }
    }

    private func captureDisplays() async throws -> [CapturedDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        var captured: [CapturedDisplay] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            captured.append(CapturedDisplay(screen: screen, image: image))
        }
        return captured
    }
}

final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

enum CaptureError: LocalizedError {
    case noDisplays
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "没有找到可截取的显示器。"
        case .imageEncodingFailed:
            return "无法生成截图文件。"
        }
    }
}
