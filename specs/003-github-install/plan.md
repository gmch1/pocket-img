# Implementation Plan 003

1. 实现下载入口，固定 GitHub 仓库，筛选兼容 Server 版本并校验附件。
2. 复用已有安装脚本，新增同版本打包工具和 Server Release 附件。
3. 用离线 GitHub fixtures 验证组件选择与失败保护；用真实二进制验证打包、解压与初始化。
4. 在 CI 和 Server 发布构建中运行安装器测试。
5. Linux 和 Docker 新安装使用 `18746`，增加端口参数校验，复用已有配置；验证 Linux 改端口与冲突保护、Docker 重装保留原端口。
6. 更新 README、一键安装、CI/CD 与 HTTP/HTTPS 边界说明。
7. 发布阶段：提交推送、等待该提交 CI，通过 Server 组件工作流发布新版本，再做公网下载与安装验收；不因此发布无关客户端。
