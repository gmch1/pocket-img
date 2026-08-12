# PocketIMG

面向单实例、自托管场景的轻量图床，计划部署在一台大容量 Android 设备上。

当前已完成可用的 React 前端、后端关键链路和多 Token 空间隔离。前端支持 Token 换会话、粘贴上传、浏览器 Worker 预压缩、上传状态、时间筛选、瀑布流、公开链接复制、图片预览、长按多选和永久删除；主空间管理员还可以直接创建新用户 Token。每个用户默认最多占用 10 GiB，并默认在 90 天后自动永久清理图片。构建结果直接嵌入 Go 服务。仓库中的服务可以构建为无动态库依赖的 Linux ARM64 单文件，也可以随无需 Root 的 Android 管理 App 运行；App 可选维护一个受严格限制的 SSH 反向隧道，把手机回环 HTTP 服务加密接入外部 HTTPS 边缘节点。项目已在目标 Android 13 / Linux 4.14 设备上通过 PC 浏览器到真机的端到端验证。它仍未覆盖游标滚动分页、Android 数据导出等全部生产能力。

后端按稳定空间 ID 执行内存限流：每空间每小时 500 次上传尝试、500 次公开原图响应，单张缩略图每分钟 5 次且每小时 10 次，全部缩略图每小时 2000 次。上传同时最多 2 个；Token 登录另有来源、全局和空间级令牌桶。超限只返回 `429` 与 `Retry-After`，前端不展示额度，Token 轮换也不会重置计数。

- [v1 需求基线](docs/requirements-v1.md)
- [v1 技术设计](docs/technical-design-v1.md)
- [后端链路预研报告](docs/backend-spike.md)
- [前端实现与开发](docs/frontend.md)
- [内网 HTTP 开发部署](docs/lan-development.md)
- [Android 管理 App](docs/android-app.md)
- [Root 实例迁移到 App](docs/root-to-app-migration.md)
- [外部 HTTPS 反向代理契约](docs/reverse-proxy.md)
- [版本变更记录](CHANGELOG.md)

推荐使用权限为 `0600` 的 Token 配置文件。对象的 key 是稳定空间 ID，value 是该空间当前使用的长期 Token：

```json
{
  "alice": "replace-with-a-long-random-token",
  "bob": "replace-with-another-long-random-token"
}
```

仓库提供了可复制的 [`tokens.example.json`](tokens.example.json)，实际的 `tokens.json` 已加入 `.gitignore`。

空间 ID 只能包含字母、数字、下划线和连字符，最多 64 个字符。它决定数据归属，不应随意改名；轮换配置 Token 时只修改对应 value 并重启服务。管理员在页面创建的用户只把 Token 指纹保存在 SQLite，明文 Token 只显示一次。删除某个配置项会禁用由配置管理的空间登录，但不会立即删除图片；图片仍按该用户的 90 天保留策略清理。

本地运行：

```bash
make build

PIH_TOKENS_FILE='./tokens.json' \
PIH_ADMIN_SPACE_ID='alice' \
PIH_COOKIE_SECURE=false \
./dist/phone-image-host-linux-amd64
```

`PIH_COOKIE_SECURE=false` 只用于本机或可信局域网 HTTP 调试。通过外部 HTTPS 入口提供服务时应保留默认值 `true`。

公网慢速上传可按 Go duration 格式调整 HTTP 超时，例如 `PIH_READ_TIMEOUT=180s`、`PIH_WRITE_TIMEOUT=240s`。域名入口仍由外部运维设施终止 TLS，且必须保留原始 `Host`。Android App 的可选 SSH 隧道只负责传输，不管理 DNS、证书或 Caddy；具体边缘地址、账号、公钥授权和主机指纹属于部署配置，不提交到本仓库。

实际开发 Token 可保存在已忽略的 `tokens.json`；Android 设备上的构建、启动、停止和日志命令见[内网部署说明](docs/lan-development.md)。域名、TLS、DDNS、反向代理和实际 SSH 端点属于外部运维设施，本仓库不保存这些环境配置或任何私钥。

也可通过 `PIH_TOKENS='{"alice":"token-a","bob":"token-b"}'` 传入 JSON。旧的单空间 `PIH_TOKEN` 仍受支持，并自动使用空间 ID `default`；三种配置方式只能选择一种。只有一个配置空间时它自动成为管理员；存在多个配置空间时必须用 `PIH_ADMIN_SPACE_ID` 明确指定其中一个。

常用验证命令：

```bash
make test
make build-arm64
make android-debug
```

前端开发和当前功能边界见[前端实现与开发](docs/frontend.md)。
