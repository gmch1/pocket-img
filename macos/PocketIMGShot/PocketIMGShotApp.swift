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
            SettingsLink {
                Text("设置…")
            }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
