import SwiftUI

@MainActor
struct SettingsView: View {
    let controller: AppController
    @ObservedObject private var settings: AppSettings

    init(controller: AppController) {
        self.controller = controller
        settings = controller.settings
    }

    var body: some View {
        Form {
            Section(L10n.text("settings.general.section", language: settings.language)) {
                Picker(
                    L10n.text("settings.language", language: settings.language),
                    selection: Binding(
                        get: { settings.language },
                        set: controller.setLanguage
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: settings.language)).tag(language)
                    }
                }
            }

            Section(L10n.text("settings.service.section", language: settings.language)) {
                TextField(text: $settings.serverAddress, prompt: Text("https://img.example.com")) {
                    HStack(spacing: 5) {
                        Text(L10n.text("settings.server_address", language: settings.language))
                        SettingsHelpIcon(
                            text: L10n.text("settings.server_address.help", language: settings.language)
                        )
                    }
                }
                    .textFieldStyle(.roundedBorder)
                SecureField("Token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
            }

            Section(L10n.text("settings.capture.section", language: settings.language)) {
                HStack {
                    Text(L10n.text("settings.global_hotkey", language: settings.language))
                    SettingsHelpIcon(
                        text: L10n.text("settings.hotkey.help", language: settings.language)
                    )
                    Spacer()
                    HotKeyRecorder(
                        hotKey: $settings.hotKey,
                        language: settings.language,
                        onChange: controller.persistHotKey,
                        onRecordingChanged: controller.setHotKeyRecording
                    )
                        .frame(width: 170, height: 28)
                }
                if !settings.hotKeyRegistrationError.isEmpty {
                    Text(settings.hotKeyRegistrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("settings.save", language: settings.language)) {
                    controller.saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 430)
        .padding()
    }
}

private struct SettingsHelpIcon: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel(text)
    }
}
