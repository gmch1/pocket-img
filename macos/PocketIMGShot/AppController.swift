import AppKit
import Combine
import CoreGraphics
import Foundation
import Sparkle
import UniformTypeIdentifiers

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    private enum Activity {
        case idle
        case screenshot
        case video(VideoRecordingState)
        case videoResult
        case uploading
        case uploadFailure
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var isUploading = false
    @Published private(set) var isVideoRecording = false
    @Published private(set) var canToggleVideoRecording = true
    @Published private(set) var statusMessage = ""
    @Published private(set) var canCheckForUpdates = false

    let settings = AppSettings()

    private let captureHotKey = GlobalHotKey(identifier: 1)
    private let videoHotKey = GlobalHotKey(identifier: 3)
    private let captureCoordinator = CaptureCoordinator()
    private let videoRecordingCoordinator = VideoRecordingCoordinator()
    private let pinnedImages = PinnedImagePresenter()
    private let toast = ToastPresenter()
    private let updaterController: SPUStandardUpdaterController
    private var pendingUpload: UploadPayload?
    private var pendingUploadExperimentSessionID: UUID?
    private var client: PocketIMGClient?
    private var clientConfiguration: ServiceConfiguration?
    private var activity: Activity = .idle

    private init() {
        let shouldStartUpdater = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        updaterController = SPUStandardUpdaterController(
            startingUpdater: shouldStartUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        DiagnosticLog.record("app started version=\(version)")
        registerHotKey()
    }

    func stop() {
        captureHotKey.unregister()
        videoHotKey.unregister()
        captureCoordinator.cancel(notify: false)
        videoRecordingCoordinator.cancel(notify: false)
        settings.flushAnnotationStyle()
    }

    func registerHotKey() {
        captureHotKey.unregister()
        videoHotKey.unregister()

        var registrationErrors: [String] = []
        do {
            try captureHotKey.register(settings.hotKey) { [weak self] in
                self?.startCapture()
            }
        } catch {
            registrationErrors.append(localizedDescription(for: error))
        }

        if settings.hotKey.keyCode == settings.videoHotKey.keyCode,
           settings.hotKey.carbonModifiers == settings.videoHotKey.carbonModifiers {
            registrationErrors.append(
                L10n.text("settings.hotkey_conflict", language: settings.language)
            )
        } else {
            do {
                try videoHotKey.register(settings.videoHotKey) { [weak self] in
                    self?.toggleVideoRecording()
                }
            } catch {
                registrationErrors.append(localizedDescription(for: error))
            }
        }

        settings.hotKeyRegistrationError = registrationErrors.joined(separator: "\n")
        if !registrationErrors.isEmpty {
            toast.show(L10n.text("toast.hotkey_registration_failed", language: settings.language))
        }
    }

    func setHotKeyRecording(_ recording: Bool) {
        if recording {
            captureHotKey.unregister()
            videoHotKey.unregister()
        } else {
            registerHotKey()
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    func persistHotKey(_ value: HotKey) {
        settings.persistHotKey(value)
    }

    func persistVideoHotKey(_ value: HotKey) {
        settings.persistVideoHotKey(value)
    }

    func setLanguage(_ language: AppLanguage) {
        settings.persistLanguage(language)
        pinnedImages.updateLanguage(language)
        if !settings.hotKeyRegistrationError.isEmpty {
            registerHotKey()
        }
    }

    func saveSettings() {
        do {
            try settings.save()
            client = nil
            clientConfiguration = nil
            registerHotKey()
            toast.show(L10n.text("toast.settings_saved", language: settings.language))
        } catch {
            showError(
                title: L10n.text("alert.settings_save_failed", language: settings.language),
                message: localizedDescription(for: error)
            )
        }
    }

    func bringSettingsToFront() {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)

        Task { @MainActor in
            for attempt in 0..<4 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(50 * attempt)))
                } else {
                    await Task.yield()
                }
                guard let settingsWindow = application.windows.first(where: {
                    $0.isVisible && $0.styleMask.contains(.titled)
                }) else {
                    continue
                }
                application.activate(ignoringOtherApps: true)
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.orderFrontRegardless()
                return
            }
        }
    }

    func startCapture() {
        guard case .idle = activity else { return }
        guard ensureScreenCaptureAccess(for: settings.hotKey) else { return }

        transition(to: .screenshot)
        statusMessage = ""
        captureCoordinator.begin(
            annotationStyle: settings.annotationStyle,
            uploadEnabled: settings.hasUploadConfiguration,
            language: settings.language,
            onAnnotationStyleChange: { [weak self] style in
                self?.settings.updateAnnotationStyle(style)
            },
            onFinish: { [weak self] payload, action in
                guard let self else { return }
                switch action {
                case .pin:
                    self.transition(to: .idle)
                    self.pin(payload)
                case .copy:
                    self.transition(to: .idle)
                    self.copy(payload)
                case .upload:
                    self.upload(payload)
                }
            },
            onCancel: { [weak self] in
                self?.transition(to: .idle)
                self?.statusMessage = ""
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.transition(to: .idle)
                self.statusMessage = L10n.text("status.capture_failed", language: self.settings.language)
                self.showError(
                    title: L10n.text("alert.capture_failed", language: self.settings.language),
                    message: self.messageWithDiagnosticLog(self.localizedDescription(for: error))
                )
            }
        )
    }

    func toggleVideoRecording() {
        switch activity {
        case .idle:
            startVideoRecording()
        case .video(.recording):
            videoRecordingCoordinator.stopRecording()
        default:
            break
        }
    }

    private func startVideoRecording() {
        guard ensureScreenCaptureAccess(for: settings.videoHotKey) else { return }

        transition(to: .video(.preparing))
        statusMessage = L10n.text("status.video.selecting", language: settings.language)
        videoRecordingCoordinator.begin(
            language: settings.language,
            stopShortcutDisplayName: settings.videoHotKey.localizedDisplayName(
                language: settings.language
            ),
            onStateChange: { [weak self] state in
                self?.handleVideoStateChange(state)
            },
            onFinish: { [weak self] result in
                guard let self else { return }
                self.transition(to: .videoResult)
                self.presentVideoResult(result)
            },
            onCancel: { [weak self] in
                self?.transition(to: .idle)
                self?.statusMessage = ""
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.transition(to: .idle)
                self.statusMessage = ""
                self.showError(
                    title: L10n.text("alert.video_failed", language: self.settings.language),
                    message: self.messageWithVideoExperimentLog(
                        self.localizedDescription(for: error)
                    )
                )
            }
        )
    }

    private func handleVideoStateChange(_ state: VideoRecordingState) {
        guard case .video = activity else { return }
        switch state {
        case .idle:
            // The matching finish, cancel, or error callback owns the terminal
            // transition so a new capture cannot start between callbacks.
            break
        case .preparing, .selecting:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.selecting", language: settings.language)
        case .countdown:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.countdown", language: settings.language)
        case .recording:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.recording", language: settings.language)
        case .stopping:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.stopping", language: settings.language)
        case .editing:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.editing", language: settings.language)
        case .exporting:
            transition(to: .video(state))
            statusMessage = L10n.text("status.video.exporting", language: settings.language)
        }
    }

    private func presentVideoResult(_ result: VideoRecordingResult) {
        let duration = String(format: "%.1f s", result.duration)
        let bytes = ByteCountFormatter.string(
            fromByteCount: result.metrics.videoBytes,
            countStyle: .file
        )
        let canUpload = settings.hasUploadConfiguration
            && !result.metrics.exceedsMaximumBytes

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("alert.video_ready", language: settings.language)
        alert.informativeText = L10n.format(
            result.metrics.exceedsMaximumBytes
                ? "alert.video_ready_body_large"
                : "alert.video_ready_body",
            language: settings.language,
            duration,
            bytes
        )
        if canUpload {
            alert.addButton(withTitle: L10n.text("button.upload_video", language: settings.language))
        }
        alert.addButton(withTitle: L10n.text("button.copy_video", language: settings.language))
        alert.addButton(withTitle: L10n.text("button.cancel", language: settings.language))

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if canUpload, response == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(at: result.fileURL)
            upload(result.payload, experimentSessionID: result.sessionID)
        } else if response == (canUpload ? .alertSecondButtonReturn : .alertFirstButtonReturn) {
            transition(to: .idle)
            copyVideo(result)
        } else {
            try? FileManager.default.removeItem(at: result.fileURL)
            transition(to: .idle)
            statusMessage = ""
        }
    }

    private func copyVideo(_ result: VideoRecordingResult) {
        let item = NSPasteboardItem()
        let videoType = NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier)
        guard item.setData(result.data, forType: videoType) else {
            VideoExperimentLogger.recordOutcome(
                sessionID: result.sessionID,
                stage: .clipboard,
                event: "clipboard_failed"
            )
            try? FileManager.default.removeItem(at: result.fileURL)
            statusMessage = ""
            showError(
                title: L10n.text("alert.video_failed", language: settings.language),
                message: L10n.text("error.clipboard_write_failed", language: settings.language)
            )
            return
        }
        item.setString(result.fileURL.absoluteString, forType: .fileURL)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            VideoExperimentLogger.recordOutcome(
                sessionID: result.sessionID,
                stage: .clipboard,
                event: "clipboard_failed"
            )
            try? FileManager.default.removeItem(at: result.fileURL)
            statusMessage = ""
            showError(
                title: L10n.text("alert.video_failed", language: settings.language),
                message: L10n.text("error.clipboard_write_failed", language: settings.language)
            )
            return
        }

        VideoExperimentLogger.recordOutcome(
            sessionID: result.sessionID,
            stage: .clipboard,
            event: "clipboard_succeeded"
        )
        let copiedStatus = L10n.text("status.video.copied", language: settings.language)
        statusMessage = copiedStatus
        toast.show(L10n.text("toast.video_copied", language: settings.language))
        clearStatusLater(expected: copiedStatus)
    }

    private func upload(
        _ payload: UploadPayload,
        experimentSessionID: UUID? = nil
    ) {
        DiagnosticLog.record("upload started bytes=\(payload.data.count) type=\(payload.contentType)")
        pendingUpload = payload
        pendingUploadExperimentSessionID = experimentSessionID
        if let experimentSessionID {
            VideoExperimentLogger.recordOutcome(
                sessionID: experimentSessionID,
                stage: .upload,
                event: "upload_started"
            )
        }
        transition(to: .uploading)
        statusMessage = L10n.text("status.uploading", language: settings.language)
        toast.show(L10n.text("toast.uploading", language: settings.language), duration: 60)

        Task {
            do {
                let configuration = try settings.serviceConfiguration()
                let client: PocketIMGClient
                if let current = self.client, clientConfiguration == configuration {
                    client = current
                } else {
                    client = PocketIMGClient(configuration: configuration)
                    self.client = client
                    clientConfiguration = configuration
                }
                let url = try await client.upload(payload)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                if let experimentSessionID {
                    VideoExperimentLogger.recordOutcome(
                        sessionID: experimentSessionID,
                        stage: .upload,
                        event: "upload_succeeded"
                    )
                }
                pendingUpload = nil
                pendingUploadExperimentSessionID = nil
                transition(to: .idle)
                let completedStatus = L10n.text("status.link_copied", language: settings.language)
                statusMessage = completedStatus
                DiagnosticLog.record("upload finished")
                toast.show(L10n.text("toast.upload_complete", language: settings.language))
                clearStatusLater(expected: completedStatus)
            } catch {
                DiagnosticLog.record(error, phase: "upload")
                if let experimentSessionID {
                    VideoExperimentLogger.recordError(
                        sessionID: experimentSessionID,
                        stage: .upload,
                        error: error
                    )
                }
                transition(to: .uploadFailure)
                statusMessage = L10n.text("status.upload_failed", language: settings.language)
                toast.dismiss()
                offerUploadRetry(error: error)
            }
        }
    }

    private func copy(_ payload: UploadPayload) {
        guard let image = NSImage(data: payload.data) else {
            showError(
                title: L10n.text("alert.copy_failed", language: settings.language),
                message: CaptureError.imageEncodingFailed.localizedMessage(language: settings.language)
            )
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            showError(
                title: L10n.text("alert.copy_failed", language: settings.language),
                message: L10n.text("error.clipboard_write_failed", language: settings.language)
            )
            return
        }
        let copiedStatus = L10n.text("status.screenshot_copied", language: settings.language)
        statusMessage = copiedStatus
        toast.show(L10n.text("toast.screenshot_copied", language: settings.language))
        clearStatusLater(expected: copiedStatus)
    }

    private func pin(_ payload: UploadPayload) {
        do {
            try pinnedImages.show(payload, language: settings.language)
            let pinnedStatus = L10n.text("status.screenshot_pinned", language: settings.language)
            statusMessage = pinnedStatus
            toast.show(L10n.text("toast.screenshot_pinned", language: settings.language))
            clearStatusLater(expected: pinnedStatus)
        } catch {
            statusMessage = L10n.text("status.pin_failed", language: settings.language)
            showError(
                title: L10n.text("alert.pin_failed", language: settings.language),
                message: localizedDescription(for: error)
            )
        }
    }

    private func offerUploadRetry(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let isVideoUpload = pendingUpload?.contentType == "video/mp4"
        let titleKey = isVideoUpload
            ? "alert.video_upload_failed"
            : "alert.upload_failed"
        alert.messageText = L10n.text(titleKey, language: settings.language)
        alert.informativeText = isVideoUpload
            ? messageWithVideoExperimentLog(localizedDescription(for: error))
            : messageWithDiagnosticLog(localizedDescription(for: error))
        alert.addButton(withTitle: L10n.text("button.retry", language: settings.language))
        alert.addButton(withTitle: L10n.text("button.cancel", language: settings.language))
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let pendingUpload {
            upload(
                pendingUpload,
                experimentSessionID: pendingUploadExperimentSessionID
            )
        } else {
            if let pendingUploadExperimentSessionID {
                VideoExperimentLogger.recordOutcome(
                    sessionID: pendingUploadExperimentSessionID,
                    stage: .upload,
                    event: "upload_cancelled"
                )
            }
            pendingUpload = nil
            pendingUploadExperimentSessionID = nil
            transition(to: .idle)
            statusMessage = ""
        }
    }

    private func clearStatusLater(expected: String) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !isUploading, statusMessage == expected {
                statusMessage = ""
            }
        }
    }

    private func transition(to newActivity: Activity) {
        activity = newActivity
        switch newActivity {
        case .idle:
            isCapturing = false
            isUploading = false
            isVideoRecording = false
            canToggleVideoRecording = true
        case .screenshot, .videoResult:
            isCapturing = true
            isUploading = false
            isVideoRecording = false
            canToggleVideoRecording = false
        case .video(let state):
            isCapturing = true
            isUploading = false
            isVideoRecording = state == .recording || state == .stopping
            canToggleVideoRecording = state == .recording
        case .uploading, .uploadFailure:
            isCapturing = false
            isUploading = true
            isVideoRecording = false
            canToggleVideoRecording = false
        }
    }

    private func ensureScreenCaptureAccess(for hotKey: HotKey) -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }

        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            showScreenCapturePermissionHelp()
            return false
        }
        toast.show(L10n.format(
            "toast.capture_permission_granted",
            language: settings.language,
            hotKey.localizedDisplayName(language: settings.language)
        ))
        return false
    }

    private func showScreenCapturePermissionHelp() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("alert.screen_permission_title", language: settings.language)
        alert.informativeText = L10n.text("alert.screen_permission_body", language: settings.language)
        alert.addButton(withTitle: L10n.text("button.open_system_settings", language: settings.language))
        alert.addButton(withTitle: L10n.text("button.cancel", language: settings.language))
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("button.ok", language: settings.language))
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func localizedDescription(for error: Error) -> String {
        if let localized = error as? AppLocalizedError {
            return localized.localizedMessage(language: settings.language)
        }
        if error is URLError {
            return L10n.text("error.network", language: settings.language)
        }
        return error.localizedDescription
    }

    private func messageWithDiagnosticLog(_ message: String) -> String {
        message + "\n\n" + L10n.format(
            "diagnostic_log",
            language: settings.language,
            "~/Library/Logs/PocketIMGShot.log"
        )
    }

    private func messageWithVideoExperimentLog(_ message: String) -> String {
        messageWithDiagnosticLog(message) + "\n" + L10n.format(
            "video_experiment_log",
            language: settings.language,
            "~/Library/Logs/PocketIMGShot-Video-Experiment.jsonl"
        )
    }
}
