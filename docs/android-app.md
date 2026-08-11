# Android 管理 App

PocketIMG 提供一个轻量 Android 管理壳。它把 Go 后端作为 ARM64 原生程序打进 APK，由用户在页面中手动启动、停止或重启；设备不需要 Root，也不需要安装 Go、Node、Docker 或终端环境。

## 能力和边界

- 支持 Android 8.0（API 26）及以上的 ARM64 设备。
- 默认监听 `0.0.0.0:8080`，页面可以修改为 `1024–65535` 的其他端口。
- 首次运行自动生成 256 bit 随机 Token，对应稳定空间 `mobile`。
- 可复制局域网地址和 Token，也可轮换 Token、查看日志、存储占用、PID、运行时长与后端 RSS。
- 后端运行在独立的前台服务进程；关闭管理页面不会停止图床。
- App 不实现域名、TLS、DDNS、反向代理、请求转发或开机自启。
- 当前 App 只面向可信局域网 HTTP，后端以 `PIH_COOKIE_SECURE=false` 运行。接入公网域名时需同步增加 HTTPS Cookie 配置，不能把长期 Token 暴露在明文公网链路上。

Android 会在服务运行期间显示不可清除的低优先级通知。通知中的“停止”和 App 内按钮都会先终止 Go 子进程，再结束前台服务。

## 数据位置

图库、SQLite、Token 和日志都位于 App 私有目录：

```text
/data/user/0/com.gmch.pocketimg/files/
├── runtime/
│   ├── tokens.json
│   ├── server.log
│   └── server.pid
└── service-data/
    ├── metadata.sqlite3
    ├── objects/
    └── thumbnails/
```

普通用户和其他 App 无法直接读取该目录。Android 卸载 App 时会删除其中的图库数据，因此有数据后不要用“卸载再安装”升级；应直接覆盖安装相同签名的新版本。正式备份/导出能力尚未实现。

## 本地构建

需要 JDK 21、Android SDK、Go 和 Node.js。Gradle 会先为 Android ARM64 生成 PIE 形式的 Go 后端，再把它打进 APK：

```bash
make frontend-install
make android-test
make android-debug
```

Debug APK 位于：

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

普通安装命令：

```bash
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

部分 MIUI 设备会要求在手机上确认 USB 安装。仅在设备已由本人授权 Root 管理时，可使用包管理器静默覆盖安装：

```bash
adb push android/app/build/outputs/apk/debug/app-debug.apk /data/local/tmp/pocketimg.apk
adb shell su -c 'pm install -r -g /data/local/tmp/pocketimg.apk'
```

Root 只用于绕过 ROM 的安装确认，App 安装后仍以普通 Android 应用 UID 运行。

## 正式签名与发布

本地可复制 `android/keystore.properties.example` 为已忽略的 `android/keystore.properties`，填写专用签名信息后执行：

```bash
make android-release
```

签名私钥和密码不得提交到 Git。GitHub Actions 从以下仓库 Secrets 恢复签名：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

正式签名证书 SHA-256 指纹为：

```text
56:CB:C5:B4:2A:80:53:B6:F7:C7:8C:96:57:F6:A5:2B:53:88:6C:A7:EC:86:78:4D:DA:63:54:38:91:C3:D2:63
```

推送 `v*` 标签会运行前端测试、Go 测试和 Android 单元测试，构建签名 APK，并发布 APK 与 SHA-256 校验文件到 GitHub Releases。Actions 页面也可以手动输入版本标签触发发布。
