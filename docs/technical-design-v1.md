# Phone Image Host v1 技术设计

状态：前后端关键链路已通过真机端到端验证
日期：2026-08-12

## 1. 技术选型结论

| 层次 | 选择 | 目的 |
| --- | --- | --- |
| 前端 | React + TypeScript + Vite | 纯 SPA，开发直接，构建结果为静态文件 |
| 后端 | Go 标准库 `net/http` | 低运行依赖、并发能力好、部署简单 |
| 路由 | Go 标准库 `http.ServeMux` | 避免引入完整 Web 框架 |
| 元数据 | SQLite（pure Go 驱动） | 与进程内嵌，无独立数据库服务和 C 运行库依赖 |
| 图片文件 | 本机普通文件 | 不把大图片写入数据库 |
| 图片编码 | `libwebp` 的 CGo-free 编译版本 | 保留 WebP 兼容性，同时生成无动态库依赖的产物 |
| 部署产物 | Linux ARM64 单文件 / Android 管理 APK | 前端资源、SQLite、时区数据和 WebP 编解码器一并编入后端 |

不选择 Node 后端、Java、PostgreSQL、Redis、ImageMagick 常驻服务或微服务拆分。Rust 理论上可以进一步压低运行时开销，但会显著增加开发和图像处理集成成本；本项目规模下 Go 的性能、内存和维护成本更均衡。

## 2. 前端设计

### 2.1 构建与运行

- 使用 React、TypeScript 和 Vite。
- 只做客户端渲染，不使用 Next.js、SSR 或服务端 React。
- Node.js 仅在开发机执行依赖安装、测试和构建。
- `vite build` 的产物由 Go 的 `go:embed` 编入最终二进制。
- 设备运行时不存在 Node 进程，也不需要部署单独的静态文件服务。

### 2.2 依赖原则

- 不引入大型组件库，页面样式使用项目内 CSS。
- 复制、删除等图标使用项目内 SVG，不加载在线图标或字体。
- 不使用 Redux；页面状态优先使用 React 自带状态能力。
- 所有前端资源随二进制提供，页面不请求 CDN、字体或第三方脚本。
- 大于等于 256 KiB 的 PNG/JPEG 在 Web Worker 中通过 `OffscreenCanvas` 尝试编码为质量 82 的同尺寸 WebP；输出类型不符、节省不足 10% 或能力不可用时上传原文件。
- 浏览器优化队列保持逐张执行，GIF 和 WebP 不进入客户端编码器；压缩阶段不占用 UI 主线程。
- 当前前端读取最近 100 张并明确显示上限；下一阶段接入游标滚动分页，长期滚动时再根据实测决定是否窗口化。

## 3. 后端设计

### 3.1 单进程结构

```text
Go process
├── HTTP server
│   ├── embedded React assets
│   ├── auth/session API
│   ├── space-scoped image metadata API
│   └── public image files
├── SQLite metadata store
├── bounded image job queue
├── one image conversion worker
└── retention/session cleanup worker
```

所有模块都在同一进程内，不通过 RPC、消息队列或独立数据库进程通信。

### 3.2 HTTP 层

- 使用标准库 `net/http` 和 `http.ServeMux`。
- 设置读取 Header、读取请求体、写响应和空闲连接超时。
- 使用 `http.MaxBytesReader` 在解析 multipart 前限制请求体大小。
- 上传内容通过流写入临时文件，不先完整读入 Go `[]byte`。
- 公开图片先用全局随机图片 ID 查询所属空间和文件类型，再从 `os.File` 直接响应，避免把整个文件加载到 Go 堆。
- 内容 URL 一旦生成便不可变，可返回 `Cache-Control: public, max-age=31536000, immutable`。
- JSON API 不使用反射较重的通用 ORM 或自动绑定框架。

### 3.3 图片处理队列

- HTTP 上传并发使用固定长度的有界槽位；槽位已满时返回 `503`，不能无限积压内存对象。
- 上传先流式写入临时目录。安全静态 WebP 和动图完成校验后直接提交全尺寸文件与元数据；需要净化或格式转换的输入仍通过单槽位同步处理。
- 元数据以 `thumbnail_size = 0` 表示待生成缩略图；提交后唤醒单独的缩略图 worker，上传响应不等待该 worker。
- 缩略图 worker 同一时间只解码一张图片，并在服务启动及周期扫描时补做未完成任务。
- 解码前读取格式、宽高和动画属性，先检查文件字节数和总像素数。
- 失败任务删除全部临时文件，不写入正式元数据。
- 默认解码像素上限为 20 MP；这是根据目标设备压测从预研初值 40 MP 收紧后的结果。
- 每次图片处理完成后主动让 Go 运行时归还短期大对象占用，避免进程长期维持在转换峰值 RSS。

