# PocketIMG 安全审查报告

审查日期：2026-08-12
审查范围：Go 后端、React/TypeScript 前端、Android 管理 App、发布工作流，以及公网入口可观察到的 HTTP 安全头。外部反向代理与 SSH/网络中转配置位于 `OPS-Note`，不在本次源码审查范围内。

> 2026-08-12 后续：0.3.0 已为 SEC-005 增加可选的 App 内置 SSH 反向隧道。设备密钥在 App 私有目录生成并以 `0600` 保存，SSH 主机密钥必须固定；远端监听和本机目标强制为回环地址。启用“仅允许本机访问 HTTP”后后端绑定 `127.0.0.1`，可消除原先 249 到手机的局域网明文最后一跳。实际边缘账号、授权和 Caddy 状态仍需在 `OPS-Note` 单独核验。

## 执行摘要

未发现 Critical 级问题。发现 1 个 High、5 个 Medium、3 个 Low 风险点。

最需要先解决的是多 Token 场景下缺少空间配额和系统磁盘保留线。队列、单文件大小与单 worker 只能控制瞬时资源，不能阻止任一有效 Token 持有者持续上传并占满手机存储。第二优先级是失败缩略图任务会被永久、无退避地重复执行，以及登录/上传缺少速率与会话数量控制。

现有安全基础较好：Token 与 Session 使用安全随机数；Token 先转换为固定长度 SHA-256 指纹，数据库只存指纹/哈希；Cookie 为 `HttpOnly`、`SameSite=Strict`，公网模式启用 `Secure`；管理 API 按空间隔离；SQL 使用参数；上传有字节、像素、并发限制；文件名由服务端随机生成；前端未使用危险 HTML sink，也未持久化 Token；Android 数据位于 App 私有目录并禁止备份。

### 后续实现状态

本报告生成后，当前工作树已完成以下加固：SEC-001 的每用户 10 GiB 实际存储配额；SEC-002 的批次、指数退避和 5 次失败终止；SEC-003 的过期 Session 周期清理；SEC-004 的 CSP、`frame-ancestors`、`X-Frame-Options` 与 `Permissions-Policy`；SEC-009 的 64 KiB `MaxHeaderBytes`。SEC-001 提到的全局系统磁盘保留线、SEC-003 的频率/Session 数量限制以及其余风险仍待处理。下面保留原始发现，便于追踪审查依据。

## 验证结果

- `go test -race -tags=nodynamic ./...`：通过。
- `go vet -tags=nodynamic ./...`：通过。
- `govulncheck ./...`（官方 `golang.org/x/vuln`）：未发现可达漏洞。
- `npm audit`（官方 npm registry）：0 个已知漏洞。
- `./gradlew lintDebug testDebugUnitTest --no-daemon`：通过，0 error；6 个非安全阻断 warning。
- 当前工作树及全部可达 Git 历史未发现私钥、常见云密钥、GitHub Token 或实际 Token 配置；GitHub Secret Scanning 与 Push Protection 已启用，当前无告警。
- 公网入口实测会将 HTTP 重定向到 HTTPS，并设置 HSTS、`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`；未返回 CSP、点击劫持保护或 `Permissions-Policy`。

## High

### SEC-001：有效 Token 用户可耗尽整台手机的存储

- Rule ID：GO-CONC-001 / GO-HTTP-002（资源耗尽扩展）
- Severity：High
- Location：`internal/backend/server.go:421` `uploadImage`；`cmd/server/main.go:32-37`；`android/app/src/main/java/com/gmch/pocketimg/BackendRuntime.kt:114-128`
- Evidence：上传路径只限制单请求约 25 MiB、队列深度 8、图片像素和同时处理数；没有每空间字节/文件数量配额、总实例配额、每日上传预算或最小剩余磁盘线。Android 端只展示 `usableSpace`，不参与准入判断。
- Impact：任一有效 Token 持有者都可串行调用 API，持续写入对象、缩略图和 SQLite，直到 `/data` 分区耗尽。结果可能包括图床不可用、SQLite 写失败、Android 系统及其他 App 空间不足。新增给其他用户的 Token 使该风险从单管理员误操作变成真实的多租户边界问题。
- Fix：增加每空间 `max_bytes`、`max_objects`，并设置全局 `min_free_bytes`/最小剩余比例；在接收请求前、临时文件落盘后、正式提交前检查，最终配额扣减与图片元数据写入放在同一数据库事务中。为 GIF/WebP 同时按最终文件与缩略图预留预算。
- Mitigation：修复前先仅向完全可信的人发 Token；在 Android/系统侧设置磁盘告警；由入口限制每 Token 的上传吞吐，并保留足够的系统分区余量。
- False positive notes：单 worker 和 25 MiB 限制会降低填满速度，但不会限制累计容量，因此不能消除此风险。

