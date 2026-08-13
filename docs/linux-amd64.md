# Linux x86_64 后端部署

PocketIMG 的 Linux x86_64 版本是独立 Go 服务端，不包含 Android 管理壳或 macOS 截图客户端。单个可执行文件已经内嵌网页前端、SQLite、时区数据和 WebP 编解码实现，不需要 Node.js、Go、Docker 或额外动态库就能运行。

## 获取与校验

GitHub Release 提供以下两个文件：

- `PocketIMG-<version>-linux-amd64`
- `PocketIMG-<version>-linux-amd64.sha256`

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

## 配置和运行

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

## 网络边界

Go 服务只提供 HTTP，不负责 TLS 证书、域名、自动更新或系统进程守护。公网部署应让 Caddy、Nginx 等 HTTPS 反向代理访问回环地址，并保留默认的 `PIH_COOKIE_SECURE=true`。仅在可信局域网直接使用 HTTP 时才设置 `PIH_COOKIE_SECURE=false`。

长期运行可以交给服务器已有的 systemd、容器或其他进程管理器；它们不属于 PocketIMG 后端产物的一部分。反向代理的安全要求见[外部 HTTPS 反向代理契约](reverse-proxy.md)。
