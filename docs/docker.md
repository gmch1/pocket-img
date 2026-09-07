# Docker 部署

PocketIMG 的生产镜像只有一个运行服务。React 页面会先由 Node.js 构建，再通过
Go `embed` 编入静态后端；SQLite 也运行在同一个 Go 进程中，不需要额外的
前端、数据库或反向代理容器。

镜像同时支持 `linux/amd64` 和 `linux/arm64`。容器监听 `8080`，以固定的非
root UID/GID `10001:10001` 运行，并把全部可变数据写入 `/data`。

## 自动安装（推荐）

需要 Docker Engine、支持 `up --wait` 的 Docker Compose v2、Bash、curl、Python 3、tar 和 sha256sum，当前用户须有运行 Docker 的权限。Docker 引擎支持 Linux amd64/arm64；无需 Git、Go、Node.js 或源代码。在准备存放部署配置的目录执行：

```bash
curl -fsSL https://raw.githubusercontent.com/gmch1/pocket-img/main/install.sh | bash -s -- --docker
```

入口从 GitHub 的稳定 `server-v*` Release 中选择含 Docker 部署包及校验文件的最高版本，不使用属于 Mac 的 GitHub Latest，也不使用浮动镜像 `latest`。下载 `PocketIMG-<version>-docker-install.tar.gz` 并校验 SHA-256 和文件结构后，部署到当前目录下的 `pocketimg-docker`，拉取 GHCR 镜像。部署包的 Compose 固定镜像摘要；其中没有源码、Dockerfile 或 `build` 配置。需要访问 GitHub 与 GHCR，不需要构建依赖源。

指定版本、端口或部署目录（版本号替换为已发布且带 Docker 部署包的版本）：

```bash
curl -fsSL https://raw.githubusercontent.com/gmch1/pocket-img/main/install.sh | \
  bash -s -- --docker --version X.Y.Z --port 19876 --directory ./pocketimg-docker
```

脚本自动在持久化卷生成管理员 Token，然后启动并等待服务健康。完成后直接输出访问地址、管理员空间、Token 和保存位置，无需执行随机数命令或手工编辑配置。从 [Server 0.5.3](https://github.com/gmch1/pocket-img/releases/tag/server-v0.5.3) 起提供 Docker 部署包，旧 Release 不会被自动选中。

默认使用发布包指定的镜像；高级用户可通过 `PIH_IMAGE` 覆盖，但必须自行确保镜像兼容。旧版本（包括 `0.5.2`）不支持 `init`，不能用于此自动安装入口。

离线或本地已有镜像可同时设置 `PIH_INSTALL_PULL=0`，跳过拉取。

升级时重新执行 GitHub 入口并用 `--directory` 指向原部署目录。入口只更新自身管理且未被修改的三个部署文件，保留 `.env`、数据卷和凭证；目录非空但无安装标记，或 Compose/脚本被手工修改时会拒绝覆盖。首次上线前请备份现有数据，源码部署不要直接混用此入口。保留原 Compose 项目名 `pocketimg`；部署第二个独立实例需另设 `COMPOSE_PROJECT_NAME` 和端口。

如果只需重启或复用已下载版本，在部署目录执行 `bash scripts/install-docker.sh`，不会查询新 Release。自定义配置放在该目录的 `.env`，保留此目录以便管理服务。

离线准备：在联网机器执行 `bash install.sh --docker --version X.Y.Z --download-only ./docker-bundle`，并另行导出部署包引用的镜像；目标机器加载镜像后，在解压目录执行 `PIH_INSTALL_PULL=0 bash scripts/install-docker.sh`。仅下载模式不拉取镜像、不启动服务。

自动凭证保存在数据卷的 `/data/tokens.json`，权限为 `0600`，所有者为 `10001:10001`。初始化容器和服务使用同一卷、同一 UID；不会写入只读 `/config`。默认管理员空间为 `admin`，新安装入口为 `http://宿主机地址:18746`，容器内部仍监听 `8080`。修改宿主机端口：

```bash
bash scripts/install-docker.sh --port 19876
```

也支持 `PIH_PORT=19876` 或 `.env` 中的同名配置。安装脚本在未指定端口时复用已有容器的宿主机端口（包括停止的容器），否则使用 `18746`。如果使用裸 Compose 命令，或删除容器后重建，请通过 `.env` 保存自定义 `PIH_PORT`；旧部署要继续使用 `8080` 也应显式设置。

重复安装、容器重建和升级复用原凭证。普通 `docker compose up -d` 能读取已有的自动凭证，但不会初始化新实例或直接展示 Token；首次安装使用脚本。安装失败后保留凭证，修复问题再运行；已有数据但凭证缺失时要求恢复原配置，不生成新身份。

安装脚本也支持下文的显式文件、`PIH_TOKENS` 或旧 `PIH_TOKEN`，只使用一种来源。保留相同 Compose 项目名、卷及自定义环境配置，不要在重装时更换它们。无人值守更新可设置 `PIH_INSTALL_QUIET=1` 隐藏 Token；默认安装输出包含登录凭证，普通服务日志不打印它。

## 手工构建镜像

仅开发或修改源码时使用。需要 Git，首次获取源码并自动构建安装可执行：

```bash
git clone --depth 1 https://github.com/gmch1/pocket-img.git pocket-img && \
  cd pocket-img && \
  bash scripts/install-docker.sh
```

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

## 手工配置单 Token（高级方式）

自动安装无需以下步骤；此节保留给已有配置和自定义部署。

先生成至少 32 字节随机 Token，并把它保存在部署主机的安全配置中：

```bash
openssl rand -hex 32
```

将输出值通过环境变量传给 Compose。下面的值只是格式示意，不能直接使用：

```bash
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach --build
```

默认入口为 `http://宿主机地址:18746`。可以通过 `PIH_PORT` 修改宿主机端口：

```bash
PIH_PORT=18080 \
PIH_TOKEN='replace-with-a-random-64-character-hex-token' \
docker compose up --detach
```

环境变量会出现在容器配置中。长期部署更推荐使用 Token 文件。

## 手工配置 Token 文件（高级方式）

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
├── tokens.json（自动安装的管理员凭证）
├── metadata.sqlite3
├── metadata.sqlite3-wal
├── metadata.sqlite3-shm
├── objects/
├── thumbnails/
└── tmp/
```

自动生成的 `tokens.json` 必须随数据卷一起备份；显式 `/config` 文件或环境凭证需单独备份。SQLite 和媒体文件必须作为同一组备份。最可靠的方式是先停止服务，完整备份
该卷，再重新启动。不要把 `/data` 放到 NFS、SMB 等网络文件系统，也不要让
多个 PocketIMG 容器同时挂载并写入同一数据目录。

如需使用主机目录代替命名卷，把 Compose 中的 `pocketimg-data:/data` 改为
绝对路径绑定，并确保目录归 `10001:10001` 所有且模式不宽于 `0750`。

## 健康检查与日志

镜像内置健康检查：

```bash
curl --fail http://127.0.0.1:18746/healthz
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