## Medium

### SEC-002：失败缩略图会成为永久重试的“毒任务”

- Rule ID：GO-CONC-001
- Severity：Medium
- Location：`internal/backend/server.go:239-281` `runThumbnailWorker`/`processThumbnail`；`internal/backend/store.go:132-153` `listPendingThumbnails`；`internal/backend/processor.go:97-109,140-147`
- Evidence：`thumbnail_size = 0` 的全部记录每分钟无上限扫描；解码失败只写日志并返回，不记录失败次数、下次执行时间或终止状态。GIF 和动画 WebP 在上传阶段可只经过头部/容器检查后原样提交，完整首帧解码发生在异步任务中。
- Impact：持有有效 Token 的用户可提交能通过头部检查、但缩略图解码失败或异常昂贵的动画文件。多个失败记录会每分钟被全部重新解码，形成持续 CPU、内存与日志写入放大，且待处理表越大每轮开销越高。
- Fix：给任务增加 `attempts`、`next_attempt_at`、`last_error` 和终止状态；指数退避并限制最大重试次数；查询按固定批次读取。更稳妥的做法是在正式提交前至少成功解码首帧，或将永久失败记录标记为“无缩略图”，继续回退到全图展示。
- Mitigation：监控 `thumbnail_size = 0` 数量与日志增长；出现持续失败记录时人工隔离对应对象。
- False positive notes：尚未针对当前解码库构造最小恶意样本；但无限扫描和失败后状态不变是确定的，任何真实损坏文件或库边界输入都会触发重复工作。

### SEC-003：登录、会话创建和上传缺少滥用控制，会话表可无界增长

- Rule ID：GO-HTTP-002 / GO-HTTP-006（abuse control）
- Severity：Medium
- Location：`internal/backend/server.go:297-304,316-352,421-475`；`internal/backend/store.go:263-306`
- Evidence：路由没有速率限制。每次成功 Token 登录都会插入一个新 Session；只有请求携带旧 Cookie 时才替换旧行。过期 Session 仅在服务启动时清理，没有周期清理和每空间 Session 上限。
- Impact：泄露或主动共享的有效 Token 可通过不保存 Cookie 的客户端快速写大 Session 表，并竞争单连接 SQLite；同一用户也能持续占用上传 CPU/IO。无效 Token 暴力猜测成功率因 256-bit Token 极低，但仍可制造请求与日志/连接压力。
- Fix：为每空间设置上传令牌桶、同时上传数和日预算；为登录增加按来源与全局速率限制；周期删除过期 Session，并限制每空间活跃 Session 数，超限时淘汰最旧记录。入口侧限流时必须由可信代理确定客户端地址。
- Mitigation：在 Caddy/公网入口先做连接、请求体和登录频率限制；短期内定期清理过期 Session；发现 Token 被共享过度时轮换该空间 Token。
- False positive notes：项目先前明确延期了频率限制；此项因此属于已知、尚未实现的生产防护，而非隐藏的认证绕过。

### SEC-004：公网 App 缺少 CSP 与点击劫持保护

- Rule ID：GO-HTTP-004 / REACT-HEADERS-001
- Severity：Medium
- Location：`internal/backend/server.go:687-692` `securityHeaders`；公网 `https://img.901200.xyz/` 运行时响应
- Evidence：应用只设置 `nosniff` 和 `Referrer-Policy`。公网入口补充了 HSTS，但实测没有 `Content-Security-Policy`、`X-Frame-Options`/`frame-ancestors` 或 `Permissions-Policy`。
- Impact：缺少 CSP 会放大未来 XSS 或依赖供应链问题的影响；页面可被其他站点嵌入，在浏览器允许 Cookie 的场景（尤其同站点兄弟子域）可能进行点击劫持，诱导已登录用户执行永久删除等操作。
- Fix：在应用或 Caddy 集中加入与当前纯同源前端兼容的策略，例如 `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; worker-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`，并补 `X-Frame-Options: DENY` 与最小 `Permissions-Policy`。先在预发布验证 Worker 与图片粘贴。
- Mitigation：至少立即增加 `frame-ancestors 'none'`/`X-Frame-Options: DENY`；保持当前无第三方脚本、React 默认转义和 `nosniff`。
- False positive notes：CSP 不是修复已有 XSS 的替代品；本次源码扫描未发现可利用的前端 XSS sink，因此这是重要的纵深防御和点击劫持问题，而不是已证实的 XSS。