限制并发 worker 比提高单次吞吐更重要：大图解码后的 RGBA 内存约为 `宽 × 高 × 4` 字节，多图同时处理会快速放大内存峰值。

### 3.4 多 Token 空间模型

- 配置是 `space_id → token` 映射；空间 ID 是稳定数据归属，Token 只是可轮换凭据。
- `space_id` 限制为 1–64 个 ASCII 字母、数字、下划线或连字符，避免目录穿越和不稳定路径。
- 服务只保存 Token 的 SHA-256 指纹，不保存数据库明文 Token；配置文件是明文凭据源，文件权限应为 `0600`。
- Token 换取 Session 时，Session 记录同时绑定空间 ID 和签发时的 Token 指纹。
- 管理 API 中的空间 ID 只由 Session 中间件写入请求 Context，客户端不能通过请求参数选择空间。
- Token 轮换会使该空间旧 Session 失效，但不会改变图片的 `owner_id`；其他空间 Session 不受影响。
- 删除空间配置只会禁用其登录与管理会话，不自动删除图片；已知公开直链仍保持可访问。
- v1 使用共享表的 `owner_id` 逻辑分区，不按 Token 动态建表、建库，也不把 Token 写进文件路径。
- 部署配置指定一个主空间为管理员。管理员通过 API 创建用户时，服务生成 256-bit Token，只返回一次，并只把其 SHA-256 指纹持久化到 SQLite；动态用户不需要写回 Token 配置文件，重启后仍然有效。
- 每个用户默认具有 10 GiB 实际存储配额与 90 天保留期。配额包含全尺寸文件和已完成的缩略图，配额检查与元数据插入在同一 SQLite 事务中完成。

## 4. 图片处理管线

### 4.1 静态图片

```text
temporary upload
  → header/decode-config validation
  → pixel-limit check
  ├── safe static WebP → validated full-size passthrough
  └── PNG/JPEG/metadata WebP → decode → full-size WebP quality 82
  → fsync/atomic rename → SQLite pending-thumbnail row → HTTP 201
  → background decode → 640px thumbnail WebP quality 75
  → atomic rename → update thumbnail size
```

- PNG、JPEG 和静态 WebP 都进入静态图片管线，客户端预压缩不能绕过后端校验。
- 全尺寸输出保持输入宽高，不做放大或缩小。
- 缩略图保持宽高比，长边不超过 640 px。
- 无动画且仅包含标准图像/Alpha 块的 WebP 在完成头部和容器结构校验后直接作为全尺寸文件；包含 ICC、EXIF、XMP 或未知块时重编码净化。

### 4.2 动图

```text
temporary GIF / animated WebP
  → format and pixel validation
  → original animation atomic rename → SQLite pending-thumbnail row → HTTP 201
  → background decode first frame → 640px WebP thumbnail
```

- 动图正式文件保持上传字节不变。
- 只为瀑布流额外生成首帧静态缩略图。
- 公开 URL 保留正确扩展名和 `Content-Type`。

### 4.3 原子性

- 临时文件、正式文件和 SQLite 位于同一数据分区，保证重命名可原子完成。
- 先同步并原子提交全尺寸文件，再写入待生成缩略图的 SQLite 记录；数据库提交失败时删除全尺寸文件。
- 缩略图先写入临时候选文件，再原子重命名并更新 `thumbnail_size`；服务进程异常退出时，数据库中的零值记录会在下次启动补做。失败任务按批次指数退避，连续 5 次失败后标记为不再重试并回退到全图，避免损坏输入永久消耗设备资源。
- 待生成记录的 API 响应把 `thumbnail_url` 暂时指向已落盘的全尺寸公开 URL，避免出现不可访问的图片卡片。
- 永久删除与缩略图提交使用同一互斥区，保证删除完成后后台 worker 不会重新留下缩略图。

## 5. SQLite 设计原则

- SQLite 只保存图片元数据、管理会话和待清理任务，不保存图片 BLOB。
- 开启 WAL 模式和 `busy_timeout`。
- 所有写事务保持短小，不在事务中执行图片解码或编码。
- 图片表以 `owner_id` 标识所属空间，并为 `(owner_id, created_at, id)` 建联合索引，支持各空间稳定的倒序游标分页。
- 会话表只保存随机会话凭据的哈希、`owner_id` 和 Token 指纹，不保存浏览器 Cookie 原值。
- 用户表只保存稳定空间 ID、Token 指纹和启用状态，不包含密码、角色或用户资料。
- 用户表同时保存管理员标记、字节配额、保留天数和配置/动态来源；管理员标记只有部署指定的主空间为真，不提供任意角色系统。
- 数据库文件只由当前 Go 进程访问，不放在网络文件系统上。

