# 飞牛 fnOS 部署与应用打包

PocketIMG 的 fnOS 版本采用一个 Docker 容器：同一个 Go 进程提供内嵌的 React 页面、API、SQLite 和媒体文件服务。fnOS 的 `.fpk` 只负责应用元数据、桌面入口、Docker Compose 编排、生命周期状态和本地客户端安装包，不再引入 PostgreSQL、Redis 或第二个业务容器。

官方参考：

- [Docker 应用案例](https://developer.fnnas.com/docs/examples/docker)
- [应用框架](https://developer.fnnas.com/docs/core-concepts/framework)
- [应用资源](https://developer.fnnas.com/docs/core-concepts/resource)
- [应用入口](https://developer.fnnas.com/docs/core-concepts/app-entry)
- [统一网关](https://developer.fnnas.com/docs/core-concepts/gateway-registration)
- [Manifest](https://developer.fnnas.com/docs/core-concepts/manifest)
- [fnpack](https://developer.fnnas.com/docs/cli/fnpack)

## 访问与认证模型

fnOS 部署有两个不同用途的入口，不能混为一个地址：

```text
fnOS 桌面或应用中心
  └── /app/pocket-img
      └── fnOS 统一网关验证 NAS 登录态
          └── /var/apps/pocket-img/target/app.sock
              └── Web 管理页和需要登录的 API

Mac 客户端、公开图片和视频
  └── http://<NAS 地址>:8080 或管理员配置的外部 HTTPS 地址
      └── PocketIMG Mac 客户端连接凭证 / Session
          ├── 上传 API
          └── /i/ 与 /t/ 公共媒体
```

统一网关会在转发前校验 fnOS 登录态，并提供以下身份 Header：

```text
X-Trim-Userid
X-Trim-Isadmin
X-Trim-Username
```

后端应使用 `X-Trim-Userid` 作为稳定用户标识，用户名只用于显示，管理员操作每次根据 `X-Trim-Isadmin` 检查。Header 只有在 `app.sock` listener 上可信；TCP listener 必须忽略客户端自行发送的所有 `X-Trim-*` Header，避免局域网请求伪造管理员。

fnOS 网页通过 SSO 识别当前飞牛用户，并把该用户稳定映射到一个 PocketIMG 图库空间；该用户以后进入网页，或在 Mac 使用自己生成的连接凭证，看到的都是同一份图库。这个过程不会为用户导出 fnOS 登录 Token，也不会把飞牛管理员凭据保存为 PocketIMG Token。

fnOS 当前没有供原生客户端复用 SSO 的用户名/密码登录接口。因此，当前飞牛用户需要在引导页单独生成可撤销的“Mac 客户端连接凭证”。该凭证只绑定当前用户的 PocketIMG 图库，用于 Mac 客户端换取 Session，不继承飞牛或 PocketIMG 的管理员权限。服务端只保存凭证哈希，明文只在生成时完整显示一次；丢失后无法找回，只能重新生成，旧凭证和它签发的客户端 Session 会立即失效。

不得把飞牛 Cookie、密码、管理员凭据或 `TRIM_API_TOKEN` 暴露给 Mac 客户端。`TRIM_API_TOKEN` 是应用调用 fnOS 文件或平台开放 API 的凭据，不是用户登录凭据，本方案不使用也不向容器传递它。

公开媒体不能放在统一网关之后。聊天软件和链接接收者通常没有 NAS Session Cookie；若 `/i/...` 经过统一网关，媒体将无法加载。管理员页面可以走 SSO，但复制出的公开 URL 必须使用 TCP 服务或单独配置的外部 HTTPS 基址。

## FPK 目录

模板位于 `deploy/fnos/pocket-img`：

```text
deploy/fnos/pocket-img/
├── app/
│   ├── docker/
│   │   └── docker-compose.yaml
│   ├── downloads/
│   │   └── manifest.json
│   └── ui/
│       ├── config
│       └── images/
│           ├── icon_64.png
│           └── icon_256.png
├── cmd/
│   ├── main
│   ├── install_init
│   ├── install_callback
│   ├── upgrade_init
│   ├── upgrade_callback
│   ├── uninstall_init
│   ├── uninstall_callback
│   ├── config_init
│   └── config_callback
├── config/
│   ├── privilege
│   └── resource
├── wizard/
├── manifest
├── ICON.PNG
└── ICON_256.PNG
```

`manifest`、`config/resource`、`config/privilege` 和 `app/ui/config` 都没有文件扩展名。`manifest` 使用 `key=value`，其余三个配置文件使用 JSON。

固定标识如下，发布后不能随意更名：

| 项目 | 值 |
| --- | --- |
| appname | `pocket-img` |
| 桌面入口 ID | `pocket-img.main` |
| Docker 项目名 | `pocket-img` |
| 容器名 | `pocket-img` |
| gatewayPrefix | `/app/pocket-img` |
| gatewaySocket | `app.sock` |
| 最低 fnOS 版本 | `1.1.3100` |
| 宿主服务端口 | `manifest.service_port`，当前为 `8080` |
| 容器 HTTP 端口 | `8080` |

包本身只有 Compose、脚本、JSON、图标和客户端 ZIP，因此使用 `platform=all`。这不代表容器镜像可以只有一个架构；相同版本标签必须在 GHCR 同时提供 `linux/amd64` 与 `linux/arm64`。

## Compose 约定

模板中的镜像为：

```text
ghcr.io/gmch1/pocket-img:__VERSION__
```

`__VERSION__` 只能由构建脚本替换。不要直接对模板运行 `fnpack build`，也不要在发布包中使用 `latest`。

容器挂载和环境变量：

| fnOS 路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `${TRIM_PKGVAR}` | `/data` | SQLite、WAL、原图、缩略图、临时文件 |
| `${TRIM_APPDEST}` | `/fnos-target` | 创建 `/fnos-target/app.sock` |
| `${TRIM_APPDEST}/downloads` | `/downloads`，只读 | 本地 PocketIMG Shot 安装包和清单 |

```text
PIH_DATA_DIR=/data
PIH_ADDR=0.0.0.0:8080
PIH_COOKIE_SECURE=false
PIH_FNOS_SOCKET=/fnos-target/app.sock
PIH_FNOS_PREFIX=/app/pocket-img
PIH_SERVICE_PORT=${TRIM_SERVICE_PORT}
PIH_DOWNLOADS_DIR=/downloads
PIH_VERSION=<FPK 版本>
```

后端需要同时监听 TCP 和 Unix Socket，并在启动时安全删除自己遗留的旧 `app.sock`。停止时应关闭两个 listener。不要把 SQLite 数据放进镜像、`TRIM_APPDEST` 或用户共享目录；数据库、WAL 和对象目录必须作为一个整体备份和恢复。

`config/privilege` 中的 package 用户不会自动决定容器内 UID。Compose 使用 `${TRIM_UID}:${TRIM_GID}` 显式让容器进程采用 fnOS 分配的 package 用户，并以镜像内的 `10001:10001` 作为非 fnOS 环境的后备值。仍需在 amd64、arm64 真机上验证它对 `/data` 和 `/fnos-target` 的权限。

宿主服务端口当前是可信局域网 HTTP，因此模板明确设置 `PIH_COOKIE_SECURE=false`。如果管理员把 TCP 入口放到外部 HTTPS 反向代理之后，正式包需要提供受控配置把它切换为 `true`；不能在不可信网络中直接暴露 8080。

`cmd/main` 的 `start`、`stop` 是安全 no-op，因为 Docker 项目生命周期由 fnOS 根据 `config/resource` 管理；`status` 使用固定容器名检查 `.State.Running`，运行返回 `0`，未运行返回 `3`。其他框架回调当前也是可重复执行的 no-op，后续只有确实需要迁移时再加入逻辑。

## 统一网关路径

fnOS 不会把 `gatewayPrefix` 当成透明前缀。应用实际收到的请求仍可能是：

```http
GET /app/pocket-img/api/images
```

因此 FNOS 构建下的 Vite 静态资源 base、API、SSE 和页面路由都必须兼容 `/app/pocket-img/`。可选择：

1. 前端构建时使用 `/app/pocket-img/` 作为 base，并让后端直接注册该前缀；或
2. Unix Socket listener 在确认请求以该固定前缀开始后 strip prefix，再复用现有根路由 handler，同时让前端通过运行时 base 生成 URL。

不能继续使用无条件的 `fetch("/api/...")`，否则请求会落到 fnOS 自身的 `/api`。直接 TCP 部署仍需保留根路径兼容。

## 本地 macOS 客户端

FNOS 包不在安装时访问 GitHub。发布流水线必须先准备同版本、已签名的 Apple Silicon ZIP，再把它交给打包脚本。当前 Android APK 是“在 Android 上运行后端”的管理壳，不是连接 FNOS 的上传客户端，不应出现在 FNOS 引导页。

安装包清单位于 `app/downloads/manifest.json`。渲染后的格式为：

```json
{
  "schema_version": 1,
  "artifacts": [
    {
      "id": "pocketimg-shot-macos-arm64",
      "display_name": "PocketIMG Shot",
      "version": "0.5.0",
      "platform": "macos",
      "architecture": "arm64",
      "minimum_os_version": "14.0",
      "filename": "PocketIMGShot-0.5.0-macos-arm64.zip",
      "content_type": "application/zip",
      "sha256": "<64 位小写十六进制 SHA-256>"
    }
  ]
}
```

后端只能提供清单中列出的 basename，不能把请求路径直接拼到文件系统。下载响应应设置：

```http
Content-Type: application/zip
Content-Disposition: attachment; filename="PocketIMGShot-0.5.0-macos-arm64.zip"
X-Content-Type-Options: nosniff
```

引导页应同时展示版本、macOS 14+、Apple Silicon 要求和 SHA-256。ZIP 从 NAS 本地返回。打包脚本本身从不下载 Release 资产；正式流水线会接收同一次发布中已签名的 macOS 产物并写进 FPK。NAS 安装完成后，用户下载客户端不依赖 GitHub Release。现有 macOS 客户端安装后的 Sparkle 更新源仍指向 GitHub；若要求后续更新也完全本地化，还需另行提供实例内 appcast 并修改客户端更新源。

## 构建

准备：

- 与目标版本同号的 amd64/arm64 多架构镜像已经推送到 `ghcr.io/gmch1/pocket-img`。
- 已从受信任的发布任务取得并校验签名的 `PocketIMGShot-<version>-macos-arm64.zip`。
- 完整构建已安装 `fnpack`；当前官方文档版本为 1.2.3。

完整构建：

```bash
./scripts/build_fnos_package.sh \
  --version 0.5.0 \
  --macos-zip /secure/artifacts/PocketIMGShot-0.5.0-macos-arm64.zip
```

输出：

```text
dist/fnos/pocket-img-0.5.0.fpk
```

脚本会：

1. 严格校验版本格式和 ZIP 文件。
2. 在临时目录复制 FPK 模板，不修改模板源文件。
3. 要求 ZIP 精确命名为 `PocketIMGShot-<version>-macos-arm64.zip`，避免误打包其他版本。
4. 计算 SHA-256 并写入下载清单。
5. 同时替换 manifest、镜像标签和下载清单中的版本占位符。
6. 检查没有遗留任何 `__PLACEHOLDER__`。
7. 调用 `fnpack build`，并要求只生成一个 `.fpk`。

没有安装 `fnpack` 时可以只生成完全渲染的 staging 目录：

```bash
./scripts/build_fnos_package.sh \
  --version 0.5.0 \
  --macos-zip /secure/artifacts/PocketIMGShot-0.5.0-macos-arm64.zip \
  --stage-only
```

输出：

```text
dist/fnos/pocket-img-0.5.0/
```

不加 `--stage-only` 且系统找不到 `fnpack` 时，脚本会明确失败，不会生成一个看似成功的不完整包。脚本也不会覆盖已有的同版本输出。

## 安装和首次引导

开发设备可使用应用中心手动安装，或在 fnOS 上执行：

```bash
appcenter-cli install-fpk pocket-img-0.5.0.fpk
```

安装过程需要能够从 GHCR 拉取目标多架构镜像。`checkport=true` 会让 fnOS 在启动前检查宿主 `8080`；若已有服务占用，应先解决冲突，不要绕过检查。

安装完成后，从 fnOS 桌面打开 PocketIMG。主入口为：

```text
https://<当前 fnOS 主机>/app/pocket-img
```

首次引导页显示：

1. 当前 fnOS 管理地址。
2. Mac 客户端应填写的服务地址，例如 `http://192.168.1.10:8080`，或管理员配置的外部 HTTPS 地址。
3. 从本机 `/downloads` 提供的 PocketIMG Shot ZIP、版本、系统要求和校验值。
4. 当前飞牛用户，以及生成、重新生成和撤销“Mac 客户端连接凭证”的操作；凭证只完整展示一次。
5. 客户端填写说明：只填服务地址和连接凭证，不填写飞牛用户名、密码、管理员凭据或空间 ID。
6. 手机无需安装当前 Android 管理 App，直接打开 Web 管理地址。

推荐的首次连接顺序为：

1. 登录 fnOS，并从应用中心打开 PocketIMG；网页通过 SSO 进入当前飞牛用户的图库。
2. 下载 NAS 本地提供的 PocketIMG Shot。
3. 在引导页生成连接凭证，并立即复制服务地址和只显示一次的凭证。
4. 在 Mac 设置中填入这两项。Mac 上传的内容会出现在当前飞牛用户的同一图库中。

连接凭证不是“飞牛管理 Token”。重新生成只是在不改变图库归属的前提下轮换 Mac 连接凭证；如果凭证遗失或怀疑泄露，重新生成后需要在所有 Mac 上更新。

不能根据 fnOS 开放 API 可靠发现公网地址。页面可用当前 hostname 和 `PIH_SERVICE_PORT` 给出局域网候选值，但外部 HTTPS 公共基址必须由管理员显式配置。管理地址 `/app/pocket-img` 不能作为 Mac 客户端服务地址。

## 升级和数据

- FPK manifest 版本、OCI 镜像标签、Mac ZIP 版本必须一致。
- `${TRIM_PKGVAR}` 映射的 `/data` 在容器重建和应用升级时保持不变。
- 数据库迁移由新镜像启动时执行；升级前应整体备份数据库、WAL、对象与缩略图。
- 若把现有 Linux 部署的完整 `/data` 迁入 fnOS，数据库中已有的 Token 空间会继续保留，可从 TCP 入口使用原 Token 访问。fnOS SSO 用户会建立新的独立空间；系统不会猜测旧空间对应哪个 NAS 用户，也不会自动合并数据。
- `${TRIM_APPDEST}/downloads` 会随 FPK 更新，确保引导页提供与当前服务匹配的客户端。
- 当前卸载回调不会主动删除或导出数据。正式上架前应在真机确认 fnOS 的卸载数据行为；若要让用户选择保留或删除，需增加 `wizard/uninstall` 和明确、可重复执行的回调逻辑。

## 真机验收

至少在一台 amd64 和一台 arm64 fnOS 设备验证：

- `.fpk` 可安装，正确拉取对应架构镜像。
- 应用中心的启动、停止和状态准确，异常信息可见。
- `/app/pocket-img` 的 HTML、JS、CSS、API 和 SSE 都保留正确前缀。
- 两个普通 fnOS 用户首次访问后得到不同空间，互相不可见。
- 普通用户无法调用管理员 API；管理员身份以可信 Header 为准。
- 从 TCP 端伪造 `X-Trim-Userid` 或 `X-Trim-Isadmin` 不会改变身份。
- Mac 客户端使用引导页给出的地址和连接凭证，可以向当前飞牛用户的同一图库上传图片及 MP4，且客户端会话不具有管理员权限。
- 无 fnOS Cookie 的浏览器仍能读取复制出的 `/i/...` 公共链接。
- 本地 ZIP 文件名、版本、SHA-256、Content-Type 和 Content-Disposition 正确。
- 容器重启、应用停止再启动、同版本覆盖测试和跨版本升级后数据完整。
- 端口被占用、镜像拉取失败、Socket 无法创建、数据目录不可写时能显示可执行的错误。
- 外部 HTTPS 场景不会把 Secure Cookie 或公开 URL 错误地降级到局域网 HTTP。
