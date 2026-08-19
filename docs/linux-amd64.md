# Linux x86_64 后端部署

PocketIMG 的 Linux x86_64 版本是独立 Go 服务端，不包含 Android 管理壳或 macOS 截图客户端。单个可执行文件已经内嵌网页前端、SQLite、时区数据和 WebP 编解码实现，不需要 Node.js、Go、Docker 或额外动态库就能运行。

## 支持范围

- CPU 架构：64 位 x86，也就是 `x86_64` / `amd64`；不支持 32 位 `i386` / `i686`。
- 操作系统：Linux。发布流程会验证产物为静态链接的 x86-64 ELF，因此不依赖发行版提供 glibc、SQLite 或 WebP 动态库。
- 服务形态：单个 HTTP 服务进程，同时提供管理网页、API、公开图片和健康检查。
- 不包含：桌面截图功能、Android 管理界面、TLS 证书管理、域名配置、自动更新和系统服务安装器。

## 获取与校验

GitHub Release 提供以下两个文件：

- `PocketIMG-<version>-linux-amd64`
- `PocketIMG-<version>-linux-amd64.sha256`

正式服务端版本使用 `server-v<version>` 标签独立发布，不会同时构建 Android 或 macOS。完整规则见[组件发布流程](releases.md)。

下载到同一目录后执行：

```bash
sha256sum --check PocketIMG-<version>-linux-amd64.sha256
chmod 755 PocketIMG-<version>-linux-amd64
```

也可以在源码目录构建同类产物：

```bash
make build-amd64
```

输出位于 `dist/phone-image-host-linux-amd64`。构建过程需要 Go 和 Node.js，运行发布产物不需要。

## 快速启动

准备权限为 `0600` 的 Token 配置文件：

```json
{
  "admin": "replace-with-a-long-random-token"
}
```

默认只监听 `127.0.0.1:8080`，数据写入当前目录下的 `data`。生产环境建议明确指定绝对路径：

```bash
PIH_TOKENS_FILE='/etc/pocketimg/tokens.json' \
PIH_ADMIN_SPACE_ID='admin' \
PIH_DATA_DIR='/var/lib/pocketimg' \
PIH_ADDR='127.0.0.1:8080' \
./PocketIMG-<version>-linux-amd64
```

只有一个配置空间时可以省略 `PIH_ADMIN_SPACE_ID`。也可使用 `PIH_TOKENS` 或旧的单空间 `PIH_TOKEN`，三种 Token 来源只能选择一种。

访问 `/healthz` 可以检查服务状态：

```bash
curl --fail http://127.0.0.1:8080/healthz
```

正常响应为：

```json
{"status":"ok"}
```

进程接收 `SIGINT` 或 `SIGTERM` 后会停止接收新请求，并在最多 10 秒的关闭窗口内结束 HTTP 服务。

## 配置参考

