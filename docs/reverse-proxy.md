# 外部 HTTPS 反向代理契约

PocketIMG 只处理 HTTP 请求，不内置域名、DDNS、证书申请、TLS 终止、网络中转或 SSH 隧道。外部边缘代理负责 HTTPS，并把请求转发到设备的 HTTP 监听端口。

## 应用侧配置

- Android App 选择“外部 HTTPS”模式，使 `PIH_COOKIE_SECURE=true`。
- 独立二进制部署不显式覆盖 `PIH_COOKIE_SECURE`，使用默认值 `true`。
- 公网慢速上传建议设置 `PIH_READ_TIMEOUT=180s` 与 `PIH_WRITE_TIMEOUT=240s`。
- 上游仅需访问设备 HTTP 端口；不需要知道 Token、空间 ID 或数据路径。

## 代理要求

- TLS 只在外部代理终止。
- 必须保留浏览器请求的原始 `Host`。后端 Origin 校验不信任客户端提供的 `X-Forwarded-Host`。
- HTTP 入口应永久重定向到 HTTPS，并由边缘设置 HSTS。
- 请求体上限至少为 28 MiB，以容纳 25 MiB 图片和 multipart 开销。
- 上游读写/响应超时应高于应用的 180/240 秒配置，建议不低于 300 秒。
- `/healthz` 可用于内网主动检查；它不包含设备或图库详情。
- `/i/*` 和 `/t/*` 是设计内的公开资源；`/api/*` 仍由 Token 换取的 Session Cookie 保护。

## 不应公开的端口

只允许边缘代理公开 80/443。设备 HTTP 端口、SSH 反向隧道回环端口和数据库文件都不应直接暴露到公网。

## 上线验收

1. HTTPS Token 换 Cookie 响应包含 `Secure`、`HttpOnly`、`SameSite=Strict`。
2. HTTP 域名入口只返回 HTTPS 重定向，不接收管理 Cookie。
3. 正确域名的登录、列表、上传、公开图片和永久删除成功。
4. 伪造 `Origin` 或只伪造 `X-Forwarded-Host` 的写请求返回 `403`。
5. 单个接近 25 MiB 的慢速上传不会被代理提前断开。
6. 隧道或设备服务停止时返回可诊断的 `502/503`，恢复后无需修改 DNS。
