# 内网 HTTP 开发部署

状态：部署模板已验证
日期：2026-08-12

## 部署参数

| 项目 | 值 |
| --- | --- |
| 访问地址 | `http://<device-lan-ip>:8080` |
| 前端页面 | 与访问地址相同，由 ARM64 二进制内嵌提供 |
| 健康检查 | `http://<device-lan-ip>:8080/healthz` |
| 手机目录 | `/data/local/tmp/phone-image-host-dev` |
| 数据目录 | `/data/local/tmp/phone-image-host-dev/data` |
| 运行用户 | Android `shell`，不是 root |
| HTTPS / 外部转发 | 不属于本仓库 |
| 开机自启 | 未启用，手机重启后需手动启动 |

Token 的开发配置保存在本机项目根目录 `tokens.json`，该文件已被 `.gitignore` 排除；手机上对应文件权限为 `0600`。不要把实际 Token 提交到版本库或复制到公开日志。

配置包含多个空间时，还必须给启动环境设置 `PIH_ADMIN_SPACE_ID=<主空间 ID>`；只有一个空间时会自动成为管理员。管理员在 Web 页面创建的用户保存在 SQLite，明文 Token 不写回 `tokens.json`。

## 生命周期

重新构建并部署二进制。`make build-arm64` 会先构建 React 前端并将其嵌入 ARM64 产物，不需要另外推送静态文件：

```bash
make build-arm64
adb -s <adb-serial> shell \
  /data/local/tmp/phone-image-host-dev/stop-dev.sh
adb -s <adb-serial> push \
  dist/phone-image-host-linux-arm64 \
  /data/local/tmp/phone-image-host-dev/phone-image-host
adb -s <adb-serial> shell \
  chmod 755 /data/local/tmp/phone-image-host-dev/phone-image-host
adb -s <adb-serial> shell \
  /data/local/tmp/phone-image-host-dev/start-dev.sh
```

启动和停止：

```bash
adb -s <adb-serial> shell \
  /data/local/tmp/phone-image-host-dev/start-dev.sh

adb -s <adb-serial> shell \
  /data/local/tmp/phone-image-host-dev/stop-dev.sh
```

查看状态和日志：

```bash
curl --noproxy '*' http://<device-lan-ip>:8080/healthz

adb -s <adb-serial> shell \
  tail -n 100 /data/local/tmp/phone-image-host-dev/server.log
```

修改 `tokens.json` 后，需要把它重新推送到手机并重启服务。空间 ID 不能随 Token 轮换而改变。

## 当前网络边界

- 开发服务显式监听 `0.0.0.0:8080`，仅用于可信局域网。
- 服务只处理内嵌前端、HTTP API 和公开图片，不实现 DDNS、代理、远程抓图、TLS 或请求转发。
- 内网 HTTP 模式设置 `PIH_COOKIE_SECURE=false`，否则浏览器不会在普通 HTTP 请求中发送 Session Cookie。
- Token 换 Cookie 不能加密链路；同一局域网内能够监听流量的设备仍可能窃取 Token 或 Session。
- 后端不开放 CORS，内嵌前端与 API 同源。本仓库不提供网络代理配置。
- 后端按空间限制上传和图片读取频率，超限返回 `429` 与 `Retry-After`；上传体积、解码像素、队列长度和单 worker 仍共同限制资源占用。
- React 前端已经内嵌完成。域名、HTTPS、DDNS 和反向代理由独立运维项目负责；启用 HTTPS 入口时恢复 `Secure` Cookie。