### SEC-005：设备端 HTTP 监听扩大了长期 Token 的明文暴露面

- Rule ID：GO-CONFIG-001 / 网络传输边界
- Severity：Medium
- Location：`android/app/src/main/java/com/gmch/pocketimg/BackendRuntime.kt:58-64`；`android/app/src/main/AndroidManifest.xml:18`；`docs/lan-development.md:59-66`
- Evidence：Go 服务固定监听 `0.0.0.0:<port>`，设备端只提供 HTTP。文档已明确局域网 HTTP 下 Token 和 Session 可被同网段监听者窃取。切换“外部 HTTPS”只会把 Cookie 标记为 `Secure`，并不会禁止直连设备 HTTP 的 `/api/auth/session` 接收 Bearer Token。
- Impact：用户若误从局域网 HTTP 页面输入 Token，长期凭据会以明文经过网络；被动监听者可换取自己的 Session 并完整管理对应空间。外部 HTTPS 到设备 HTTP 的最后一跳安全性取决于 `OPS-Note` 中的隧道与局域网信任边界。
- Fix：外部模式优先让隧道直接落到手机回环地址并让服务绑定 `127.0.0.1`；若必须监听 LAN，使用主机防火墙只允许固定代理来源，或通过加密隧道覆盖最后一跳。可增加配置，使外部模式拒绝从非回环/非允许来源调用登录接口。
- Mitigation：继续禁用 Android App 在外部模式下的“打开局域网页”按钮；在 UI 与文档突出提示不要在 HTTP 页面输入 Token；用 `OPS-Note` 验证 8080 未暴露公网且 LAN ACL 正确。
- False positive notes：若设备、代理主机及最后一跳都位于完全可信且不可监听的网络，本项概率会降低；该基础设施不在本仓库，需单独核验。

### SEC-006：发布流水线缺少持续安全扫描与最小权限分层

- Rule ID：GO-DEPLOY-001 / REACT-SUPPLY-001
- Severity：Medium
- Location：`.github/workflows/release.yml:14-15,21-128`；`android/gradle/wrapper/gradle-wrapper.properties:3-5`
- Evidence：Release job 从开始即拥有 `contents: write`，并在同一 job 中执行 npm、Go、Gradle 依赖与构建；`actions/checkout` 没有禁用持久化凭据。CI 没有 `govulncheck`、`npm audit`、`go test -race` 或 CodeQL。GitHub 当前 Dependabot Security Updates/Alerts 未启用，Code Scanning 无分析；Gradle distribution 未配置 `distributionSha256Sum`，也未发现 Gradle dependency verification metadata。
- Impact：上游依赖、安装脚本或构建插件一旦被投毒，构建步骤拥有更大的仓库写入面；发布签名步骤还必须接触签名材料。缺少自动告警会延长依赖漏洞暴露时间。
- Fix：把只读构建/测试与有 `contents: write` 的发布拆成两个 job，构建 job 使用 `contents: read` 且 `persist-credentials: false`，发布 job 只下载已验证 artifact；加入 `govulncheck`、`npm audit`、race test 和 CodeQL/Dependabot；为 Gradle wrapper增加官方 SHA-256，并启用依赖校验。
- Mitigation：当前 Actions 已按 commit SHA 固定、npm 有 lockfile、Go 有 `go.sum`，这些控制应保留；签名 Secrets 继续只在发布步骤注入。
- False positive notes：本次即时 `govulncheck` 与 `npm audit` 均为 0 漏洞，且 Secret Scanning/Push Protection 已启用；风险在于持续检测与流水线权限，而不是当前已知恶意依赖。

## Low

### SEC-007：Cookie 写接口的 CSRF 防护允许缺失 Origin，且没有自定义请求头/CSRF Token

