# PocketIMG

PocketIMG 是面向单实例、自托管场景的轻量图床。

Go 后端内嵌 React 管理网页，可作为 Linux 单文件服务运行，也可以通过 Android 管理 App 部署。仓库还提供独立的 macOS 截图上传客户端。

## 当前状态

核心的登录、上传、浏览、复制链接、删除、用户隔离和自动清理链路已经实现。

Linux x86_64 后端、Android ARM64 App 和 macOS 通用客户端均可通过 GitHub Release 获取。

项目已经在 Android 13 / Linux 4.14 设备上完成浏览器到真机的端到端验证。

## 已实现功能

### Web 管理网页

- 使用长期 Token 换取 `HttpOnly` Session Cookie，浏览器不持久化 Token。
- 支持直接粘贴图片并上传。
- PNG/JPEG 可在 Web Worker 中预压缩为 WebP，失败时自动回退原文件。
- 页面顶部显示非阻塞上传进度和结果提示。
- 支持最近 7 天和全部图片两个范围。
- 图片按 `Asia/Shanghai` 日期倒序展示。
- 支持缩略图时间线、完整图片预览和公开链接复制。
- 支持单张永久删除、长按多选、桌面空白区域拖拽框选和批量永久删除。
- 浏览器 Tab 从隐藏恢复为可见时，自动重新查询当前图片列表。
- 管理员可创建用户空间，新 Token 只显示一次。

### Go 图床后端

- 前端静态资源、SQLite、时区数据和 WebP 编解码能力内嵌在同一个二进制中。
- 支持 PNG、JPEG、GIF 和 WebP 上传，并校验真实格式、文件大小和像素数。
- 为静态图片保存 WebP 原图，为图片异步生成 WebP 缩略图。
- 通过稳定空间 ID 隔离用户、图片、配额和访问频率。
- 每个用户默认配额为 10 GiB。
- 每个用户默认保留图片 90 天，到期后自动永久清理。
- 支持配置型多 Token 空间和管理员动态创建用户。
- Token 轮换不会改变空间归属，也不会重置限流状态。
- 上传、原图、缩略图和登录接口均有内存限流。
- 支持优雅关闭、健康检查和可配置 HTTP 超时。
- 可选维护一条主机密钥固定、两端均限制为回环地址的 SSH 反向隧道。

### Linux 后端

- GitHub Release 提供无动态库依赖的 Linux x86_64 单文件。
- 发布产物已内嵌 Web 管理网页，运行时不需要 Go、Node.js 或 Docker。
- 支持通过 systemd 或现有进程管理器长期运行。
- 支持使用 Caddy、Nginx 等外部 HTTPS 反向代理。
- 源码同时支持构建 Linux ARM64 单文件。

### Android 管理 App

- 支持 Android 8.0（API 26）及以上的 ARM64 设备。
- 将 Go 后端作为 App 私有子进程运行，不需要 Root。
- 支持启动、停止、重启和查看服务状态。
- 支持配置端口、访问模式、Token 和管理员空间。
- 支持查看日志、存储占用、PID、运行时长和后端 RSS。
- Go 子进程异常退出或健康检查持续失败时自动恢复。
- 支持开机后恢复用户先前要求运行的服务。
- 可选配置受限 SSH 反向隧道和断线自动重连。

### macOS 截图客户端

- 原生 macOS 14+ 菜单栏应用，不显示 Dock 图标。
- 默认全局快捷键为 `F1`，支持用户手动修改。
- 支持多显示器区域截图、对应屏幕原位置贴图和 Retina 原生像素输出。
- 截图完成后默认可直接拖动选区，标注工具需要手动选择并可再次点击取消。
- 方框、箭头或文字绘制完成后保持当前选中；工具仍激活时也能直接移动或缩放当前标注。
- 点击空白处开始绘制下一个标注；取消当前工具后可编辑任意已有标注。
- 支持像素放大预览、坐标和颜色值显示。
- 支持方框、箭头和文字标注。
- 方框与箭头共享线宽设置，文字字号独立调整，并持久化上次设置。
- 绘制过程中或绘制完成且标注仍为当前对象时，滚轮会直接调整该方框、箭头的线宽或文字字号。
- 支持撤销、复制截图、贴图置顶和上传图片。
- 未配置有效的服务地址和 Token 时隐藏上传按钮，并禁用回车上传。
- 上传成功后自动复制公开 URL。
- 配置保存在固定应用数据目录，不访问 macOS 钥匙串。
- 自动检查经过签名的 GitHub Release，并支持在应用内完成更新与重启。

## 当前未实现

- 图库列表目前最多读取最近 100 张，尚未实现游标分页和滚动加载。
- Android App 尚未提供正式的数据导出和备份界面。
- macOS 截图客户端尚未实现马赛克、画笔、窗口吸附、长截图和本地历史记录。
- 核心服务不管理域名、DDNS、TLS 证书或外部反向代理。
- Linux 后端不包含自动更新器或系统服务安装器。

## 文档

### 使用和部署

- [Linux x86_64 后端部署](docs/linux-amd64.md)
- [Android 管理 App](docs/android-app.md)
- [macOS 截图上传客户端](docs/macos-shot.md)
- [前端实现与开发](docs/frontend.md)
- [内网 HTTP 开发部署](docs/lan-development.md)
- [外部 HTTPS 反向代理契约](docs/reverse-proxy.md)
- [Root 实例迁移到 Android App](docs/root-to-app-migration.md)

### 设计和记录

- [v1 需求基线](docs/requirements-v1.md)
- [v1 技术设计](docs/technical-design-v1.md)
- [后端链路预研报告](docs/backend-spike.md)
- [版本变更记录](CHANGELOG.md)

## 本地构建和运行

### 1. 准备 Token

复制示例配置：

```bash
cp tokens.example.json tokens.json
chmod 600 tokens.json
```

Token 文件是一个 JSON 对象。对象 key 是稳定空间 ID，value 是该空间的长期 Token：

```json
{
  "alice": "replace-with-a-long-random-token",
  "bob": "replace-with-another-long-random-token"
}
```

空间 ID 只能包含字母、数字、下划线和连字符，最多 64 个字符。

空间 ID 决定数据归属。轮换 Token 时只修改对应 value，不要修改空间 ID。

实际使用的 `tokens.json` 已被 `.gitignore` 排除，不应提交到仓库。

### 2. 构建 Linux x86_64 后端

```bash
make frontend-install
make build-amd64
```

输出文件：

```text
dist/phone-image-host-linux-amd64
```

### 3. 启动本地 HTTP 服务

```bash
PIH_TOKENS_FILE='./tokens.json' \
PIH_ADMIN_SPACE_ID='alice' \
PIH_COOKIE_SECURE=false \
./dist/phone-image-host-linux-amd64
```

默认监听地址为 `127.0.0.1:8080`。

`PIH_COOKIE_SECURE=false` 只适用于本机或可信局域网 HTTP。通过外部 HTTPS 入口使用时，应保留默认值 `true`。

只有一个配置空间时可以省略 `PIH_ADMIN_SPACE_ID`。配置多个空间时，必须明确指定其中一个管理员空间。

也可以通过 `PIH_TOKENS` 传入 JSON，或通过旧版 `PIH_TOKEN` 配置单空间。`PIH_TOKENS_FILE`、`PIH_TOKENS` 和 `PIH_TOKEN` 三者只能选择一个。

## 常用验证命令

```bash
make test
make build-amd64
make build-arm64
make android-test
make android-debug
```

macOS 环境还可以运行：

```bash
make macos-test
make macos-build
```
