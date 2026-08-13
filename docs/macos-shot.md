# macOS 截图上传客户端

`PocketIMG Shot` 是 PocketIMG 的原生 macOS 菜单栏客户端。它提供一条精简工作流：

```text
F2 → 拖拽选择区域 → 红框/箭头标注 → 点击最右侧上传按钮 → 剪贴板得到公开 URL
```

客户端要求 macOS 14 或更高版本，使用 ScreenCaptureKit 截图，通过现有 `POST /api/auth/session` 和 `POST /api/images` 接口上传，不需要单独部署桌面端 API。

## 当前能力

- 菜单栏常驻，不显示 Dock 图标。
- 默认全局快捷键为 `F2`，可以在设置中录制其他功能键或带修饰键的组合。
- 支持多显示器区域选择及 Retina 像素比例。
- 支持固定红色矩形和红色箭头。
- 支持工具栏撤销、`Command-Z`、`Escape` 取消和 `Return` 上传。
- 工具栏最右侧固定为上传按钮。
- 上传成功后把公开 URL 写入系统剪贴板。
- Token 保存在 macOS 钥匙串；Session Cookie 只保存在当前进程。
- 截图自动限制在 19 MP 以内；超过 24 MiB 的 PNG 尝试转为 JPEG 后上传。

暂未实现文字、马赛克、画笔、窗口吸附、选区二次缩放、长截图和本地历史记录。

## 开发与运行

在安装了 Xcode 16 或更高版本的 Mac 上打开：

```bash
open macos/PocketIMGShot.xcodeproj
```

选择 `PocketIMGShot` scheme 后运行。工程默认使用本机 ad-hoc 签名，开发阶段无需配置发布证书。GitHub Release 中的 macOS 通用包也采用 ad-hoc 签名，首次启动需要在 Finder 中右键应用并选择“打开”。需要免提示分发或公证时，在 Xcode 的 Signing & Capabilities 中换成自己的 Developer ID 团队和签名。

也可以从仓库根目录运行：

```bash
make macos-test
make macos-build
```

首次截图时，macOS 会要求“屏幕与系统音频录制”权限。授权后若仍无法截图，请完全退出并重新打开 App。功能键行为受系统键盘设置影响；部分 Mac 键盘需要按 `Fn-F2` 才会发送标准 F2。

## 首次配置

1. 点击菜单栏相机图标并打开“设置”。
2. 填写 PocketIMG 根地址，例如 `https://img.example.com` 或局域网开发地址 `http://192.168.1.20:8080`。
3. 填写当前空间的长期 Token。
4. 如有需要，点击快捷键框后按下新的组合。
5. 保存设置，然后按 `F2` 开始截图。

客户端首次上传时用 Token 换取 Session；后续复用 Session。服务返回 `401` 时会自动重新认证并重试一次。上传失败不会修改剪贴板，且会保留当前编码后的截图供用户重试。
