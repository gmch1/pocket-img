import AppKit
import SwiftUI

@main
@MainActor
struct PocketIMGShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var settings = AppController.shared.settings

    var body: some Scene {
        MenuBarExtra {
            Button(L10n.format(
                "menu.capture",
                language: settings.language,
                settings.hotKey.localizedDisplayName(language: settings.language)
            )) {
                controller.startCapture()
            }
            .disabled(controller.isCapturing || controller.isUploading)

            Button(
                controller.isGIFRecording
                    ? L10n.text("menu.stop_gif", language: settings.language)
                    : L10n.format(
                        "menu.record_gif",
                        language: settings.language,
                        settings.gifHotKey.localizedDisplayName(language: settings.language)
                    )
            ) {
                controller.toggleGIFRecording()
            }
            .disabled(!controller.canToggleGIFRecording)

            if !controller.statusMessage.isEmpty {
                Divider()
                Text(controller.statusMessage)
            }

            Divider()
            Button(L10n.text("menu.check_updates", language: settings.language)) {
                controller.checkForUpdates()
            }
            .disabled(!controller.canCheckForUpdates)
            SettingsMenuButton(controller: controller, language: settings.language)
            Button(L10n.text("menu.quit", language: settings.language)) {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label {
                Text("PocketIMG Shot")
            } icon: {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }

        Settings {
            SettingsView(controller: controller)
        }
    }
}

private struct SettingsMenuButton: View {
    @ObservedObject var controller: AppController
    let language: AppLanguage
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L10n.text("menu.settings", language: language)) {
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