## 6. 数据目录

```text
data/
├── metadata.sqlite3
├── metadata.sqlite3-wal
├── metadata.sqlite3-shm
├── objects/
│   └── <space-id>/ab/cd/<opaque-id>.webp|gif
├── thumbnails/
│   └── <space-id>/ab/cd/<opaque-id>.webp
└── tmp/
```

- `opaque-id` 使用密码学安全随机 ID，不能由数据库自增 ID 推测。
- 两级前缀目录避免大量图片集中在一个目录。
- 公开 URL 仍为 `/i/<opaque-id>.<ext>` 与 `/t/<opaque-id>.webp`，不暴露内部空间 ID。
- 数据目录通过启动参数配置，默认指向手机的大容量 `/data` 分区。

## 7. 内存与性能基线

2026-08-11 在目标 Dimensity 1100 设备上的首轮数据如下，详细条件见[后端链路预研报告](backend-spike.md)：

| 场景 | 实测结果 |
| --- | --- |
| 启动后空闲 RSS | 约 9.7–10.7 MiB |
| 2728×1884 PNG 转换 | 3.39 秒，峰值 199 MiB，完成后 12.5 MiB |
| 3840×2160 PNG 转换 | 3.68 秒，峰值 293 MiB，完成后 11.9 MiB |
| 默认并发图片转换 | 1 |
| ARM64 二进制 | 约 12.4 MiB，静态链接 |
| 公开图片响应 | 流式文件响应，不复制整张图片到堆 |

4K 峰值高于原设计目标，但相对压测时约 2.8 GiB 的系统可用内存仍有足够余量，且任务结束后 RSS 能立即回落。因此 v1 保持单 worker 并把像素上限设为 20 MP，不提升为 2 workers。若多图粘贴的等待时间影响体验，再单独研究通过 Android NDK 静态链接原生 `libwebp`；不让该优化阻塞首版。

## 8. 构建与部署

- 开发机完成 React 构建和 Go 编译。
- 预研基线使用 pure Go SQLite 驱动，以及编译到 Go 的 `libwebp` CGo-free 实现。
- 推荐通过 `PIH_TOKENS_FILE` 指向权限为 `0600` 的 JSON 对象配置多空间；同时支持 `PIH_TOKENS` 内联 JSON 和兼容旧版的单值 `PIH_TOKEN`，三者互斥。
- 单个引导空间自动成为管理员；配置多个引导空间时必须通过 `PIH_ADMIN_SPACE_ID` 指定管理员。Android App 自动把当前主空间传给后端。
- 旧版单 Token 数据库升级且只配置一个空间时，启动过程自动补充 `owner_id` 并把旧文件移动到该空间目录。旧库直接切换到多个空间时，应保留一个名为 `default` 的空间用于接管历史图片。
- 目标产物不依赖设备上的 Node、npm、SQLite CLI、libwebp 动态库或图片转换命令。
- 已 Root 设备可通过 Magisk `service.d` 或 Linux chroot 的进程守护方式启动；普通 ARM64 Android 设备可使用管理 App 的前台服务手动启停内嵌 Go 后端。
- 当前开发阶段由手机监听 `0.0.0.0:8080` 提供可信局域网 HTTP，显式设置 `PIH_COOKIE_SECURE=false`，不包含外部入口配置。
- React 前端已经内嵌并在局域网入口完成验收；接入外部 HTTPS 入口时，把 `PIH_COOKIE_SECURE` 恢复为默认值 `true`。
- v1 不实现请求频率限制，继续用上传大小、像素上限、有界队列和单 worker 控制资源消耗。
- 发布时输出二进制、示例配置和数据库迁移说明，不输出 Docker 镜像作为主要部署方式。

## 9. 选择依据

- Go 标准库支持把前端文件树嵌入可执行文件，并可直接提供 HTTP 文件服务。
- SQLite 适合设备本地、低写并发且无需独立数据库管理的应用。
- libwebp 提供原生编码、解码、缩放和动画特征检测 API，适合控制移动设备上的转换开销。

参考：

- [Go `embed` 包](https://pkg.go.dev/embed)
- [Go `net/http` 包](https://pkg.go.dev/net/http)
- [SQLite 的适用场景](https://sqlite.org/whentouse.html)
- [SQLite 的进程内架构](https://sqlite.org/serverless.html)
- [libwebp API](https://developers.google.com/speed/webp/docs/api)
- [`gen2brain/webp` CGo-free WebP 实现](https://github.com/gen2brain/webp)
- [`modernc.org/sqlite` pure Go SQLite 驱动](https://gitlab.com/cznic/sqlite)
- [React 从构建工具开始创建应用](https://react.dev/learn/creating-a-react-app)
