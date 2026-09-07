# 组件发布流程

PocketIMG 的 Linux Server、Android App、macOS Shot 和 fnOS 应用使用独立发布通道。提交代码本身只运行 CI；只有对应组件标签或 Actions 手动调度才会生成正式 Release。

| 组件 | 标签 | 工作流 | 主要产物 |
| --- | --- | --- | --- |
| Server / Docker | `server-v<version>` | `release-server.yml` | Linux amd64 二进制、systemd 与 Docker 安装包及 SHA-256、amd64/arm64 GHCR 镜像 |
| Android App | `android-v<version>` | `release-android.yml` | 签名 ARM64 APK 与 SHA-256 |
| macOS Shot | `macos-v<version>` | `release-macos.yml` | Apple Silicon（arm64）应用 ZIP、自动更新 tar.xz、SHA-256 与签名 appcast |
| fnOS | `fnos-v<version>` | `release-fnos.yml` | fnOS FPK 与 SHA-256，复用同版本 Server 镜像 |

版本必须是三个非负整数，例如 `0.4.41`。发布标签不接受预发布后缀。首轮组件化发布以旧的全平台 `v0.4.40` 作为 Release Notes 比较基线，之后每个工作流只比较同组件的上一个标签。

## 单组件发布

推送 `main` 会自动触发 CI，验证源码及容器，但不会创建 Release 或更新用户已经安装的服务。要让 GitHub 一键安装入口取得新功能，还需要发布 Server 组件；单纯修改文案无需单独发布 Mac 或 Android。

Server 构建会调用 `scripts/package-linux-installer.sh`，把二进制、`scripts/install-linux.sh` 与 systemd unit 打成 `PocketIMG-<version>-linux-amd64-install.tar.gz`，并附带 SHA-256。根目录 `install.sh` 只选择包含该附件及校验文件的稳定 Server Release。历史发布不补写附件；首次启用此流程必须发布新版本。

Server 现在同时发布 `ghcr.io/gmch1/pocket-img:<version>` 的 amd64/arm64 镜像。构建测试通过后推送镜像并检查匿名可拉取，再以镜像摘要生成 `PocketIMG-<version>-docker-install.tar.gz` 和 SHA-256，最后发布包含两类安装包的 Server Release。根目录入口的 `--docker` 只选择含 Docker 部署包的稳定 Server 版本。升级入口不依赖 Mac 或 fnOS 发布。

同版本镜像若已存在，只允许同一源码提交重试，其他提交必须使用新版本；历史无 revision 标签的镜像也不覆盖。不更新浮动 `latest`。Server `0.5.3` 是首个同时提供两类安装包和 Server 镜像发布的新版本，不能直接使用旧 `0.5.2` 镜像进行自动初始化。

确认目标提交已经进入 `main` 且 CI 通过后，只推送需要发布的标签：

```bash
git tag server-v0.4.41
git push origin server-v0.4.41

git tag android-v0.4.41
git push origin android-v0.4.41

git tag macos-v0.4.41
git push origin macos-v0.4.41

git tag fnos-v0.4.41
git push origin fnos-v0.4.41
```

也可以在 Actions 中单独运行对应工作流并输入不带组件前缀的版本号。手动运行会在当前提交创建相应组件标签和 Release。

后端和网页同时被 Linux Server 与 Android App 使用。此类更新若需要覆盖两个部署端，应在同一提交上分别推送 `server-v*` 与 `android-v*`，而不是触发无关的 macOS 构建。Android 管理壳自身的修改只需要 `android-v*`。

## 全平台发布

`Release all PocketIMG components` 不监听标签，只能从 Actions 手动运行。输入一个版本号后，它会先并行发布 Server、Android 和 macOS；fnOS 等待 Server 和 macOS 成功，再复用同版本镜像与签名 macOS ZIP 构建 FPK，最终创建四个标签和四个 Release。

fnOS 不再写入 Registry 或重建后端镜像。单独发布 fnOS 前必须先发布同版本 Server 和 macOS；打包前检查 Server Release 存在及镜像可匿名拉取，缺失时直接失败。FPK 固定引用同版本镜像标签，且把匹配版本的 macOS ZIP 直接放进安装包；NAS 安装后下载客户端不再依赖 GitHub Release。

旧的 `v*` 标签不再触发工作流。

## Android 与 macOS 构建号

Android `versionCode` 和 macOS `CFBundleVersion` 不再使用工作流运行次数，而是从组件语义版本稳定计算：

```text
build number = major × 1,000,000 + minor × 1,000 + patch
0.4.41 → 4041
```

`minor` 与 `patch` 均不能超过 999，最终值必须处于 `1...2100000000`。这一规则使独立工作流重新计数后仍能正确覆盖安装，并让 Sparkle 判断新版本高于旧版。

## macOS 自动更新

macOS 版本化 Release 使用 `macos-v*` 标签，并被明确标记为 GitHub Latest，以兼容仍从旧 `/releases/latest/download/appcast.xml` 地址检查更新的客户端。Server 和 Android Release 使用 `--latest=false`，不会抢占该入口。

新客户端固定读取：

```text
https://github.com/gmch1/pocket-img/releases/download/macos-appcast/appcast.xml
```

macOS 工作流先发布版本化归档，再更新 `macos-appcast` 预发布中的滚动签名清单，避免 appcast 暂时指向尚不存在的文件。`macos-appcast` 不匹配 `macos-v*`，更新该资产不会递归触发发布。

macOS Release 只构建并发布 Apple Silicon（`arm64`）版本，不再提供 Intel 或 Universal 产物。供用户手动下载的归档命名为 `PocketIMGShot-<version>-macos-arm64.zip`；Sparkle appcast 指向体积更小的 `PocketIMGShot-<version>-macos-arm64.tar.xz`，两种归档分别提供 SHA-256。appcast 使用 `sparkle:hardwareRequirements=arm64` 标记硬件要求；已安装旧 Universal 版本的 Intel Mac 会保留现有版本，但不会下载或安装不兼容的新版本。
