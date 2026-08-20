import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

enum GIFRecordingState: Equatable, Sendable {
    case idle
    case preparing
    case selecting
    case countdown(Int)
    case recording
    case stopping
    case encoding
}

struct GIFRecordingMetrics: Sendable {
    let sourcePointSize: CGSize
    let recordingPixelSize: CGSize
    let outputPixelSize: CGSize
    let frameRate: Int
    let movieBytes: Int64
    let gifBytes: Int64
    let frames: GIFFrameStatistics
    let encodingAttempts: [GIFEncodingAttempt]
    let encodingWallTime: TimeInterval
    let encodingCPUTime: TimeInterval
    let exceedsMaximumBytes: Bool
}

struct GIFRecordingResult: Sendable {
    let sessionID: UUID
    let data: Data
    let fileURL: URL
    let duration: TimeInterval
    let payload: UploadPayload
    let metrics: GIFRecordingMetrics
}

@MainActor
final class GIFRecordingCoordinator: NSObject, NSWindowDelegate {
    private enum Phase {
        case idle
        case preparing
        case selecting
        case countdown
        case starting
        case recording
        case stopping
        case encoding
    }

    private struct FrozenDisplay {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let image: CGImage
    }

    private struct SelectionContext {
        let region: GIFCaptureRegion
        let screenFrame: CGRect
        let screenVisibleFrame: CGRect
    }

    private static let countdownSeconds = 3
    private static let maximumRecordingDuration: TimeInterval = 30

    private var phase: Phase = .idle
    private(set) var state: GIFRecordingState = .idle
    private var selectionWindows: [GIFRecordingWindow] = []
    private var countdownWindow: NSPanel?
    private var recordingHUDWindow: NSPanel?
    private var captureTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var maximumDurationTask: Task<Void, Never>?
    private var hudUpdateTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var focusRecoveryTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private let escapeHotKey = GlobalHotKey(identifier: 4)
    private var recorder: ScreenStreamRecorder?
    private var encoder: GIFEncoder?
    private var sessionID: UUID?
    private var selectionContext: SelectionContext?
    private var recordingStartedAt: Date?
    private var previouslyActiveApplication: NSRunningApplication?
    private var previouslyActiveCursor: NSCursor?
    private var onStateChange: ((GIFRecordingState) -> Void)?
    private var onFinish: ((GIFRecordingResult) -> Void)?
    private var onCancel: (() -> Void)?
    private var onError: ((Error) -> Void)?
    private var language: AppLanguage = .system
    private var finished = true

