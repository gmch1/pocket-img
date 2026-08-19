import AppKit
import Combine
import CoreGraphics
import Foundation
import Sparkle

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isCapturing = false
    @Published private(set) var isUploading = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var canCheckForUpdates = false

    let settings = AppSettings()

    private let hotKey = GlobalHotKey(identifier: 1)
    private let captureCoordinator = CaptureCoordinator()
    private let pinnedImages = PinnedImagePresenter()
    private let toast = ToastPresenter()
    private let updaterController: SPUStandardUpdaterController
    private var pendingUpload: UploadPayload?
    private var client: PocketIMGClient?
    private var clientConfiguration: ServiceConfiguration?

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
        hotKey.unregister()
        captureCoordinator.cancel(notify: false)
        settings.flushAnnotationStyle()
    }

    func registerHotKey() {
        do {
            try hotKey.register(settings.hotKey) { [weak self] in
                self?.startCapture()
            }
            settings.hotKeyRegistrationError = ""
        } catch {
            settings.hotKeyRegistrationError = localizedDescription(for: error)
            toast.show(L10n.text("toast.hotkey_registration_failed", language: settings.language))
        }
    }

    func setHotKeyRecording(_ recording: Bool) {
        if recording {
            hotKey.unregister()
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
        guard !isCapturing, !isUploading else { return }
        guard CGPreflightScreenCaptureAccess() else {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                showScreenCapturePermissionHelp()
                return
            }
            toast.show(L10n.format(
                "toast.capture_permission_granted",
                language: settings.language,
                settings.hotKey.localizedDisplayName(language: settings.language)
            ))
            return
        }

        isCapturing = true
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
                self.isCapturing = false
                switch action {
                case .pin:
                    self.pin(payload)
                case .copy:
                    self.copy(payload)
                case .upload:
                    self.upload(payload)
                }
            },
            onCancel: { [weak self] in
                self?.isCapturing = false
                self?.statusMessage = ""
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.isCapturing = false
                self.statusMessage = L10n.text("status.capture_failed", language: self.settings.language)
                self.showError(
                    title: L10n.text("alert.capture_failed", language: self.settings.language),
                    message: self.messageWithDiagnosticLog(self.localizedDescription(for: error))
                )
            }
        )
    }

    private func upload(_ payload: UploadPayload) {
        DiagnosticLog.record("upload started bytes=\(payload.data.count) type=\(payload.contentType)")
        pendingUpload = payload
        isUploading = true
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
                pendingUpload = nil
                isUploading = false
                let completedStatus = L10n.text("status.link_copied", language: settings.language)
                statusMessage = completedStatus
                DiagnosticLog.record("upload finished")
                toast.show(L10n.text("toast.upload_complete", language: settings.language))
                clearStatusLater(expected: completedStatus)
            } catch {
                DiagnosticLog.record(error, phase: "upload")
                isUploading = false
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
        alert.messageText = L10n.text("alert.upload_failed", language: settings.language)
        alert.informativeText = messageWithDiagnosticLog(localizedDescription(for: error))
        alert.addButton(withTitle: L10n.text("button.retry", language: settings.language))
        alert.addButton(withTitle: L10n.text("button.cancel", language: settings.language))
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let pendingUpload {
            upload(pendingUpload)
        } else {
            pendingUpload = nil
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
}
