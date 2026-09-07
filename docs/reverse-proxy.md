# 外部 HTTPS 反向代理契约

PocketIMG 后端只提供 HTTP，不内置域名、DDNS、证书申请或 TLS 终止。新的一键安装默认监听 `127.0.0.1:18746`，支持 `--port` 自定义；用户自行配置 Nginx、Caddy 或已有网关接收公网 HTTPS，再转发给实际配置的 HTTP 端口。

浏览器或 Mac 使用 `https://img.example.com`，反向代理访问 `http://127.0.0.1:18746`。已有部署可能仍使用 `8080` 或其他端口，以部署配置为准。安装脚本不会修改 Nginx/Caddy、申请证书或开放防火墙端口。`PIH_COOKIE_SECURE=true` 只是 Cookie 的 HTTPS 安全属性，不会让后端端口变成 HTTPS。

Android 部署可选择维护一条到边缘服务器回环端口的 SSH 反向隧道，HTTPS 仍由外部代理负责。

## 应用侧配置

- 独立部署或一键安装保留 `PIH_COOKIE_SECURE=true`；Docker 放到 HTTPS 入口后也需显式设置该值（Compose 默认面向局域网 HTTP，为 `false`）。
- Android App 选择“外部 HTTPS”模式，使 `PIH_COOKIE_SECURE=true`。
- 使用内置 SSH 隧道时固定服务器主机密钥指纹、使用设备独立密钥和无命令权限的受限账号，并在切换完成后让后端只监听 `127.0.0.1`。
- 独立二进制部署不显式覆盖 `PIH_COOKIE_SECURE`，使用默认值 `true`。
- 公网慢速上传建议设置 `PIH_READ_TIMEOUT=180s` 与 `PIH_WRITE_TIMEOUT=240s`。
- 上游仅需访问设备 HTTP 端口；不需要知道 Token、空间 ID 或数据路径。

## 代理要求

- TLS 只在外部代理终止。
- 必须保留浏览器请求的原始 `Host`。后端 Origin 校验不信任客户端提供的 `X-Forwarded-Host`。
- 必须覆盖写入 `X-PocketIMG-Client-IP` 为边缘实际看到的客户端 IP，不能透传客户端同名请求头。后端只在直连对端为回环地址时使用它限制无效 Token 登录；图片与上传额度按所属空间计算。
- HTTP 入口应永久重定向到 HTTPS，并由边缘设置 HSTS。
- 请求体上限至少为 28 MiB，以容纳 25 MiB 图片和 multipart 开销。
- 上游读写/响应超时应高于应用的 180/240 秒配置，建议不低于 300 秒。
- `/healthz` 可用于内网主动检查；它不包含设备或图库详情。
- `/i/*` 和 `/t/*` 是设计内的公开资源；`/api/*` 仍由 Token 换取的 Session Cookie 保护。

## 不应公开的端口

只允许边缘代理公开 80/443。设备 HTTP 端口、SSH 反向隧道回环端口和数据库文件都不应直接暴露到公网。内置隧道还会在代码中拒绝非回环远端监听和非回环本机目标。

## 上线验收

1. HTTPS Token 换 Cookie 响应包含 `Secure`、`HttpOnly`、`SameSite=Strict`。
2. HTTP 域名入口只返回 HTTPS 重定向，不接收管理 Cookie。
3. 正确域名的登录、列表、上传、公开图片和永久删除成功。
4. 伪造 `Origin` 或只伪造 `X-Forwarded-Host` 的写请求返回 `403`。
5. 单个接近 25 MiB 的慢速上传不会被代理提前断开。
6. 隧道或设备服务停止时返回可诊断的 `502/503`，恢复后无需修改 DNS。
7. 同一来源连续触发登录限制时返回 `429` 和 `Retry-After`，伪造公开请求中的 `X-PocketIMG-Client-IP` 不会被原样转发。
