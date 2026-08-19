import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: NSObject, CaptureOverlayViewDelegate, NSWindowDelegate {
    private struct CapturedDisplay {
        let screen: NSScreen
        let image: CGImage
    }

    private var windows: [CaptureWindow] = []
    private var captureTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var onFinish: ((UploadPayload, CaptureAction) -> Void)?
    private var onCancel: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var finished = false

    func begin(
        annotationStyle: AnnotationStylePreferences,
        uploadEnabled: Bool,
        language: AppLanguage,
        onAnnotationStyleChange: @escaping (AnnotationStylePreferences) -> Void,
        onFinish: @escaping (UploadPayload, CaptureAction) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        cancel(notify: false)
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onError = onError
        finished = false
        installKeyMonitor()
        showPreparationWindows()

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let displays = try await captureDisplays()
                try Task.checkCancellation()
                guard !displays.isEmpty else {
                    throw CaptureError.noDisplays
                }
                if NSEvent.pressedMouseButtons != 0 {
                    DiagnosticLog.record("capture waiting for an active mouse gesture to finish")
                }
                while NSEvent.pressedMouseButtons != 0 {
                    try await Task.sleep(for: .milliseconds(16))
                }
                try Task.checkCancellation()
                guard !finished else { return }
                showCaptureWindows(
                    displays,
                    annotationStyle: annotationStyle,
                    uploadEnabled: uploadEnabled,
                    language: language,
                    onAnnotationStyleChange: onAnnotationStyleChange
                )
                captureTask = nil
                DiagnosticLog.record("capture overlays ready displays=\(displays.count)")
            } catch is CancellationError {
                // Cancellation already tears down the preparation windows and callbacks.
            } catch {
                failCapture(error)
            }
        }
    }

    private func showPreparationWindows() {
        windows = NSScreen.screens.map { screen in
            let view = CapturePreparationView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            ) { [weak self] in
                self?.cancel()
            }
            return makeWindow(for: screen, contentView: view, opaque: false)
        }
        DiagnosticLog.record("capture preparation windows shown count=\(windows.count)")
        activateWindows()
    }

    private func showCaptureWindows(
        _ displays: [CapturedDisplay],
        annotationStyle: AnnotationStylePreferences,
        uploadEnabled: Bool,
        language: AppLanguage,
        onAnnotationStyleChange: @escaping (AnnotationStylePreferences) -> Void
    ) {
        let preparationWindows = windows
        windows = displays.map { display in
            let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: display.screen.frame.size))
            view.annotationStyle = annotationStyle
            view.uploadEnabled = uploadEnabled
            view.language = language
            view.onAnnotationStyleChange = onAnnotationStyleChange
            view.screenshot = display.image
            view.delegate = self

            let window = preparationWindows.first {
                $0.screen?.displayID == display.screen.displayID
            } ?? makeWindow(for: display.screen, contentView: view, opaque: true)
            window.contentView = view
            window.backgroundColor = .black
            window.isOpaque = true
            window.setFrame(display.screen.frame, display: true)
            return window
        }

        let activeWindowIDs = Set(windows.map { ObjectIdentifier($0) })
        for window in preparationWindows
            where !activeWindowIDs.contains(ObjectIdentifier(window)) {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        activateWindows()
    }

    private func makeWindow(
        for screen: NSScreen,
        contentView: NSView,
        opaque: Bool
    ) -> CaptureWindow {
        let window = CaptureWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = contentView
        window.delegate = self
        window.backgroundColor = opaque ? .black : .clear
        window.isOpaque = opaque
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        return window
    }

    private func activateWindows(includeHidden: Bool = true) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let candidates = includeHidden ? windows : windows.filter(\.isVisible)
        for window in candidates {
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let preferred = candidates.first { $0.frame.contains(pointer) } ?? candidates.first
        preferred?.makeKeyAndOrderFront(nil)
        preferred?.makeFirstResponder(preferred?.contentView)
        if let overlay = preferred?.contentView as? CaptureOverlayView {
            overlay.initializeHoverPoint(atScreenPoint: pointer)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !finished else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.restoreCaptureFocusIfNeeded()
        }
    }

    private func restoreCaptureFocusIfNeeded() {
        guard !finished, !windows.isEmpty else { return }
        if let keyWindow = NSApplication.shared.keyWindow,
           windows.contains(where: { $0 === keyWindow }) {
            return
        }
        DiagnosticLog.record("capture focus lost; restoring overlay focus")
        activateWindows(includeHidden: false)
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.finished, event.keyCode == 53 else { return event }
                self.cancel()
                return nil
            }
        }
    }

    func cancel(notify: Bool = true) {
        guard !finished || !windows.isEmpty || captureTask != nil else { return }
        finished = true
        captureTask?.cancel()
        captureTask = nil
        closeWindows()
        let completion = onCancel
        clearCallbacks()
        if notify { completion?() }
    }

    private func failCapture(_ error: Error) {
        guard !finished else { return }
        finished = true
        captureTask?.cancel()
        captureTask = nil
        closeWindows()
        let completion = onError
        clearCallbacks()
        completion?(error)
    }

    private func clearCallbacks() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
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
        clearCallbacks()
        completion?(payload, action)
    }

    func captureOverlay(_ overlay: CaptureOverlayView, didFailWith error: Error) {
        guard !finished else { return }
        finished = true
        closeWindows()
        let completion = onError
        clearCallbacks()
        completion?(error)
    }

    private func closeWindows() {
        let dismissedWindows = windows
        windows.removeAll()

        for window in dismissedWindows {
            (window.contentView as? CaptureOverlayView)?.delegate = nil
            window.delegate = nil
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
        let captureWindowIDs = Set(windows.compactMap { window -> CGWindowID? in
            guard window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        let excludedWindows = content.windows.filter {
            captureWindowIDs.contains($0.windowID)
        }
        DiagnosticLog.record(
            "capture excluded overlay windows=\(excludedWindows.count)"
        )
        var captured: [CapturedDisplay] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: excludedWindows
            )
            let configuration = SCStreamConfiguration()
            let captureSize = CaptureGeometry.capturePixelSize(
                displayPointSize: CGSize(width: display.width, height: display.height),
                backingScaleFactor: screen.backingScaleFactor
            )
            configuration.width = Int(captureSize.width)
            configuration.height = Int(captureSize.height)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false
            DiagnosticLog.record(
                "capture display points=\(display.width)x\(display.height) " +
                "scale=\(screen.backingScaleFactor) " +
                "output=\(configuration.width)x\(configuration.height)"
            )
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            captured.append(CapturedDisplay(screen: screen, image: image))
        }
        return captured
    }
}

final class CapturePreparationView: NSView {
    private var onCancel: (() -> Void)?

    init(frame frameRect: NSRect, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
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

enum CaptureError: LocalizedError, AppLocalizedError {
    case noDisplays
    case imageEncodingFailed

    var errorDescription: String? {
        localizedMessage(language: .system)
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch self {
        case .noDisplays:
            return L10n.text("error.capture.no_displays", language: language)
        case .imageEncodingFailed:
            return L10n.text("error.capture.encoding_failed", language: language)
        }
    }
}
