# Spec 004：Server 镜像发布与免源码 Docker 安装

## 目标

普通用户通过 GitHub 一条命令安装已发布镜像，不克隆源码、不本机构建，自动初始化并展示 Token。

## 范围

- Server Release 发布 amd64/arm64 GHCR 镜像、固定摘要的 Docker 部署包及 SHA-256。
- fnOS 复用同版本 Server 镜像；全组件发布等待 Server 与 Mac 完成后打包 fnOS。
- `install.sh --docker` 支持稳定版本选择、指定版本、端口、部署目录、仅下载模式；校验失败不得执行部署。
- 更新仅覆盖未被用户修改的受管文件，保留 `.env`、项目身份、数据卷和凭证；源码部署保持可用。
- 不改变上传/列表鉴权、图片直链公开访问、HTTP/HTTPS 边界；不自动安装 Docker 或配置 TLS。

## 验收

下载器离线测试、部署包结构与更新保护测试、真实 Docker 初始化/重装/登录/权限测试、工作流静态检查通过。Server 0.5.3 已完成 GitHub 下载、校验、GHCR 拉取和部署包安装验收，详见 [任务记录](tasks.md)。
