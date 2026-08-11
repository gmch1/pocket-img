# PocketIMG

面向单实例、自托管场景的轻量图床，计划部署在一台大容量 Android 设备上。

当前已完成可用的 React 前端、后端关键链路和多 Token 空间隔离。前端支持 Token 换会话、粘贴上传、上传状态、时间筛选、瀑布流、公开链接复制、图片预览、长按多选和永久删除；构建结果直接嵌入 Go 服务。仓库中的服务可以构建为无动态库依赖的 Linux ARM64 单文件，并已在目标 Android 13 / Linux 4.14 设备上通过 PC 浏览器到真机的端到端验证。它仍未覆盖游标滚动分页、异常文件恢复等全部 v1 生产能力。

- [v1 需求基线](docs/requirements-v1.md)
- [v1 技术设计](docs/technical-design-v1.md)
- [后端链路预研报告](docs/backend-spike.md)
- [前端实现与开发](docs/frontend.md)
- [内网 HTTP 开发部署](docs/lan-development.md)

推荐使用权限为 `0600` 的 Token 配置文件。对象的 key 是稳定空间 ID，value 是该空间当前使用的长期 Token：

```json
{
  "alice": "replace-with-a-long-random-token",
  "bob": "replace-with-another-long-random-token"
}
```

仓库提供了可复制的 [`tokens.example.json`](tokens.example.json)，实际的 `tokens.json` 已加入 `.gitignore`。

空间 ID 只能包含字母、数字、下划线和连字符，最多 64 个字符。它决定数据归属，不应随意改名；轮换 Token 时只修改对应 value 并重启服务。删除某个配置项会禁用该空间的管理登录，但不会自动删除图片或使既有公开直链失效。

本地运行：

```bash
make build

PIH_TOKENS_FILE='./tokens.json' \
PIH_COOKIE_SECURE=false \
./dist/phone-image-host-linux-amd64
```

`PIH_COOKIE_SECURE=false` 只用于本机或可信局域网 HTTP 调试。通过外部 HTTPS 入口提供服务时应保留默认值 `true`。

实际开发 Token 可保存在已忽略的 `tokens.json`；Android 设备上的构建、启动、停止和日志命令见[内网部署说明](docs/lan-development.md)。域名、TLS、DDNS 和反向代理属于外部运维设施，本仓库不保存这些配置。

也可通过 `PIH_TOKENS='{"alice":"token-a","bob":"token-b"}'` 传入 JSON。旧的单空间 `PIH_TOKEN` 仍受支持，并自动使用空间 ID `default`；三种配置方式只能选择一种。

常用验证命令：

```bash
make test
make build-arm64
```

前端开发和当前功能边界见[前端实现与开发](docs/frontend.md)。
