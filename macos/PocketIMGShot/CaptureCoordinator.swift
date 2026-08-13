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
    private var onUpload: ((UploadPayload) -> Void)?
    private var onCancel: (() -> Void)?
    private var finished = false
    private var approvedDisplayFilters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?

    func begin(
        onUpload: @escaping (UploadPayload) -> Void,
        onCancel: @escaping () -> Void
    ) async throws {
        cancel(notify: false)
        self.onUpload = onUpload
        self.onCancel = onCancel
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
        guard !finished || !windows.isEmpty || pickerContinuation != nil else { return }
        finished = true
        finishPicker(with: .failure(CancellationError()))
        closeWindows()
        if notify { onCancel?() }
        onUpload = nil
        onCancel = nil
    }

    func captureOverlayDidStartSelection(_ overlay: CaptureOverlayView) {
        for window in windows where window.contentView !== overlay {
            window.orderOut(nil)
        }
        overlay.window?.makeKeyAndOrderFront(nil)
        overlay.window?.makeFirstResponder(overlay)
    }

    func captureOverlayDidCancel(_ overlay: CaptureOverlayView) {
        cancel()
    }

    func captureOverlay(_ overlay: CaptureOverlayView, didFinish payload: UploadPayload) {
        guard !finished else { return }
        finished = true
        closeWindows()
        let completion = onUpload
        onUpload = nil
        onCancel = nil
        completion?(payload)
    }

    private func closeWindows() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }

    private func captureDisplays() async throws -> [CapturedDisplay] {
        let pointer = NSEvent.mouseLocation
        let preferredScreen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let preferredDisplayID = preferredScreen?.displayID
        let filter: SCContentFilter

        if let preferredDisplayID, let approved = approvedDisplayFilters[preferredDisplayID] {
            filter = approved
        } else {
            filter = try await requestDisplayFilter()
        }

        guard let display = filter.includedDisplays.first,
              let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureError.noDisplays
        }
        approvedDisplayFilters[display.displayID] = filter

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
        return [CapturedDisplay(screen: screen, image: image)]
    }

    private func requestDisplayFilter() async throws -> SCContentFilter {
        guard pickerContinuation == nil else {
            throw CaptureError.captureAlreadyInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            pickerContinuation = continuation

            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = .singleDisplay
            configuration.allowsChangingSelectedContent = false
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                configuration.excludedBundleIDs = [bundleIdentifier]
            }

            let picker = SCContentSharingPicker.shared
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            picker.present(using: .display)
        }
    }

    private func finishPicker(with result: Result<SCContentFilter, Error>) {
        guard let continuation = pickerContinuation else { return }
        pickerContinuation = nil
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
        continuation.resume(with: result)
    }
}

extension CaptureCoordinator: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.finishPicker(with: .failure(CancellationError()))
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.finishPicker(with: .success(filter))
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.finishPicker(with: .failure(error))
        }
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
    case captureAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return "没有找到可截取的显示器。"
        case .imageEncodingFailed:
            return "无法生成截图文件。"
        case .captureAlreadyInProgress:
            return "已有截图选择正在进行。"
        }
    }
}
