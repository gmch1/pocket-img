# 后端关键链路预研报告

日期：2026-08-11
结论：可行，可以进入正式后端实现阶段

## 1. 预研问题

本轮只验证后端，不实现 React 页面，重点回答以下问题：

1. 能否做成不依赖 Docker、Node、系统 SQLite 或系统 `libwebp` 的 ARM64 单文件。
2. Android 13、Linux 4.14 的目标手机能否直接运行该文件。
3. Token 换 Cookie、鉴权上传、WebP 转换、缩略图、SQLite、公开直链和永久删除能否形成闭环。
4. 转换耗时和峰值内存是否在设备可接受范围内。
5. 服务重启后会话、记录和图片是否保持稳定。

## 2. Spike 实现范围

当前代码实现了：

- `POST /api/auth/session`：长期 Bearer Token 换随机 Session Cookie；SQLite 只保存会话哈希。
- `POST /api/images`：鉴权、流式 multipart 落临时文件、文件大小限制、格式解码验证和像素限制。
- PNG、JPEG、静态 WebP 转全尺寸 WebP，并生成 640 px WebP 缩略图。
- GIF 和动态 WebP 原样保存，并从首帧生成 WebP 缩略图。
- `GET /api/images`：会话鉴权和今天、7 天、30 天、全部筛选。
- `GET /i/...`、`GET /t/...`：无需鉴权的公开文件读取和 immutable 缓存头。
- `DELETE /api/images`：会话鉴权后永久删除正式文件、缩略图和元数据。
- SQLite WAL、两级文件目录、128 bit 随机图片 ID、单 worker 和有界等待队列。
- 内嵌 `Asia/Shanghai` 时区数据，规避 Android 缺少标准 zoneinfo 文件的问题。
- 图片处理后主动归还临时大对象对应的内存页。

尚未实现的生产功能见“剩余工作”，不能把本 spike 直接当成完整 v1。

## 3. 目标设备与构建产物

目标设备实测环境：

| 项目 | 结果 |
| --- | --- |
| 型号 | M2104K10AC（chopin） |
| Android | 13 |
| CPU 架构 | aarch64 |
| Linux 内核 | 4.14.186 |
| 总内存 | 约 7.3 GiB |
| 压测前可用内存 | 约 2.8 GiB |
| `/data` 可用空间 | 约 206 GiB |

构建产物 `phone-image-host-linux-arm64`：

- 12,976,290 bytes，约 12.4 MiB。
- ELF aarch64，可执行文件已 strip。
- 静态链接，不依赖 Android 的 glibc、SQLite、`libwebp.so` 或命令行工具。
- 手机中也未发现可供应用直接复用的独立 `libwebp.so`，因此无动态依赖的基线更可靠。

实际运行不需要 Docker。预研通过 `adb push` 放到 `/data/local/tmp`，以普通 adb shell 进程启动；root 不是运行这个二进制的必要条件。正式部署时是否使用 root 仅取决于数据目录、开机自启和进程守护方案。

## 4. 真机结果

### 4.1 常见截图

输入样本为 2728×1884 RGBA PNG，716 KiB：

| 指标 | 结果 |
| --- | --- |
| 上传并完成转换 | 3.394 秒 |
| 服务峰值 RSS | 203,988 KiB，约 199 MiB |
| 完成后 RSS | 12,756 KiB，约 12.5 MiB |
| 全尺寸 WebP | 222,828 bytes，原宽高不变 |
| 640 px 缩略图 | 23,088 bytes，640×441 |

同一样本在开发机的 CGo-free 构建中耗时约 1.28 秒，峰值约 204 MiB，完成后约 18 MiB。开发机和手机的峰值接近，说明主要内存来自分辨率和编解码工作区，而不是设备差异。

### 4.2 4K 图片

输入样本为 3840×2160 RGBA PNG：

| 指标 | 结果 |
| --- | --- |
| 上传并完成转换 | 3.684 秒 |
| 服务峰值 RSS | 300,512 KiB，约 293 MiB |
| 完成后 RSS | 12,164 KiB，约 11.9 MiB |

该样本是简单渐变画面，文件大小和输出压缩率不代表真实照片；分辨率、转换耗时和内存峰值仍可用于本次边界判断。

4K 峰值高于最初的 192 MiB 目标，但只短暂出现，并会在响应前回落。结合设备当时约 2.8 GiB 可用内存，单任务安全余量足够。预研据此把默认解码上限由 40 MP 收紧为 20 MP，并固定一个转换 worker。

