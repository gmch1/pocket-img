# Changelog

## 0.1.4 - 2026-08-12

### Added

- 缩略图改由单独的持久化后台任务生成；服务启动时会自动补做数据库中尚未完成的缩略图。
- 上传进度在请求体发送完成后显示“处理中”，只在后端正式返回可访问 URL 后显示成功。

### Changed

- 安全的浏览器 WebP 完成校验、原子落盘和元数据写入后立即响应，不再等待缩略图解码与编码。
- 新上传图片在缩略图就绪前临时使用公开原图展示，后续图库请求自动使用缩略图。
- Android 默认版本更新为 `0.1.4`（versionCode 5）。

### Fixed

- 日期范围切换时保留现有瀑布流位置，刷新指示器不再占据文档流并把图片整体向下推。
- 缩略图后台生成与永久删除串行化，避免删除过程中重新产生孤立缩略图。

## 0.1.3 - 2026-08-12

### Added

- Android 前台服务增加 Go 子进程退出监听和周期健康检查，异常时自动清理旧进程并恢复后端。
- 恢复失败使用最高 5 分钟的有上限退避，稳定运行 5 分钟后自动重置，避免崩溃循环。

### Changed

- Android 默认版本更新为 `0.1.3`（versionCode 4）。

## 0.1.2 - 2026-08-12

### Added

- Android App 增加“局域网 HTTP / 外部 HTTPS”访问模式；HTTPS 模式启用 Secure Session Cookie 和更长的上传超时。
- 增加 `BOOT_COMPLETED` 与 `MY_PACKAGE_REPLACED` 恢复入口，并为启动失败增加有限退避重试。
- Android App 增加“后台运行设置”入口；重新打开 App 时会恢复用户原先要求保持运行、但被系统终止的服务。
- 增加 Root 开发实例到 App 私有目录的可回滚迁移脚本和操作文档。
- 增加通用反向代理契约，不包含具体域名、凭据、DNS 或隧道配置。
- Go 服务增加 `PIH_READ_TIMEOUT`、`PIH_WRITE_TIMEOUT` duration 配置。

### Changed

- App 从 Token 文件识别并保留既有空间 ID，不再强制把迁入数据归到 `mobile`。
- Origin 校验只使用代理保留的原始 `Host`，不再无条件信任 `X-Forwarded-Host`。
- Android 默认版本更新为 `0.1.2`（versionCode 3）。

### Validation fixes

- MIUI 未授权“自启动”时，划掉任务卡会把应用标记为系统强停；安装文档补充无需 Root 的授权步骤，并在真机授权后验证任务卡移除不再中断服务。
- Android 界面与前台服务不再拆分进程，避免 `SharedPreferences` 的访问模式、端口和期望运行状态在跨进程缓存中不同步；Go 服务仍保持为独立子进程。
- Android 真机的 `adb shell su -c` 不会可靠保留多行参数边界；迁移脚本改用编码后的单一 root shell 输入，防止后续命令意外退回普通 shell 权限。
- 迁移必须同时复制数据库、对象、缩略图、Token 和空间 ID；只切换二进制会造成历史图库不可见。
- 公网入口启用前必须从当前 Root 开发运行时切换到唯一的 App 运行时，避免两个服务争用端口或使用不同数据目录。

### Validated

- Root 实例无损迁移到 Android App；既有图库条目、空间 ID 和历史图片 SHA-256 保持一致。
- `img.901200.xyz` 的 IPv4/IPv6、HTTPS、DNS-only 记录、独立受限反向 SSH 隧道和 Caddy 代理链路通过端到端验证。
- 公网鉴权、Secure/HttpOnly/SameSite=Strict Session Cookie、Origin 防护、WebP 上传、公开读取和永久删除均通过。
- 真机开机并完成首次解锁后，App 服务与公网入口自动恢复为 200；按用户要求未再执行第二次重启。
- 公网并发验证无错误：健康接口 400 次请求、并发 40；公开图片 200 次请求、并发 20；上传并转码 20 张、并发 5，随后全部永久删除。