- Rule ID：GO-HTTP-006 / REACT-CSRF-001
- Severity：Low
- Location：`internal/backend/server.go:390-413,695-705`；`frontend/src/api.ts:33-38,52-58,64-97`
- Evidence：`sameOrigin` 在没有 `Origin` 时直接放行，只比较 Host、不比较 scheme。使用 Session Cookie 的上传和删除请求没有要求服务端验证的自定义头或 CSRF Token。
- Impact：当前 `SameSite=Strict`、浏览器 Origin、非简单 DELETE 方法和无 CORS 已显著降低主流浏览器中的可利用性；但若代理剥离 Origin、使用特殊客户端，或同站点子域与浏览器行为组合变化，状态修改将缺少独立的请求意图证明。上传是 `multipart/form-data`，尤其应防御简单跨源 POST。
- Fix：为所有 Cookie 认证的 POST/DELETE 要求固定自定义头（例如 `X-PocketIMG-Request: 1`）并在服务端验证；或实现标准 CSRF Token。对状态修改请求在没有 Origin/Referer/Fetch Metadata 时默认拒绝，并明确处理代理后的公开 scheme。
- Mitigation：保持 `SameSite=Strict`、Host-only Secure Cookie、无 CORS和现有 Origin 校验；确认 Caddy 不删除 `Origin`。
- False positive notes：未证明可在当前 Chrome/Edge 配置下直接完成跨站利用，因此按 Low 而非 High 评级。

### SEC-008：后端接受任意非空 Token，弱配置会退化为可猜凭据

- Rule ID：GO-CONFIG-001 / GO-AUTH-001
- Severity：Low
- Location：`internal/backend/server.go:173-200` `configuredCredentials`；`android/app/src/main/java/com/gmch/pocketimg/ServiceSettings.kt:123-127`
- Evidence：后端只拒绝空 Token，不设最小长度或格式；Android 自动生成路径使用 32 字节 `SecureRandom`，但独立二进制的环境变量/JSON 配置可传入单字符 Token。
- Impact：运维误配置弱 Token 时，公网登录接口和无速率限制组合会导致空间完全失陷。数据库中 SHA-256 指纹也会使弱 Token 在数据库泄露后易于离线猜测。
- Fix：启动时强制至少 32 字节随机熵对应的编码长度，提供官方 token 生成命令，并让示例值在直接使用时明确启动失败。
- Mitigation：继续使用 Android 自动生成的 256-bit Token；人工配置使用密码学随机 32 字节以上并定期轮换。
- False positive notes：当前 Android 默认 Token 生成是安全的；本项针对手工配置入口，未读取或评估线上真实 Token 内容。

### SEC-009：HTTP Server 未显式收紧 `MaxHeaderBytes`

- Rule ID：GO-HTTP-001
- Severity：Low
- Location：`cmd/server/main.go:46-53`
- Evidence：服务设置了读取 Header、请求体、写响应和空闲超时，但没有设置 `MaxHeaderBytes`。
- Impact：Go 在字段为零时仍使用标准库默认上限（约 1 MiB），所以不是无界读取；但对只需要很小 Cookie/Authorization 的服务而言上限过宽，且应用安全边界依赖隐式默认值。
- Fix：显式设置适合本服务的值，例如 32–64 KiB，并在 Caddy 保持不高于应用的请求头限制。
- Mitigation：确认公网代理已有更严格的 Header 上限与慢连接防护。
- False positive notes：由于 Go 存在默认上限且公网还有 Caddy，此项仅按 Low 评级。

## 已接受的设计边界（不计为漏洞）

- `/i/*` 与 `/t/*` 不鉴权是明确需求。128-bit 随机 ID 能防枚举，但 URL 一旦泄露，任何人都可读取。
- 图片响应使用 `Cache-Control: public, max-age=31536000, immutable`。服务端永久删除只能保证源站文件和元数据删除，不能召回浏览器、共享缓存或已下载副本；UI/文档应避免把“永久删除”解释为全球副本可撤销。
- GIF/动画文件按需求原样保存，可能保留注释或元数据；静态 PNG/JPEG/带元数据静态 WebP 的重编码净化不代表动画文件也完成隐私清理。
- Root 用户、已攻破的 Android 系统或拿到发布签名密钥的攻击者不在 App 沙箱可防御范围内。

## 建议修复顺序

1. 先实现每空间配额、全局磁盘保留线和上传预算（SEC-001）。
2. 给缩略图任务加失败状态、批次、重试上限与退避（SEC-002）。
3. 一并增加每空间上传限速、Session 上限与周期清理（SEC-003）。
4. 在应用或 Caddy 加 CSP/`frame-ancestors`，并给写请求加自定义 CSRF 头（SEC-004、SEC-007）。
5. 在 `OPS-Note` 核验 8080 暴露面和最后一跳加密/ACL（SEC-005）。
6. 拆分只读构建与发布权限，启用持续依赖/代码扫描（SEC-006）。
