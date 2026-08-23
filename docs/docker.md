# Docker 部署

PocketIMG 的生产镜像只有一个运行服务。React 页面会先由 Node.js 构建，再通过
Go `embed` 编入静态后端；SQLite 也运行在同一个 Go 进程中，不需要额外的
前端、数据库或反向代理容器。

镜像同时支持 `linux/amd64` 和 `linux/arm64`。容器监听 `8080`，以固定的非
root UID/GID `10001:10001` 运行，并把全部可变数据写入 `/data`。

## 构建镜像

在仓库根目录执行：

```bash
docker build --tag pocketimg:local .
```

发布构建可以通过 `VERSION` 同时写入服务版本和 OCI 镜像标签：

```bash
docker build \
  --build-arg VERSION=0.5.0 \
  --tag pocketimg:0.5.0 \
  .
```

多架构发布构建使用 Buildx：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg VERSION=VERSION \
  --tag registry.example.com/pocketimg:VERSION \
  --push \
  .
```

也可以直接使用正式 GHCR 镜像：

```bash
PIH_IMAGE='ghcr.io/gmch1/pocket-img:0.5.0' \
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach
```

Docker 构建上下文采用严格白名单，只包含 Go、React 构建所需的源码和清单。
本地 `tokens.json`、签名文件、Git 历史、`node_modules`、应用构建产物和数据
目录都不会发送给 Docker daemon，也不会进入镜像层。

## 使用单 Token 启动

先生成至少 32 字节随机 Token，并把它保存在部署主机的安全配置中：

```bash
openssl rand -hex 32
```

将输出值通过环境变量传给 Compose。下面的值只是格式示意，不能直接使用：

```bash
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach --build
```

默认入口为 `http://宿主机地址:8080`。可以通过 `PIH_PORT` 修改宿主机端口：

```bash
PIH_PORT=18080 \
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach
```

环境变量会出现在容器配置中。长期部署更推荐使用 Token 文件。

## 使用 Token 文件启动

Compose 会把主机的 `./config` 只读挂载到容器 `/config`。先创建配置目录，
再准备权限受限的 JSON 文件：

```bash
mkdir -p config
cp tokens.example.json config/tokens.json
```

把示例值替换成密码学随机 Token，再让容器的固定 UID 成为配置所有者：

```bash
sudo chown -R 10001:10001 config
sudo chmod 700 config
sudo chmod 600 config/tokens.json
```

然后启动：

```bash
PIH_TOKENS_FILE='/config/tokens.json' \
PIH_ADMIN_SPACE_ID='alice' \
docker compose up --detach --build
```

只有一个空间时可省略 `PIH_ADMIN_SPACE_ID`。配置文件必须能被容器 UID
`10001` 读取；绑定宿主机目录时，可将文件所有者设为 `10001:10001`，或按
主机的 ACL 机制只授予该 UID 读取权限。不要同时设置 `PIH_TOKEN` 和
`PIH_TOKENS_FILE`。

如果配置位于其他目录，可设置 `PIH_CONFIG_DIR`：

```bash
PIH_CONFIG_DIR='/srv/pocketimg/config' \
PIH_TOKENS_FILE='/config/tokens.json' \
docker compose up --detach
```

## 数据与备份

Compose 使用 `pocketimg-data` 命名卷挂载 `/data`。其中包含：

```text
/data/
├── metadata.sqlite3
├── metadata.sqlite3-wal
├── metadata.sqlite3-shm
├── objects/
├── thumbnails/
└── tmp/
```

SQLite 和媒体文件必须作为同一组备份。最可靠的方式是先停止服务，完整备份
该卷，再重新启动。不要把 `/data` 放到 NFS、SMB 等网络文件系统，也不要让
多个 PocketIMG 容器同时挂载并写入同一数据目录。

如需使用主机目录代替命名卷，把 Compose 中的 `pocketimg-data:/data` 改为
绝对路径绑定，并确保目录归 `10001:10001` 所有且模式不宽于 `0750`。

## 健康检查与日志

镜像内置健康检查：

```bash
curl --fail http://127.0.0.1:8080/healthz
docker compose ps
docker compose logs --follow pocketimg
```

正常响应为 `{"status":"ok"}`。容器接收 `SIGTERM` 后会执行 Go 服务的优雅
关闭；Compose 给它保留 20 秒退出时间。

## Cookie 与 HTTPS

示例 Compose 默认面向可信局域网 HTTP，因此设置
`PIH_COOKIE_SECURE=false`。通过 HTTPS 反向代理访问时，应设置：

```bash
PIH_COOKIE_SECURE=true \
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach
```

反向代理仍需保留原始 Host、允许至少 28 MiB 请求体，并把请求超时设置得高于
PocketIMG。完整约束见[外部 HTTPS 反向代理契约](reverse-proxy.md)。