    func begin(
        language: AppLanguage,
        onStateChange: @escaping (GIFRecordingState) -> Void,
        onFinish: @escaping (GIFRecordingResult) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        cancel(notify: false)

        let sessionID = GIFExperimentLogger.makeSessionID()
        self.sessionID = sessionID
        self.language = language
        self.onStateChange = onStateChange
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onError = onError
        self.previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        self.previouslyActiveCursor = NSCursor.current
        self.recorder = makeRecorder(for: sessionID)
        self.encoder = GIFEncoder()
        finished = false
        phase = .preparing
        publish(.preparing)
        installKeyMonitor()
        installEscapeHotKey()
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
                    DiagnosticLog.record("gif selection waiting for an active mouse gesture")
                }
                while NSEvent.pressedMouseButtons != 0 {
                    try await Task.sleep(for: .milliseconds(16))
                }
                try Task.checkCancellation()
                guard isCurrent(sessionID), phase == .preparing else { return }
                showSelectionWindows(displays)
                captureTask = nil
                phase = .selecting
                publish(.selecting)
                DiagnosticLog.record("gif selection overlays ready displays=\(displays.count)")
            } catch is CancellationError {
                // The cancellation path owns teardown and callback delivery.
            } catch {
                GIFExperimentLogger.recordError(
                    sessionID: sessionID,
                    stage: .selection,
                    error: error
                )
                fail(error)
            }
        }
    }

    /// Stops an active recording and starts GIF encoding. Calling this method in
    /// any other state is intentionally a no-op, so the global F2 handler can
    /// safely forward repeated key presses here.
    func stopRecording() {
        guard !finished,
              phase == .recording,
              let sessionID,
              let recorder,
              let encoder,
              let selectionContext else {
            return
        }

        phase = .stopping
        publish(.stopping)
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        hudUpdateTask?.cancel()
        hudUpdateTask = nil
        closeRecordingHUD()

        processingTask = Task { [weak self] in
            guard let self else { return }
            let movie: GIFMovieRecording
            do {
                movie = try await recorder.stop()
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(sessionID) else { return }
                fail(error)
                return
            }

            guard isCurrent(sessionID), phase == .stopping else {
                try? FileManager.default.removeItem(at: movie.info.movieURL)
                return
            }
            phase = .encoding
            publish(.encoding)

            let encoding: GIFEncodingResult
            do {
                encoding = try await encoder.encode(movie: movie, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(sessionID) else { return }
                fail(error)
                return
            }

            guard isCurrent(sessionID), phase == .encoding else {
                try? FileManager.default.removeItem(at: encoding.fileURL)
                return
            }
            let payload = UploadPayload(
                data: encoding.data,
                fileName: encoding.fileURL.lastPathComponent,
                contentType: "image/gif",
                displaySize: encoding.outputPixelSize
            )
            let metrics = GIFRecordingMetrics(
                sourcePointSize: selectionContext.region.sourceRect.size,
                recordingPixelSize: movie.info.outputPixelSize,
                outputPixelSize: encoding.outputPixelSize,
                frameRate: encoding.frameRate,
                movieBytes: movie.movieBytes,
                gifBytes: encoding.gifBytes,
                frames: movie.frames,
                encodingAttempts: encoding.attempts,
                encodingWallTime: encoding.encodingWallTime,
                encodingCPUTime: encoding.encodingCPUTime,
                exceedsMaximumBytes: encoding.exceedsMaximumBytes
            )
            complete(GIFRecordingResult(
                sessionID: sessionID,
                data: encoding.data,
                fileURL: encoding.fileURL,
                duration: encoding.duration,
                payload: payload,
                metrics: metrics
            ))
        }
    }

    func cancel(notify: Bool = true) {
        guard !finished || phase != .idle || !selectionWindows.isEmpty else { return }
        finished = true
        phase = .idle
        cancelTasks()
        closeAllWindows()
        restorePreviouslyActiveApplication()

        let recorder = self.recorder
        self.recorder = nil
        self.encoder = nil
        let completion = onCancel
        publish(.idle)
        clearCallbacks()
        if let recorder {
            Task {
                await recorder.cancel()
            }
        }
        if notify {
            completion?()
        }
    }

    private func makeRecorder(for sessionID: UUID) -> ScreenStreamRecorder {
        ScreenStreamRecorder { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(sessionID),
                      self.phase == .recording else {
                    return
                }
                self.fail(error)
            }
        }
    }

    private func showPreparationWindows() {
        selectionWindows = NSScreen.screens.map { screen in
            let view = GIFRecordingPreparationView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            ) { [weak self] in
                self?.cancel()
            }
            return makeSelectionWindow(for: screen, contentView: view, opaque: false)
        }
        DiagnosticLog.record("gif preparation windows shown count=\(selectionWindows.count)")
        activateSelectionWindows()
    }

    private func showSelectionWindows(_ displays: [FrozenDisplay]) {
        let preparationWindows = selectionWindows
        selectionWindows = displays.map { display in
            let view = GIFRegionSelectionView(
                frame: NSRect(origin: .zero, size: display.screen.frame.size)
            )
            view.displayID = display.displayID
            view.backingScaleFactor = display.screen.backingScaleFactor
            view.language = language
            view.screenshot = display.image
            view.delegate = self

            let window = preparationWindows.first {
                $0.screen?.gifDisplayID == display.displayID
            } ?? makeSelectionWindow(for: display.screen, contentView: view, opaque: true)
            window.contentView = view
            window.backgroundColor = .black
            window.isOpaque = true
            window.setFrame(display.screen.frame, display: true)
            return window
        }

        let activeWindowIDs = Set(selectionWindows.map { ObjectIdentifier($0) })
        for window in preparationWindows
            where !activeWindowIDs.contains(ObjectIdentifier(window)) {
            window.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        activateSelectionWindows()
    }

    private func makeSelectionWindow(
        for screen: NSScreen,
        contentView: NSView,
        opaque: Bool
    ) -> GIFRecordingWindow {
        let window = GIFRecordingWindow(
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

    private func activateSelectionWindows(includeHidden: Bool = true) {
        guard phase == .preparing || phase == .selecting else { return }
        focusRecoveryTask?.cancel()
        applySelectionFocus(includeHidden: includeHidden)
        scheduleFocusVerification()
    }

    private func applySelectionFocus(includeHidden: Bool) {
        let candidates = includeHidden
            ? selectionWindows
            : selectionWindows.filter(\.isVisible)
        guard !candidates.isEmpty else { return }
        for window in candidates {
            window.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let preferred = candidates.first { $0.frame.contains(pointer) } ?? candidates.first
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferred?.makeKeyAndOrderFront(nil)
        preferred?.makeFirstResponder(preferred?.contentView)
        if let selectionView = preferred?.contentView as? GIFRegionSelectionView {
            selectionView.initializeHoverPoint(atScreenPoint: pointer)
        }
    }

    private var hasSelectionFocus: Bool {
        guard NSApplication.shared.isActive,
              let keyWindow = NSApplication.shared.keyWindow else {
            return false
        }
        return selectionWindows.contains { $0 === keyWindow }
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
                guard !Task.isCancelled,
                      !finished,
                      phase == .preparing || phase == .selecting,
                      !selectionWindows.isEmpty else {
                    return
                }
                if hasSelectionFocus {
                    scheduleSelectionCursorSynchronization()
                    if attempt > 0 {
                        DiagnosticLog.record("gif selection focus restored attempt=\(attempt)")
                    }
                    return
                }
                DiagnosticLog.record("gif selection focus retry attempt=\(attempt + 1)")
                applySelectionFocus(includeHidden: false)
            }
            if !hasSelectionFocus {
                DiagnosticLog.record("gif selection focus unavailable after retries")
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !finished,
              phase == .preparing || phase == .selecting,
              let window = notification.object as? GIFRecordingWindow,
              selectionWindows.contains(where: { $0 === window }) else {
            return
        }
        scheduleSelectionCursorSynchronization()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !finished, phase == .preparing || phase == .selecting else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.restoreSelectionFocusIfNeeded()
        }
    }

    private func restoreSelectionFocusIfNeeded() {
        guard !finished,
              phase == .preparing || phase == .selecting,
              !selectionWindows.isEmpty else {
            return
        }
        if let keyWindow = NSApplication.shared.keyWindow,
           selectionWindows.contains(where: { $0 === keyWindow }) {
            return
        }
        DiagnosticLog.record("gif selection focus lost; restoring overlay focus")
        activateSelectionWindows(includeHidden: false)
    }

    private func scheduleSelectionCursorSynchronization() {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      !self.finished,
                      self.phase == .preparing || self.phase == .selecting,
                      !self.selectionWindows.isEmpty,
                      self.hasSelectionFocus else {
                    return
                }
                if !self.synchronizeSelectionCursor() {
                    DiagnosticLog.record("gif selection cursor sync skipped outside key window")
                }
            }
        }
    }

    @discardableResult
    private func synchronizeSelectionCursor() -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let window = NSApplication.shared.keyWindow as? GIFRecordingWindow,
              selectionWindows.contains(where: { $0 === window }),
              window.isVisible,
              window.frame.contains(pointer) else {
            return false
        }
        if let selectionView = window.contentView as? GIFRegionSelectionView {
            return selectionView.synchronizeCursor(atScreenPoint: pointer)
        }
        if let preparationView = window.contentView as? GIFRecordingPreparationView {
            window.invalidateCursorRects(for: preparationView)
            NSCursor.crosshair.set()
            return true
        }
        return false
    }

    private func installKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.cancel()
                    return nil
                }
                if self.phase == .selecting,
                   event.keyCode == UInt16(kVK_Return)
                    || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                    if self.confirmCurrentSelection() {
                        return nil
                    }
                }
                return event
            }
        }
    }

    private func installEscapeHotKey() {
        do {
            try escapeHotKey.register(
                HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0, keyLabel: "Escape")
            ) { [weak self] in
                guard let self, !self.finished else { return }
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.cancel()
                }
            }
        } catch {
            DiagnosticLog.record(error, phase: "register gif escape hotkey")
        }
    }

    @discardableResult
    private func confirmCurrentSelection() -> Bool {
        guard phase == .selecting else { return false }
        let preferredView = (NSApplication.shared.keyWindow?.contentView as? GIFRegionSelectionView)
            ?? selectionWindows.compactMap { $0.contentView as? GIFRegionSelectionView }
                .first(where: { $0.selection != nil })
        guard let preferredView else { return false }
        return preferredView.requestConfirmation()
    }

    private func beginCountdown(
        selection: CGRect,
        in view: GIFRegionSelectionView
    ) {
        guard !finished,
              phase == .selecting,
              let window = view.window,
              let displayID = view.displayID else {
            return
        }

        let sourceRect = selection.integral.intersection(view.bounds)
        guard sourceRect.width >= 8, sourceRect.height >= 8 else { return }
        let context = SelectionContext(
            region: GIFCaptureRegion(
                displayID: displayID,
                sourceRect: sourceRect,
                backingScaleFactor: view.backingScaleFactor
            ),
            screenFrame: CaptureGeometry.screenFrame(
                for: sourceRect,
                in: window.frame
            ),
            screenVisibleFrame: window.screen?.visibleFrame ?? window.frame
        )
        selectionContext = context
        phase = .countdown
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
        closeSelectionWindows()
        restorePreviouslyActiveApplication()
        showCountdownWindow(context: context, value: Self.countdownSeconds)
        publish(.countdown(Self.countdownSeconds))
        DiagnosticLog.record(
            "gif countdown started session=\(sessionID?.uuidString ?? "unknown") " +
            "display=\(displayID) rect=\(NSStringFromRect(sourceRect))"
        )

        guard let sessionID else { return }
        countdownTask = Task { [weak self] in
            guard let self else { return }
            for value in stride(from: Self.countdownSeconds, through: 1, by: -1) {
                guard isCurrent(sessionID), phase == .countdown else { return }
                updateCountdown(value)
                publish(.countdown(value))
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard isCurrent(sessionID), phase == .countdown else { return }
            countdownTask = nil
            await startRecording(context: context, sessionID: sessionID)
        }
    }

    private func startRecording(
        context: SelectionContext,
        sessionID: UUID
    ) async {
        guard isCurrent(sessionID),
              phase == .countdown,
              let recorder else {
            return
        }
        phase = .starting
        closeCountdownWindow()

        do {
            let info = try await recorder.start(region: context.region, sessionID: sessionID)
            guard isCurrent(sessionID), phase == .starting else {
                await recorder.cancel()
                return
            }
            recordingStartedAt = info.startedAt
            phase = .recording
            publish(.recording)
            showRecordingHUD(context: context)
            startRecordingTimers(sessionID: sessionID)
            DiagnosticLog.record(
                "gif recording started session=\(sessionID.uuidString) " +
                "output=\(Int(info.outputPixelSize.width))x\(Int(info.outputPixelSize.height))"
            )
        } catch is CancellationError {
            // The cancellation path owns teardown and callback delivery.
        } catch {
            guard isCurrent(sessionID) else { return }
            fail(error)
        }
    }

    private func startRecordingTimers(sessionID: UUID) {
        maximumDurationTask?.cancel()
        maximumDurationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.maximumRecordingDuration))
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(sessionID),
                  self.phase == .recording else {
                return
            }
            self.stopRecording()
        }

        hudUpdateTask?.cancel()
        hudUpdateTask = Task { @MainActor [weak self] in
            while let self,
                  self.isCurrent(sessionID),
                  self.phase == .recording {
                self.updateRecordingHUD()
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func showCountdownWindow(context: SelectionContext, value: Int) {
        closeCountdownWindow()
        let size = CGSize(width: 120, height: 120)
        let frame = centeredFrame(
            size: size,
            around: context.screenFrame,
            constrainedTo: context.screenVisibleFrame
        )
        let panel = makeAuxiliaryPanel(frame: frame, ignoresMouseEvents: true)
        panel.contentView = GIFCountdownView(frame: CGRect(origin: .zero, size: size), value: value)
        countdownWindow = panel
        panel.orderFrontRegardless()
    }

    private func updateCountdown(_ value: Int) {
        (countdownWindow?.contentView as? GIFCountdownView)?.value = value
    }

    private func showRecordingHUD(context: SelectionContext) {
        closeRecordingHUD()
        let size = CGSize(width: 250, height: 52)
        let frame = recordingHUDFrame(
            size: size,
            selectionFrame: context.screenFrame,
            visibleFrame: context.screenVisibleFrame
        )
        let panel = makeAuxiliaryPanel(frame: frame, ignoresMouseEvents: false)
        let view = GIFRecordingHUDView(
            frame: CGRect(origin: .zero, size: size),
            language: language
        ) { [weak self] in
            self?.stopRecording()
        }
        panel.contentView = view
        recordingHUDWindow = panel
        updateRecordingHUD()
        panel.orderFrontRegardless()
    }

    private func updateRecordingHUD() {
        let elapsed = min(
            max(0, Date().timeIntervalSince(recordingStartedAt ?? Date())),
            Self.maximumRecordingDuration
        )
        (recordingHUDWindow?.contentView as? GIFRecordingHUDView)?.update(elapsed: elapsed)
    }

    private func makeAuxiliaryPanel(
        frame: CGRect,
        ignoresMouseEvents: Bool
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.isReleasedWhenClosed = false
        // The recorder also excludes this application. `sharingType = .none`
        // provides a second guard for other system capture paths.
        panel.sharingType = .none
        return panel
    }

    private func centeredFrame(
        size: CGSize,
        around target: CGRect,
        constrainedTo visibleFrame: CGRect
    ) -> CGRect {
        let origin = CGPoint(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size).constrained(within: visibleFrame)
    }

    private func recordingHUDFrame(
        size: CGSize,
        selectionFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGRect {
        let gap: CGFloat = 10
        let centeredX = selectionFrame.midX - size.width / 2
        let aboveY = selectionFrame.maxY + gap
        let belowY = selectionFrame.minY - size.height - gap
        let preferredY: CGFloat
        if aboveY + size.height <= visibleFrame.maxY {
            preferredY = aboveY
        } else if belowY >= visibleFrame.minY {
            preferredY = belowY
        } else {
            preferredY = min(
                max(selectionFrame.maxY - size.height - gap, visibleFrame.minY),
                visibleFrame.maxY - size.height
            )
        }
        return CGRect(
            origin: CGPoint(x: centeredX, y: preferredY),
            size: size
        ).constrained(within: visibleFrame)
    }

    private func complete(_ result: GIFRecordingResult) {
        guard !finished else { return }
        finished = true
        phase = .idle
        cancelTasks()
        closeAllWindows()
        let completion = onFinish
        recorder = nil
        encoder = nil
        publish(.idle)
        clearCallbacks()
        DiagnosticLog.record(
            "gif recording finished bytes=\(result.data.count) " +
            "duration=\(String(format: "%.3f", result.duration))"
        )
        completion?(result)
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        phase = .idle
        cancelTasks()
        closeAllWindows()
        restorePreviouslyActiveApplication()
        let recorder = self.recorder
        self.recorder = nil
        encoder = nil
        let completion = onError
        publish(.idle)
        clearCallbacks()
        DiagnosticLog.record(error, phase: "gif recording")
        if let recorder {
            Task {
                await recorder.cancel()
            }
        }
        completion?(error)
    }

    private func publish(_ newState: GIFRecordingState) {
        state = newState
        onStateChange?(newState)
    }

    private func isCurrent(_ candidate: UUID) -> Bool {
        !finished && sessionID == candidate
    }

    private func cancelTasks() {
        captureTask?.cancel()
        captureTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        hudUpdateTask?.cancel()
        hudUpdateTask = nil
        processingTask?.cancel()
        processingTask = nil
        focusRecoveryTask?.cancel()
        focusRecoveryTask = nil
    }

    private func clearCallbacks() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        escapeHotKey.unregister()
        onStateChange = nil
        onFinish = nil
        onCancel = nil
        onError = nil
        sessionID = nil
        selectionContext = nil
        recordingStartedAt = nil
        previouslyActiveApplication = nil
        previouslyActiveCursor = nil
    }

    private func restorePreviouslyActiveApplication() {
        if let application = previouslyActiveApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !application.isTerminated {
            application.activate(options: [.activateIgnoringOtherApps])
        }
        // Cursor synchronization during selection deliberately uses `set()` to
        // replace a stale browser cursor. Restore the cursor that was active
        // before the overlay instead of forcing an arrow over the resumed app.
        previouslyActiveCursor?.set()
    }

    private func closeAllWindows() {
        closeSelectionWindows()
        closeCountdownWindow()
        closeRecordingHUD()
    }

    private func closeSelectionWindows() {
        let dismissedWindows = selectionWindows
        selectionWindows.removeAll()
        for window in dismissedWindows {
            (window.contentView as? GIFRegionSelectionView)?.delegate = nil
            window.delegate = nil
            window.orderOut(nil)
        }
        Task { @MainActor in
            await Task.yield()
            for window in dismissedWindows {
                window.contentView = nil
                window.close()
            }
        }
    }

    private func closeCountdownWindow() {
        let window = countdownWindow
        countdownWindow = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
    }

    private func closeRecordingHUD() {
        let window = recordingHUDWindow
        recordingHUDWindow = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
    }

    private func captureDisplays() async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let preparationWindowIDs = Set(selectionWindows.compactMap { window -> CGWindowID? in
            guard window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
        let excludedWindows = content.windows.filter {
            preparationWindowIDs.contains($0.windowID)
        }
        var displays: [FrozenDisplay] = []

        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let displayID = screen.gifDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
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
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            displays.append(FrozenDisplay(
                screen: screen,
                displayID: displayID,
                image: image
            ))
        }
        return displays
    }
}

extension GIFRecordingCoordinator: GIFRegionSelectionViewDelegate {
    func gifRegionSelectionViewDidStartSelection(_ view: GIFRegionSelectionView) {
        guard phase == .selecting else { return }
        for window in selectionWindows where window.contentView !== view {
            (window.contentView as? GIFRegionSelectionView)?.screenshot = nil
            window.orderOut(nil)
        }
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
    }

    func gifRegionSelectionViewDidCancel(_ view: GIFRegionSelectionView) {
        cancel()
    }

    func gifRegionSelectionView(
        _ view: GIFRegionSelectionView,
        didConfirm selection: CGRect
    ) {
        beginCountdown(selection: selection, in: view)
    }
}

@MainActor
protocol GIFRegionSelectionViewDelegate: AnyObject {
    func gifRegionSelectionViewDidStartSelection(_ view: GIFRegionSelectionView)
    func gifRegionSelectionViewDidCancel(_ view: GIFRegionSelectionView)
    func gifRegionSelectionView(_ view: GIFRegionSelectionView, didConfirm selection: CGRect)
}

@MainActor
final class GIFRegionSelectionView: NSView {
    private enum Mode {
        case selecting
        case editing
    }

    private enum Appearance {
        static let selectionHandleSize: CGFloat = 7
        static let selectionHandleHitSize: CGFloat = 14
    }

    weak var delegate: GIFRegionSelectionViewDelegate?
    var screenshot: CGImage? {
        didSet { needsDisplay = true }
    }
    var displayID: CGDirectDisplayID?
    var backingScaleFactor: CGFloat = 1
    var language: AppLanguage = .system
    private(set) var selection: CGRect?

    private var mode: Mode = .selecting
    private var dragStart: CGPoint?
    private var selectionAtDragStart: CGRect?
    private var selectionResizeHandle: SelectionResizeHandle?
    private var hoveredSelectionResizeHandle: SelectionResizeHandle?
    private var hoverPoint: CGPoint?
    private lazy var northwestSoutheastResizeCursor = Self.makeDiagonalResizeCursor(falling: true)
    private lazy var northeastSouthwestResizeCursor = Self.makeDiagonalResizeCursor(falling: false)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        switch mode {
        case .selecting:
            addCursorRect(bounds, cursor: .crosshair)
        case .editing:
            addCursorRect(bounds, cursor: .arrow)
            guard let selection else { return }
            if let selectionResizeHandle {
                addCursorRect(bounds, cursor: cursor(for: selectionResizeHandle))
                return
            }
            addCursorRect(
                selection,
                cursor: selectionAtDragStart == nil ? .openHand : .closedHand
            )
            for (handle, frame) in selectionResizeHandleFrames(for: selection) {
                addCursorRect(frame, cursor: cursor(for: handle))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point

        if mode == .editing,
           event.clickCount >= 2,
           let selection,
           selection.contains(point) {
            delegate?.gifRegionSelectionView(self, didConfirm: selection)
            return
        }

        switch mode {
        case .selecting:
            delegate?.gifRegionSelectionViewDidStartSelection(self)
            dragStart = point
            selection = CGRect(origin: point, size: .zero)
        case .editing:
            guard let selection else {
                mode = .selecting
                delegate?.gifRegionSelectionViewDidStartSelection(self)
                dragStart = point
                self.selection = CGRect(origin: point, size: .zero)
                break
            }
            if let handle = selectionResizeHandle(at: point, in: selection) {
                dragStart = point
                selectionAtDragStart = selection
                selectionResizeHandle = handle
                hoveredSelectionResizeHandle = handle
            } else if selection.contains(point) {
                dragStart = point
                selectionAtDragStart = selection
                NSCursor.closedHand.set()
            } else {
                mode = .selecting
                delegate?.gifRegionSelectionViewDidStartSelection(self)
                dragStart = point
                self.selection = CGRect(origin: point, size: .zero)
                hoveredSelectionResizeHandle = nil
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point
        switch mode {
        case .selecting:
            selection = CGRect.between(dragStart, point).intersection(bounds)
        case .editing:
            guard let originalSelection = selectionAtDragStart else { return }
            if let selectionResizeHandle {
                selection = CaptureGeometry.resizedSelection(
                    originalSelection,
                    using: selectionResizeHandle,
                    to: point,
                    within: bounds
                )
                hoveredSelectionResizeHandle = selectionResizeHandle
            } else {
                selection = CaptureGeometry.movedSelection(
                    originalSelection,
                    from: dragStart,
                    to: point,
                    within: bounds
                )
                NSCursor.closedHand.set()
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            selectionAtDragStart = nil
            selectionResizeHandle = nil
            window?.invalidateCursorRects(for: self)
        }
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point
        switch mode {
        case .selecting:
            guard let selection,
                  selection.width >= 8,
                  selection.height >= 8 else {
                self.selection = nil
                needsDisplay = true
                return
            }
            self.selection = selection.integral.intersection(bounds)
            mode = .editing
        case .editing:
            hoveredSelectionResizeHandle = selection.flatMap {
                selectionResizeHandle(at: point, in: $0)
            }
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        hoverPoint = point
        hoveredSelectionResizeHandle = mode == .editing
            ? selection.flatMap { selectionResizeHandle(at: point, in: $0) }
            : nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            delegate?.gifRegionSelectionViewDidCancel(self)
            return
        }
        if event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if requestConfirmation() { return }
        }
        super.keyDown(with: event)
    }

    @discardableResult
    func requestConfirmation() -> Bool {
        guard mode == .editing,
              let selection,
              selection.width >= 8,
              selection.height >= 8 else {
            return false
        }
        delegate?.gifRegionSelectionView(self, didConfirm: selection)
        return true
    }

    func initializeHoverPoint(atScreenPoint screenPoint: CGPoint) {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return }
        hoverPoint = constrained(point)
        needsDisplay = true
    }

    @discardableResult
    func synchronizeCursor(atScreenPoint screenPoint: CGPoint) -> Bool {
        guard let window, window.isKeyWindow else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return false }
        hoverPoint = constrained(point)
        hoveredSelectionResizeHandle = mode == .editing
            ? selection.flatMap { selectionResizeHandle(at: point, in: $0) }
            : nil
        window.invalidateCursorRects(for: self)
        resolvedCursor(at: point).set()
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let screenshot else {
            NSColor.black.setFill()
            NSBezierPath(rect: bounds).fill()
            return
        }

        let image = NSImage(cgImage: screenshot, size: bounds.size)
        let graphicsContext = NSGraphicsContext.current
        let previousInterpolation = graphicsContext?.imageInterpolation
        graphicsContext?.imageInterpolation = .none
        image.draw(
            in: bounds,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        if let previousInterpolation {
            graphicsContext?.imageInterpolation = previousInterpolation
        }

        NSColor.black.withAlphaComponent(0.44).setFill()
        if let selection {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
            shade.fill()
            drawSelection(selection)
        } else {
            NSBezierPath(rect: bounds).fill()
        }
        drawInstructions()
    }

    private func drawSelection(_ selection: CGRect) {
        NSColor.black.withAlphaComponent(0.7).setStroke()
        let shadowOutline = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        shadowOutline.lineWidth = 3
        shadowOutline.stroke()

        NSColor.systemRed.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: 0.25, dy: 0.25))
        outline.lineWidth = 1.5
        outline.stroke()

        if mode == .editing {
            drawSelectionResizeHandles(for: selection)
        }
        drawSizeLabel(selection)
    }

    private func drawInstructions() {
        let value = L10n.text("overlay.gif.instructions", language: language)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = value.size(withAttributes: attributes)
        let size = CGSize(width: textSize.width + 22, height: textSize.height + 12)
        let frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.minY + 28,
            width: size.width,
            height: size.height
        )
        NSColor(calibratedWhite: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
        value.draw(
            at: CGPoint(x: frame.minX + 11, y: frame.minY + 6),
            withAttributes: attributes
        )
    }

    private func drawSizeLabel(_ selection: CGRect) {
        guard selection.width >= 44 else { return }
        let value = "\(Int((selection.width * backingScaleFactor).rounded())) × "
            + "\(Int((selection.height * backingScaleFactor).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = value.size(withAttributes: attributes)
        let size = CGSize(width: textSize.width + 16, height: textSize.height + 8)
        let x = min(
            max(selection.minX, bounds.minX + 8),
            bounds.maxX - size.width - 8
        )
        let above = selection.minY - size.height - 7
        let y = above >= bounds.minY + 8 ? above : selection.minY + 7
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        NSColor(calibratedWhite: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        value.draw(
            at: CGPoint(x: frame.minX + 8, y: frame.minY + 4),
            withAttributes: attributes
        )
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func selectionResizeHandleFrames(
        for selection: CGRect
    ) -> [(SelectionResizeHandle, CGRect)] {
        let hitSize = Appearance.selectionHandleHitSize
        let halfHitSize = hitSize / 2
        func frame(center: CGPoint) -> CGRect {
            CGRect(
                x: center.x - halfHitSize,
                y: center.y - halfHitSize,
                width: hitSize,
                height: hitSize
            )
        }
        return [
            (.top, CGRect(
                x: selection.minX + halfHitSize,
                y: selection.minY - halfHitSize,
                width: max(0, selection.width - hitSize),
                height: hitSize
            )),
            (.right, CGRect(
                x: selection.maxX - halfHitSize,
                y: selection.minY + halfHitSize,
                width: hitSize,
                height: max(0, selection.height - hitSize)
            )),
            (.bottom, CGRect(
                x: selection.minX + halfHitSize,
                y: selection.maxY - halfHitSize,
                width: max(0, selection.width - hitSize),
                height: hitSize
            )),
            (.left, CGRect(
                x: selection.minX - halfHitSize,
                y: selection.minY + halfHitSize,
                width: hitSize,
                height: max(0, selection.height - hitSize)
            )),
            (.topLeft, frame(center: handleCenter(.topLeft, in: selection))),
            (.topRight, frame(center: handleCenter(.topRight, in: selection))),
            (.bottomRight, frame(center: handleCenter(.bottomRight, in: selection))),
            (.bottomLeft, frame(center: handleCenter(.bottomLeft, in: selection))),
        ]
    }

    private func handleCenter(
        _ handle: SelectionResizeHandle,
        in selection: CGRect
    ) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: selection.minX, y: selection.minY)
        case .top: return CGPoint(x: selection.midX, y: selection.minY)
        case .topRight: return CGPoint(x: selection.maxX, y: selection.minY)
        case .right: return CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: return CGPoint(x: selection.maxX, y: selection.maxY)
        case .bottom: return CGPoint(x: selection.midX, y: selection.maxY)
        case .bottomLeft: return CGPoint(x: selection.minX, y: selection.maxY)
        case .left: return CGPoint(x: selection.minX, y: selection.midY)
        }
    }

    private func selectionResizeHandle(
        at point: CGPoint,
        in selection: CGRect
    ) -> SelectionResizeHandle? {
        let frames = selectionResizeHandleFrames(for: selection)
        let corners: Set<SelectionResizeHandle> = [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
        ]
        return frames.first { corners.contains($0.0) && $0.1.contains(point) }?.0
            ?? frames.first { $0.1.contains(point) }?.0
    }

    private func drawSelectionResizeHandles(for selection: CGRect) {
        for handle in SelectionResizeHandle.allCases {
            let size = handle == hoveredSelectionResizeHandle
                ? Appearance.selectionHandleSize + 2
                : Appearance.selectionHandleSize
            let center = handleCenter(handle, in: selection)
            let frame = CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: frame).fill()
            NSColor.systemRed.setStroke()
            let outline = NSBezierPath(ovalIn: frame.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    private func resolvedCursor(at point: CGPoint) -> NSCursor {
        switch mode {
        case .selecting:
            return .crosshair
        case .editing:
            if let selectionResizeHandle,
               selectionAtDragStart != nil {
                return cursor(for: selectionResizeHandle)
            }
            if let selection,
               let handle = selectionResizeHandle(at: point, in: selection) {
                return cursor(for: handle)
            }
            if let selection, selection.contains(point) {
                return selectionAtDragStart == nil ? .openHand : .closedHand
            }
            return .arrow
        }
    }

    private func cursor(for handle: SelectionResizeHandle) -> NSCursor {
        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        case .topLeft, .bottomRight:
            return northwestSoutheastResizeCursor
        case .topRight, .bottomLeft:
            return northeastSouthwestResizeCursor
        }
    }

    private static func makeDiagonalResizeCursor(falling: Bool) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let start = falling ? CGPoint(x: 5, y: 19) : CGPoint(x: 5, y: 5)
            let end = falling ? CGPoint(x: 19, y: 5) : CGPoint(x: 19, y: 19)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: start)
            path.line(to: end)
            if falling {
                path.move(to: start)
                path.line(to: CGPoint(x: 5, y: 13))
                path.move(to: start)
                path.line(to: CGPoint(x: 11, y: 19))
                path.move(to: end)
                path.line(to: CGPoint(x: 19, y: 11))
                path.move(to: end)
                path.line(to: CGPoint(x: 13, y: 5))
            } else {
                path.move(to: start)
                path.line(to: CGPoint(x: 5, y: 11))
                path.move(to: start)
                path.line(to: CGPoint(x: 11, y: 5))
                path.move(to: end)
                path.line(to: CGPoint(x: 19, y: 13))
                path.move(to: end)
                path.line(to: CGPoint(x: 13, y: 19))
            }
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: CGPoint(x: size.width / 2, y: size.height / 2)
        )
    }
}