### 4.3 HTTP 与持久化闭环

真机逐项验证结果：

| 行为 | 结果 |
| --- | --- |
| 无 Cookie 读取图库 | `401` |
| 有 Cookie 读取当天图库 | `200`，返回刚上传记录 |
| 无 Cookie 读取全尺寸图 | `200 image/webp` |
| 无 Cookie 读取缩略图 | `200 image/webp` |
| 永久删除 | `200`，随后原公开 URL 为 `404` |
| 停止并重启服务 | 原 Session Cookie、图库记录和公开 URL 均继续有效 |
| 健康检查 | `200 {"status":"ok"}` |

本地自动化测试还验证了 GIF 上传字节不变，同时生成可解码的 WebP 首帧缩略图。

## 5. 技术判断

### 5.1 可以采用的基线

- 后端继续使用 Go 标准库 HTTP 服务。
- SQLite 继续只存元数据，图片使用普通文件。
- 继续使用静态 ARM64 单文件部署；它最符合 Android 上降低依赖和维护成本的目标。
- WebP 首版可沿用 CGo-free 编解码器，不要求手机安装任何系统库。
- 单 worker、有界队列、20 MP 像素限制必须保留。
- 处理完成后主动归还内存必须保留，否则预研中进程会长期保持约 200 MiB RSS。

### 5.2 性能取舍

CGo-free WebP 编码在目标手机上处理常见截图约需 3.4 秒，适合个人图床的单张粘贴，但连续 20 张图片会明显排队。开发机对比试验中，动态原生 `libwebp` 把同一图片从约 1.28 秒降到约 0.35 秒；这只证明原生编码存在优化潜力，不能直接等同于 Android 上的收益。

因此首版优先交付无系统依赖的可靠版本。只有真正在多图使用中觉得等待不可接受时，再用 Android NDK 或可复现的静态工具链构建原生 `libwebp` 版本，并重新做 ARM64 真机内存、速度和升级维护验证。

## 6. 剩余工作

进入正式后端实现前仍需补齐：

- 游标分页，而不是 spike 当前的首批 `LIMIT` 查询。
- 服务启动时的超时临时文件清理和崩溃一致性恢复。
- 批量删除的逐项结果与可重试清理状态。
- 单次多文件上传接口，或明确前端逐文件并发策略。
- 更多格式异常、超限、取消、磁盘满和 SQLite 故障测试。
- 动态 WebP 的完整自动化样本测试。
- React 构建产物的 `go:embed` 和 `/` 静态页面路由。
- 正式配置文件、日志轮转、备份恢复、Magisk 开机自启和优雅升级方案。
- 外部入口到手机这段 HTTP 网络的信任边界确认；Token 换 Cookie 不能替代链路加密。

## 7. 复现

```bash
make test
make build
make build-arm64
```

本机调试示例：

```bash
PIH_TOKENS_FILE='./tokens.json' \
PIH_COOKIE_SECURE=false \
PIH_DATA_DIR='./data' \
PIH_ADDR='127.0.0.1:8080' \
./dist/phone-image-host-linux-amd64
```

正式经 HTTPS 使用时不要关闭 Secure Cookie。真机预研使用的二进制、图片、数据库、日志和 adb 端口转发均已在测试结束后清理，未安装常驻服务。

## 8. 多 Token 空间落地复验

2026-08-11 在同一目标设备继续完成了多空间实现和真机复验：

- 使用 JSON 预配置 Alice、Bob 两个稳定空间及各自 Token。
- 两个 Token 均成功换取只属于各自空间的 Session Cookie。
- Alice、Bob 分别上传后，各自图库列表只返回自己的图片。
- Bob 携带 Alice 图片 ID 请求删除时返回 `deleted: 0`，Alice 图片及公开 URL 不受影响。
- 文件分别写入 `objects/alice/...`、`objects/bob/...` 以及对应缩略图目录。
- 只轮换 Alice Token 并重启服务后，Alice 旧 Session 与旧 Token 均返回 `401`，Bob 原 Session 继续返回 `200`。
- Alice 使用新 Token 登录后仍能读取原图库，两人的公开图片 URL 均保持 `200`。

本地自动化测试同时覆盖共享表 `owner_id` 隔离、跨空间删除、Token 轮换、旧 Session 吊销，以及旧版无 `owner_id` 数据库和文件目录自动迁移。复验结束后，手机上的临时服务、数据库、图片、Token 文件和 adb 端口转发均已删除。