除 Token 来源外，所有配置均为环境变量。布尔值使用 `true` 或 `false`，超时使用 Go duration 格式，例如 `30s`、`2m`。

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PIH_TOKENS_FILE` | 无 | 推荐方式；指向权限受限的 Token JSON 文件。 |
| `PIH_TOKENS` | 无 | 直接传入 Token JSON；不建议放进可能被日志或进程列表采集的启动脚本。 |
| `PIH_TOKEN` | 无 | 兼容旧部署的单空间 Token，空间 ID 固定为 `default`。 |
| `PIH_ADMIN_SPACE_ID` | 单空间时自动选择 | 多空间时指定管理员空间；该值必须存在于 Token 映射中。 |
| `PIH_DATA_DIR` | `./data` | SQLite、原图、缩略图和临时文件目录。生产环境应使用绝对路径。 |
| `PIH_ADDR` | `127.0.0.1:8080` | HTTP 监听地址。与本机反向代理配合时应保留回环地址。 |
| `PIH_COOKIE_SECURE` | `true` | 是否给 Session Cookie 添加 `Secure`。只有可信局域网纯 HTTP 才设为 `false`。 |
| `PIH_READ_TIMEOUT` | `60s` | HTTP 请求读取超时；公网慢速上传可提高到 `180s`。 |
| `PIH_WRITE_TIMEOUT` | `120s` | HTTP 响应写入超时；公网慢速上传可提高到 `240s`。 |

`PIH_TOKENS_FILE`、`PIH_TOKENS`、`PIH_TOKEN` 必须且只能配置一个。空间 ID 是数据所有权的一部分；轮换 Token 时只修改同一个空间 ID 对应的值，不要为了换 Token 而改名。

Go 后端也保留可选的受限反向 SSH 隧道。仅当确实需要它时设置 `PIH_TUNNEL_ENABLED=true`，并同时提供以下配置：

| 环境变量 | 说明 |
| --- | --- |
| `PIH_TUNNEL_SERVER` | SSH 服务器的 `host:port`。 |
| `PIH_TUNNEL_USER` | 只允许反向转发的受限 SSH 用户。 |
| `PIH_TUNNEL_REMOTE_ADDR` | 远端监听地址，代码强制要求数字回环地址，例如 `127.0.0.1:18080`。 |
| `PIH_TUNNEL_LOCAL_ADDR` | 本机后端地址，代码强制要求数字回环地址，例如 `127.0.0.1:8080`。 |
| `PIH_TUNNEL_PRIVATE_KEY` | 设备 Ed25519 私钥路径；不存在时自动生成并设为 `0600`。 |
| `PIH_TUNNEL_PUBLIC_KEY` | 对应公钥输出路径。 |
| `PIH_TUNNEL_STATUS_FILE` | 隧道状态 JSON 路径。 |
| `PIH_TUNNEL_HOST_KEY_SHA256` | 必须显式固定的 SSH Ed25519 主机密钥 SHA-256 指纹。 |
| `PIH_TUNNEL_KEY_COMMENT` | 可选的公钥注释。 |

不使用隧道时不要设置这些变量。隧道两端都限制为回环地址，它不能代替公网边缘的 HTTPS 终止。

## 数据目录

首次启动会自动创建以下内容：

```text
/var/lib/pocketimg/
├── metadata.sqlite3
├── metadata.sqlite3-wal
├── metadata.sqlite3-shm
├── objects/
│   └── <space-id>/ab/cd/<opaque-id>.webp|gif
├── thumbnails/
│   └── <space-id>/ab/cd/<opaque-id>.webp
└── tmp/
```

SQLite 只保存元数据、用户、Session 和缩略图任务，图片本身位于 `objects/` 与 `thumbnails/`。不要只备份数据库或只复制图片目录，两者必须保持一致；数据目录也不应放在网络文件系统上。

## 使用 systemd 长期运行

以下示例使用独立的低权限账号，服务仍然只是同一个 Go 二进制，没有额外管理壳。不同发行版的 `useradd` 路径可能略有差异。

```bash
sudo useradd --system \
  --home-dir /var/lib/pocketimg \
  --create-home \
  --shell /usr/sbin/nologin \
  pocketimg

sudo install -o root -g root -m 0755 \
  PocketIMG-<version>-linux-amd64 \
  /usr/local/bin/pocketimg
sudo install -d -o pocketimg -g pocketimg -m 0750 \
  /etc/pocketimg \
  /var/lib/pocketimg
sudo install -o pocketimg -g pocketimg -m 0600 \
  tokens.json \
  /etc/pocketimg/tokens.json
```

创建 `/etc/systemd/system/pocketimg.service`：

```ini
[Unit]
Description=PocketIMG image hosting backend
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=pocketimg
Group=pocketimg
ExecStart=/usr/local/bin/pocketimg
Environment=PIH_TOKENS_FILE=/etc/pocketimg/tokens.json
Environment=PIH_ADMIN_SPACE_ID=admin
Environment=PIH_DATA_DIR=/var/lib/pocketimg
Environment=PIH_ADDR=127.0.0.1:8080
Environment=PIH_COOKIE_SECURE=true
Restart=on-failure
RestartSec=5s
TimeoutStopSec=20s
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/pocketimg
ReadWritePaths=/var/lib/pocketimg

