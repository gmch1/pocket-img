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
                HStack {
                    HStack(spacing: 5) {
                        Text(L10n.text("settings.server_address", language: settings.language))
                        SettingsHelpButton(
                            text: L10n.text("settings.server_address.help", language: settings.language)
                        )
                    }
                    Spacer()
                    TextField(
                        "",
                        text: $settings.serverAddress,
                        prompt: Text("https://img.example.com")
                    )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                SecureField("Token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
            }

            Section(L10n.text("settings.capture.section", language: settings.language)) {
                HStack {
                    Text(L10n.text("settings.screenshot_hotkey", language: settings.language))
                    SettingsHelpButton(
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
                HStack {
                    Text(L10n.text("settings.gif_hotkey", language: settings.language))
                    SettingsHelpButton(
                        text: L10n.text("settings.hotkey.help", language: settings.language)
                    )
                    Spacer()
                    HotKeyRecorder(
                        hotKey: $settings.gifHotKey,
                        language: settings.language,
                        onChange: controller.persistGIFHotKey,
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
        .frame(width: 500, height: 470)
        .padding()
    }
}

private struct SettingsHelpButton: View {
    let text: String
    @State private var isHovered = false
    @State private var isExpanded = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(isHovered || isExpanded ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: helpPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private var helpPresented: Binding<Bool> {
        Binding(
            get: { isHovered || isExpanded },
            set: { presented in
                guard !presented else { return }
                isHovered = false
                isExpanded = false
            }
        )
    }
}
