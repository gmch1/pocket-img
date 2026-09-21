import AppKit
import Carbon.HIToolbox
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
    private var preparationTimeoutTask: Task<Void, Never>?
    private var focusRecoveryTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var inputGuard: CaptureInputGuard?
    private var sessionID = UUID()
    private let escapeHotKey = GlobalHotKey(identifier: 2)
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
        let sessionID = UUID()
        self.sessionID = sessionID
        let inputGuard = CaptureInputGuard()
        do {
            try inputGuard.start { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.failCapture(CaptureError.inputProtectionUnavailable)
            }
            self.inputGuard = inputGuard
        } catch {
            failCapture(error)
            return
        }
        installKeyMonitor()
        installEscapeHotKey()
        // Preserve the source app’s focus and hover state until every display is captured.
        preparationTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, !self.finished, self.sessionID == sessionID else { return }
            self.failCapture(CaptureError.preparationTimedOut)
        }

        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let displays = try await captureDisplays()
                try Task.checkCancellation()
                guard !displays.isEmpty else {
                    throw CaptureError.noDisplays
                }
                if CaptureInputGuard.pressedButtons != 0 {
                    DiagnosticLog.record("capture waiting for an active mouse gesture to finish")
                }
                while CaptureInputGuard.pressedButtons != 0 {
                    try await Task.sleep(for: .milliseconds(16))
                }
                try Task.checkCancellation()
                guard !finished, self.sessionID == sessionID else { return }
                guard !inputGuard.protectionLost else {
                    throw CaptureError.inputProtectionUnavailable
                }
                showCaptureWindows(
                    displays,
                    annotationStyle: annotationStyle,
                    uploadEnabled: uploadEnabled,
                    language: language,
                    onAnnotationStyleChange: onAnnotationStyleChange
                )
                inputGuard.stop()
                self.inputGuard = nil
                preparationTimeoutTask?.cancel()
                preparationTimeoutTask = nil
                captureTask = nil
                DiagnosticLog.record("capture overlays ready displays=\(displays.count)")
            } catch is CancellationError {
                // Cancellation already tears down the capture session and callbacks.
            } catch {
                guard !Task.isCancelled, self.sessionID == sessionID else { return }
                failCapture(error)
            }
        }
    }

    private func showCaptureWindows(
        _ displays: [CapturedDisplay],
        annotationStyle: AnnotationStylePreferences,
        uploadEnabled: Bool,
        language: AppLanguage,
        onAnnotationStyleChange: @escaping (AnnotationStylePreferences) -> Void
    ) {
        windows = displays.map { display in
            let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: display.screen.frame.size))
            view.annotationStyle = annotationStyle
            view.uploadEnabled = uploadEnabled
            view.language = language
            view.onAnnotationStyleChange = onAnnotationStyleChange
            view.screenshot = display.image
            view.delegate = self
            view.onCopySampledColor = { [weak self] in
                guard let self else { return false }
                return Self.copySampledColor(
                    at: NSEvent.mouseLocation, in: self.windows, to: .general
                )
            }

            return makeWindow(for: display.screen, contentView: view)
        }
        // Only show windows and claim focus after the screenshots are frozen.
        activateWindows()
    }

    @discardableResult
    static func copySampledColor(
        at screenPoint: CGPoint,
        in windows: [NSWindow],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard let window = windows.first(where: {
            $0.isVisible && $0.frame.contains(screenPoint)
        }), let overlay = window.contentView as? CaptureOverlayView,
              overlay.isSelecting else { return false }
        overlay.initializeHoverPoint(atScreenPoint: screenPoint)
        return overlay.copySampledColor(to: pasteboard)
    }

    private func makeWindow(
        for screen: NSScreen,
        contentView: NSView
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
        window.backgroundColor = .black
        window.isOpaque = true
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
        focusRecoveryTask?.cancel()
        applyCaptureFocus(includeHidden: includeHidden)
        scheduleFocusVerification()
    }

    private func applyCaptureFocus(includeHidden: Bool) {
        let application = NSApplication.shared
        let candidates = includeHidden ? windows : windows.filter(\.isVisible)
        guard !candidates.isEmpty else { return }
        for window in candidates {
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let preferred = candidates.first { $0.frame.contains(pointer) } ?? candidates.first
        application.activate(ignoringOtherApps: true)
        preferred?.makeKeyAndOrderFront(nil)
        preferred?.makeFirstResponder(preferred?.contentView)
        if let overlay = preferred?.contentView as? CaptureOverlayView {
            overlay.initializeHoverPoint(atScreenPoint: pointer)
        }
    }

    private var hasCaptureFocus: Bool {
        let application = NSApplication.shared
        guard application.isActive, let keyWindow = application.keyWindow else { return false }
        return windows.contains(where: { $0 === keyWindow })
    }

    private func scheduleFocusVerification() {
        focusRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let retryDelaysMilliseconds: [Int64] = [0, 25, 75, 150, 300]
            for (attempt, delay) in retryDelaysMilliseconds.enumerated() {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard !Task.isCancelled, !finished, !windows.isEmpty else { return }
                if hasCaptureFocus {
                    scheduleCaptureCursorSynchronization()
                    if attempt > 0 {
                        DiagnosticLog.record("capture focus restored attempt=\(attempt)")
                    }
                    return
                }
                let keyWindow = NSApplication.shared.keyWindow
                let captureWindowIsKey = keyWindow.map { keyWindow in
                    windows.contains(where: { $0 === keyWindow })
                } ?? false
                DiagnosticLog.record(
                    "capture focus retry attempt=\(attempt + 1) " +
                    "appActive=\(NSApplication.shared.isActive) " +
                    "captureWindowIsKey=\(captureWindowIsKey)"
                )
                applyCaptureFocus(includeHidden: false)
            }
            if !hasCaptureFocus {
                DiagnosticLog.record("capture focus unavailable after retries")
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !finished,
              let window = notification.object as? CaptureWindow,
              windows.contains(where: { $0 === window }) else {
            return
        }
        scheduleCaptureCursorSynchronization()
    }

    private func scheduleCaptureCursorSynchronization() {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished, !self.windows.isEmpty else { return }
                guard self.hasCaptureFocus else {
                    DiagnosticLog.record("capture cursor sync skipped without key-window focus")
                    return
                }
                if !self.synchronizeCaptureCursor() {
                    DiagnosticLog.record("capture cursor sync skipped outside active key window")
                }
            }
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

    @discardableResult
    private func synchronizeCaptureCursor() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let window = NSApplication.shared.keyWindow as? CaptureWindow,
              windows.contains(where: { $0 === window }),
              window.isVisible,
              window.frame.contains(pointer) else {
            return false
        }
        if let overlay = window.contentView as? CaptureOverlayView {
            return overlay.synchronizeCursor(atScreenPoint: pointer)
        }
        return false
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

    private func installEscapeHotKey() {
        do {
            try escapeHotKey.register(
                HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, keyLabel: "Escape")
            ) { [weak self] in
                guard let self, !self.finished else { return }
                // Let the Carbon callback unwind before unregistering its handler.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.cancel()
                }
            }
        } catch {
            DiagnosticLog.record(error, phase: "register capture escape hotkey")
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
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = nil
        inputGuard?.stop()
        inputGuard = nil
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        escapeHotKey.unregister()
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
        NSCursor.arrow.set()

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
        var captured: [CapturedDisplay] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: []
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
    case inputProtectionUnavailable
    case preparationTimedOut

    var errorDescription: String? {
        localizedMessage(language: .system)
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch self {
        case .noDisplays:
            return L10n.text("error.capture.no_displays", language: language)
        case .imageEncodingFailed:
            return L10n.text("error.capture.encoding_failed", language: language)
        case .inputProtectionUnavailable:
            return L10n.text("error.capture.input_protection", language: language)
        case .preparationTimedOut:
            return L10n.text("error.capture.preparation_timeout", language: language)
        }
    }
}
