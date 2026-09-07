# Tasks 004

- [x] 调整 Server/fnOS/全组件发布依赖
- [x] Docker 部署包固定摘要，添加 GitHub Docker 安装模式
- [x] 保留源码构建入口及已安装凭证/配置
- [x] Linux 下载器 9 项、Docker 下载/部署保护 15 项离线测试通过
- [x] 原 Docker 安装真实初始化、重装、登录与权限测试通过
- [x] 更新 README、Docker 和发布文档
- [x] 新镜像构建及真实部署包安装验证
- [x] 发布工作流静态检查（actionlint 1.7.7、YAML 解析）
- [ ] 推送后 CI、新 Server Release 及公网安装验收（需后续授权发布）

本地实测发现跨阶段 COPY 未保留目标目录的 0700 权限，已用显式 `COPY --chmod=0700` 修复。新镜像部署包的初始化、Token 复用、端口保留、登录、容器重建、权限和日志脱敏测试通过；测试项目及数据卷已清理。amd64/arm64 双架构构建通过（ARM 为交叉构建，未做 ARM 实机运行）。

阿里云 47.86.41.255 为 Ubuntu 22.04 x86_64，原 PocketIMG 服务停止且没有 Docker；已询问是否允许安装 Docker 后进行隔离验证，尚未改动原服务。
