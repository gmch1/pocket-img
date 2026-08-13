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
            Section("PocketIMG 服务") {
                TextField("服务器地址", text: $settings.serverAddress, prompt: Text("https://img.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Token", text: $settings.token)
                    .textFieldStyle(.roundedBorder)
                Text("设置写入 ~/Library/Application Support/PocketIMGShot/settings.json，不访问钥匙串；替换 App 后仍会保留。局域网调试可以使用 HTTP 地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("截图") {
                HStack {
                    Text("全局快捷键")
                    Spacer()
                    HotKeyRecorder(
                        hotKey: $settings.hotKey,
                        onChange: controller.persistHotKey,
                        onRecordingChanged: controller.setHotKeyRecording
                    )
                        .frame(width: 170, height: 28)
                }
                Text("点击快捷键框后按下新组合。默认是 F1；部分 Mac 键盘需要同时按 Fn。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.hotKeyRegistrationError.isEmpty {
                    Text(settings.hotKeyRegistrationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("保存") {
                    controller.saveSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 330)
        .padding()
    }
}
