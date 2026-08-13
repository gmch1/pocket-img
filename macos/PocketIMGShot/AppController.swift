import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isCapturing = false
    @Published private(set) var isUploading = false
    @Published private(set) var statusMessage = ""

    let settings = AppSettings()

    private let hotKey = GlobalHotKey()
    private let captureCoordinator = CaptureCoordinator()
    private let toast = ToastPresenter()
    private var pendingUpload: UploadPayload?
    private var client: PocketIMGClient?
    private var clientConfiguration: ServiceConfiguration?

    private init() {}

    func start() {
        registerHotKey()
    }

    func stop() {
        hotKey.unregister()
        captureCoordinator.cancel(notify: false)
    }

    func registerHotKey() {
        do {
            try hotKey.register(settings.hotKey) { [weak self] in
                self?.startCapture()
            }
            settings.hotKeyRegistrationError = ""
        } catch {
            settings.hotKeyRegistrationError = error.localizedDescription
            toast.show("快捷键注册失败")
        }
    }

    func setHotKeyRecording(_ recording: Bool) {
        if recording {
            hotKey.unregister()
        } else {
            registerHotKey()
        }
    }

    func saveSettings() {
        do {
            try settings.save()
            client = nil
            clientConfiguration = nil
            registerHotKey()
            toast.show("设置已保存")
        } catch {
            showError(title: "无法保存设置", message: error.localizedDescription)
        }
    }

    func startCapture() {
        guard !isCapturing, !isUploading else { return }
        do {
            _ = try settings.serviceConfiguration()
        } catch {
            showError(title: "请先配置 PocketIMG", message: error.localizedDescription)
            openSettings()
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                showScreenCapturePermissionHelp()
                return
            }
            toast.show("已获得截屏权限，请再次按 \(settings.hotKey.displayName)")
            return
        }

        isCapturing = true
        statusMessage = "正在准备截图…"
        Task {
            do {
                try await captureCoordinator.begin(
                    onUpload: { [weak self] payload in
                        self?.isCapturing = false
                        self?.upload(payload)
                    },
                    onCancel: { [weak self] in
                        self?.isCapturing = false
                        self?.statusMessage = ""
                    }
                )
                statusMessage = "拖拽选择截图区域"
            } catch {
                isCapturing = false
                statusMessage = ""
                showError(title: "无法开始截图", message: error.localizedDescription)
            }
        }
    }

    private func upload(_ payload: UploadPayload) {
        pendingUpload = payload
        isUploading = true
        statusMessage = "正在上传…"
        toast.show("正在上传…", duration: 60)

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
                statusMessage = "链接已复制"
                toast.show("上传完成，链接已复制")
                clearStatusLater()
            } catch {
                isUploading = false
                statusMessage = "上传失败"
                toast.dismiss()
                offerUploadRetry(error: error)
            }
        }
    }

    private func offerUploadRetry(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图上传失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "取消")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let pendingUpload {
            upload(pendingUpload)
        } else {
            pendingUpload = nil
            statusMessage = ""
        }
    }

    private func clearStatusLater() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !isUploading, statusMessage == "链接已复制" {
                statusMessage = ""
            }
        }
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func showScreenCapturePermissionHelp() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 PocketIMG Shot，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
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
        alert.addButton(withTitle: "好")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
