import AppKit
import SwiftUI

@main
@MainActor
struct PocketIMGShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            Button("截图（\(controller.settings.hotKey.displayName)）") {
                controller.startCapture()
            }
            .disabled(controller.isCapturing || controller.isUploading)

            if !controller.statusMessage.isEmpty {
                Divider()
                Text(controller.statusMessage)
            }

            Divider()
            Button("检查更新…") {
                controller.checkForUpdates()
            }
            .disabled(!controller.canCheckForUpdates)
            SettingsMenuButton(controller: controller)
            Button("退出 PocketIMG Shot") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("PocketIMG Shot", systemImage: controller.isUploading ? "arrow.up.circle" : "camera.viewfinder")
        }

        Settings {
            SettingsView(controller: controller)
        }
    }
}

private struct SettingsMenuButton: View {
    @ObservedObject var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("设置…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
            controller.bringSettingsToFront()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let automaticTerminationReason = "PocketIMG Shot must remain available from the menu bar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(automaticTerminationReason)
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLog.record("app will terminate")
        AppController.shared.stop()
        ProcessInfo.processInfo.enableAutomaticTermination(automaticTerminationReason)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
