# Root 开发实例迁移到 Android App

本流程只迁移 PocketIMG 的运行数据，不配置域名、TLS、DNS、Caddy 或 SSH 隧道。迁移期间旧 Root 服务会停止，但目录保持原样，验证完成前可以随时回滚。

## 迁移内容

- `metadata.sqlite3` 及 WAL 文件
- `objects/` 与 `thumbnails/`
- Token 配置和稳定空间 ID
- 对应的文件权限和 App UID/GID

不能只复制图片文件。图库记录通过稳定空间 ID 隔离；如果旧实例和 App 的空间 ID 不同，替换 Token 或只复制 SQLite 都会导致登录后看不到历史图片。

## 前置备份

先停止写入并把旧实例的 `data/` 与 `tokens.json` 备份到受限的本地目录。备份包含长期 Token，必须使用 `0600` 权限，并且不得放入 Git。

## 执行迁移

安装相同签名的新版本 APK，但先不要启动 App 后端。目标设备已通过 `adb` 连接且 Root 由设备所有者授权时运行：

```bash
ANDROID_SERIAL='<adb-serial>' ./deploy/android/migrate-root-to-app.sh migrate
```

脚本会：

1. 停止 App 与 `/data/local/tmp/phone-image-host-dev` 中的旧服务。
2. 把 App 原有空数据移动到 `service-data.before-root-migration`。
3. 复制旧数据和完整 Token 映射到 App 私有目录。
4. 修正所有权和权限。
5. 保持旧 Root 目录停止但不删除。

新版 App 会从迁入的 Token 配置中选择既有空间 ID，不会强制改名为 `mobile`。

## 验证

在 App 中选择访问模式并启动服务，然后确认：

- `/healthz` 返回 `200`。
- 既有公开图片 URL 内容和哈希不变。
- 使用原 Token 能看到迁移前图库。
- 新上传、缩略图、删除均正常。
- App 停止后端时端口释放，重新启动后数据仍在。

确认 App 正常后再接入外部 HTTPS 代理。外部 HTTPS 模式会使用 Secure Session Cookie，管理页面需要从 HTTPS 域名访问；局域网 HTTP 仅保留健康检查和公开图片能力。

## 回滚

验证失败时运行：

```bash
ANDROID_SERIAL='<adb-serial>' ./deploy/android/migrate-root-to-app.sh rollback
```

脚本会恢复 App 迁移前的数据和 Token，并重新启动旧 Root 服务。失败的迁入数据会改名保留，便于排查，不会被直接删除。