@MainActor
private final class GIFRecordingPreparationView: NSView {
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
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class GIFCountdownView: NSView {
    var value: Int {
        didSet { needsDisplay = true }
    }

    init(frame frameRect: NSRect, value: Int) {
        self.value = value
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 8, dy: 8)
        NSColor(calibratedWhite: 0.06, alpha: 0.88).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.systemRed.withAlphaComponent(0.95).setStroke()
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 3
        outline.stroke()

        let text = String(value)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 58, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }
}

@MainActor
private final class GIFRecordingHUDView: NSView {
    private let language: AppLanguage
    private let label = NSTextField(labelWithString: "")
    private let stopButton = NSButton()
    private let recordingDot = GIFRecordingDotView()
    private var onStop: (() -> Void)?

    init(
        frame frameRect: NSRect,
        language: AppLanguage,
        onStop: @escaping () -> Void
    ) {
        self.language = language
        self.onStop = onStop
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.94).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        stopButton.title = L10n.text("gif.hud.stop", language: language)
        stopButton.bezelStyle = .rounded
        stopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        addSubview(stopButton)
        addSubview(recordingDot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        recordingDot.frame = CGRect(x: 14, y: bounds.midY - 5, width: 10, height: 10)
        stopButton.frame = CGRect(
            x: bounds.maxX - 76,
            y: bounds.midY - 15,
            width: 64,
            height: 30
        )
        label.frame = CGRect(
            x: 32,
            y: bounds.midY - 10,
            width: stopButton.frame.minX - 40,
            height: 20
        )
    }

    func update(elapsed: TimeInterval) {
        let wholeSeconds = Int(max(0, elapsed).rounded(.down))
        let value = String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
        label.stringValue = L10n.format("gif.hud.recording", language: language, value)
    }

    @objc private func stopPressed() {
        onStop?()
    }
}

@MainActor
private final class GIFRecordingDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

private final class GIFRecordingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSScreen {
    var gifDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

private extension CGRect {
    func constrained(within bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(minX, bounds.minX), max(bounds.minX, bounds.maxX - width)),
            y: min(max(minY, bounds.minY), max(bounds.minY, bounds.maxY - height)),
            width: min(width, bounds.width),
            height: min(height, bounds.height)
        )
    }
}