[Install]
WantedBy=multi-user.target
```

如果 Token 文件中的管理员空间不是 `admin`，同步修改 `PIH_ADMIN_SPACE_ID`。启用可选 SSH 隧道时，还要把密钥和状态文件放进服务可写目录，并在 unit 中增加对应环境变量。

加载并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pocketimg
sudo systemctl status pocketimg
curl --fail http://127.0.0.1:8080/healthz
```

查看日志：

```bash
journalctl -u pocketimg -n 100 --no-pager
journalctl -u pocketimg -f
```

## 网络边界

Go 服务只提供 HTTP，不负责 TLS 证书、域名、自动更新或系统进程守护。公网部署应让 Caddy、Nginx 等 HTTPS 反向代理访问回环地址，并保留默认的 `PIH_COOKIE_SECURE=true`。仅在可信局域网直接使用 HTTP 时才设置 `PIH_COOKIE_SECURE=false`。

反向代理必须保留原始 `Host`，覆盖写入真实来源对应的 `X-PocketIMG-Client-IP`，允许至少 28 MiB 请求体，并把上游超时设置得高于应用超时。只公开边缘的 80/443，不要把 PocketIMG HTTP 端口或 SQLite 文件直接暴露到公网。完整要求和上线检查见[外部 HTTPS 反向代理契约](reverse-proxy.md)。

如果只在可信局域网使用并把 `PIH_ADDR` 改为 `0.0.0.0:8080`，浏览器应通过 HTTP 访问且需要 `PIH_COOKIE_SECURE=false`。这种模式没有链路加密，不应跨越不可信网络。

## 升级

升级不需要重新构建前端，也不要改动数据目录：

```bash
sha256sum --check PocketIMG-<new-version>-linux-amd64.sha256
sudo systemctl stop pocketimg
sudo install -o root -g root -m 0755 \
  PocketIMG-<new-version>-linux-amd64 \
  /usr/local/bin/pocketimg
sudo systemctl start pocketimg
curl --fail http://127.0.0.1:8080/healthz
```

启动时会自动执行已支持的数据库迁移。升级前仍应先做完整备份；如果需要回退，应同时恢复升级前的数据目录，而不是只替换旧二进制。

## 备份与恢复

为了让 SQLite 和图片文件处于同一个一致时间点，最简单可靠的方式是先停止服务，再同时备份数据目录和 Token 文件：

```bash
sudo systemctl stop pocketimg
sudo tar --create --gzip \
  --file pocketimg-backup-$(date +%Y%m%d-%H%M%S).tar.gz \
  /var/lib/pocketimg \
  /etc/pocketimg/tokens.json
sudo systemctl start pocketimg
```

备份中包含长期 Token、用户元数据和所有图片，应按敏感数据保存并限制读取权限。恢复时停止服务，把数据目录和 Token 文件作为同一组恢复，确认所有者仍为 `pocketimg:pocketimg`，再启动并检查 `/healthz`、登录、图片列表和既有公开 URL。

## 故障排查

- 启动提示未配置 Token：确认三种 Token 来源恰好设置一个，并检查 systemd 是否能读取 Token 文件。
- 多空间启动失败：确认 `PIH_ADMIN_SPACE_ID` 与 Token JSON 中某个稳定空间 ID 完全一致。
- HTTP 页面无法保持登录：局域网纯 HTTP 使用 `PIH_COOKIE_SECURE=false`；HTTPS 入口保持默认 `true`。
- 代理上传中断：提高 `PIH_READ_TIMEOUT`、`PIH_WRITE_TIMEOUT`，并确保代理请求体上限至少 28 MiB、上游超时不低于应用配置。
- 权限错误：服务用户必须能读 Token 文件，并能完整读写 `PIH_DATA_DIR`。
- 页面没有更新：确认下载的是目标 Release 的 Linux amd64 文件并已重启服务；网页资源已经内嵌在二进制中。
