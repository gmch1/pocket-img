# Android 管理 App

PocketIMG 提供一个轻量 Android 管理壳。它把 Go 后端作为 ARM64 原生程序打进 APK，由用户在页面中手动启动、停止或重启；设备不需要 Root，也不需要安装 Go、Node、Docker 或终端环境。

## 能力和边界

- 支持 Android 8.0（API 26）及以上的 ARM64 设备。
- 未启用内置隧道时默认监听 `0.0.0.0:8080`，页面可以修改为 `1024–65535` 的其他端口；启用隧道和“仅允许本机访问”后改为监听 `127.0.0.1`。
- 首次运行自动生成 256 bit 随机 Token，对应稳定空间 `mobile`；迁入既有 Token 配置时保留原空间 ID。
- Android 选定的主空间会作为管理员空间传给后端；管理员可在 Web 页面创建其他用户，新用户 Token 只在创建结果中显示一次。
- 可复制局域网地址和 Token，也可轮换 Token、查看日志、存储占用、PID、运行时长与后端 RSS。
- Go 后端作为独立子进程由 Android 前台服务管理；关闭管理页面不会停止图床。
- 前台服务监听 Go 子进程退出，并每 15 秒检查本机健康接口；连续 3 次失败后自动重建后端。
- 异常恢复采用 `2 秒 → 10 秒 → 30 秒 → 1 分钟 → 5 分钟`的有上限退避；稳定运行 5 分钟后重置退避，防止崩溃循环频繁拉起。
- 可选由 Go 子进程维护 SSH 反向隧道：App 配置公网 HTTPS 地址、SSH 主机/端口、受限用户、回环远端端口和经过可信渠道取得的主机密钥 SHA-256 指纹。
- SSH 隧道断线后使用有上限退避自动重连，并每 30 秒执行应用层 keepalive。远端监听和本机转发目标均被后端强制限制为数字回环地址，不能把 App 配置成通用网络代理。
- App 不申请证书，也不管理域名、DDNS、Caddy 或其他边缘代理配置；这些仍属于独立运维范围。
- “局域网 HTTP”模式使用普通 Session Cookie；“外部 HTTPS”模式使用 Secure Cookie，并把上传读写超时提高到 180/240 秒。
- 用户启动过服务后，App 记录期望运行状态；进程被回收、App 覆盖升级或手机重启后会尝试恢复前台服务。子进程单独退出或健康接口持续失效时，前台服务也会自动恢复后端。厂商 ROM 的自启动和电池策略仍可能要求用户授权。

Android 会在服务运行期间显示不可清除的低优先级通知。通知中的“停止”和 App 内按钮都会先终止 Go 子进程，再结束前台服务。

外部 HTTPS 模式下浏览器不会在 HTTP 上使用 Secure Session Cookie，因此管理图库必须从 HTTPS 域名进入。启用 App 隧道时会自动启用该模式；完成迁移后应同时启用“仅允许本机访问 HTTP”，让 SSH 加密链路直接落到手机回环服务。反向代理约束见[外部 HTTPS 反向代理契约](reverse-proxy.md)。

## 数据位置

图库、SQLite、Token 和日志都位于 App 私有目录：

```text
/data/user/0/com.gmch.pocketimg/files/
├── runtime/
│   ├── tokens.json
│   ├── server.log
│   ├── server.pid
│   ├── tunnel-ed25519
│   ├── tunnel-ed25519.pub
│   └── tunnel-status.json
└── service-data/
    ├── metadata.sqlite3
    ├── objects/
    └── thumbnails/
```

`tunnel-ed25519` 是首次启用隧道时由设备生成的私钥，权限固定为 `0600`；App 只提供复制公钥的按钮，不提供私钥导出。普通用户和其他 App 无法直接读取该目录。Android 卸载 App 时会删除其中的图库数据和设备隧道身份，因此有数据后不要用“卸载再安装”升级；应直接覆盖安装相同签名的新版本。正式备份/导出能力尚未实现。

## SSH 隧道配置

边缘服务器必须为每台设备使用独立的受限 SSH 用户或独立授权密钥，并至少限制为：公钥认证、仅远端转发、无 PTY/Agent/X11/命令执行，以及唯一的 `127.0.0.1:远端端口`。对应端口不得监听公网。

App 不接受首次连接自动信任，并只协商 ED25519 服务器主机密钥。对应指纹必须通过已认证的管理通道取得，并以 OpenSSH `SHA256:base64` 格式填入。启用后第一次启动会生成设备 Ed25519 密钥；把 App 展示的公钥加入服务器 `authorized_keys` 后，连接会自动重试并变为“已连接”。不要把设备私钥、真实授权行或签名材料加入 Git。

迁移现有入口时可暂时关闭“仅允许本机访问 HTTP”，让旧代理和手机直连并行验证。Caddy 切换并验证完成后重新启用该选项。此开关是迁移/局域网兼容手段，不应作为长期公网部署默认值。

从 `/data/local/tmp/phone-image-host-dev` 迁移现有 Root 开发实例时，必须同时保留 SQLite、对象、缩略图、Token 和空间 ID，具体步骤见[Root 实例迁移到 App](root-to-app-migration.md)。

## 后台运行与自启动

标准 Android 会保留用户主动启动的前台服务，并允许 `BOOT_COMPLETED`
恢复。小米、红米等厂商 ROM 还可能把“划掉任务卡”解释为系统强停；强停
状态下 Android 不会向 App 投递开机广播，App 也不能自行绕过这一限制。

首次安装后点击 App 内的“后台运行设置”，在厂商页面允许 PocketIMG
自启动。MIUI 上对应“安全中心 → 自启动管理 → PocketIMG”。这一步由普通
用户操作即可，不需要 Root。授权后再启动服务，并实际验证一次：划掉任务卡
后 `/healthz` 应继续返回 200；重启手机并完成首次解锁后也应自动恢复。

非 MIUI 设备的按钮会打开 PocketIMG 应用详情页，可在该页面检查后台活动和
电池策略。系统“强行停止”始终是显式停用语义，任何 App 都不应尝试绕过。

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
