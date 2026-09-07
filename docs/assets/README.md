# 产品展示素材

| 文件 | 来源 | 用途 |
| --- | --- | --- |
| `gallery.png` | 当前 Web 页面真实浏览器截图 | 图库概览 |
| `preview.png` | 当前 Web 页面真实浏览器截图 | 大图预览与操作 |
| `shot-workflow.svg` | 项目内手工维护的矢量说明图 | Mac 截图到分享的流程，非应用实拍 |
| `shot-interface.svg` | 依据 `CaptureOverlayView.swift` 绘制的矢量示意 | 桌面与应用选区、八个手柄、尺寸标签、标注与九按钮工具栏，非实拍 |
| `shot-cli.svg` | 项目内手工维护的矢量说明图 | 上传后自动复制 URL，再手动粘贴到 CLI，非终端实拍 |
| `../../frontend/public/favicon.svg` | 项目原创矢量图标母版 | 图片卡片与上传箭头；生成 Mac、fnOS、ICO 资源 |

Web 截图为 1280 × 780 CSS 像素、2 倍像素密度。使用隔离的本地图床、临时演示账号，通过正常登录及上传接口填充 18 张项目原创几何排版样张。样张不是产品界面，也不代表图床具备排版或绘图功能。截图没有合成按钮或修改应用 DOM，不包含真实用户数据、Token 或生产地址。

本批素材未使用图片生成服务；示意图由项目内 SVG 源码绘制，并明确标注非实拍。Mac 界面图的壁纸、背景应用与内容为原创演示素材，图外说明不属于真实 UI。以配置完整、标注工具未激活的编辑状态为例；尺寸按 2 倍 Retina 比例示意，实际外观受系统强调色和显示缩放影响。没有加入马赛克、长截图或窗口吸附等尚未支持的能力。

CLI 图仅说明剪贴板流转，依据 `AppController.swift` 上传成功后写入 URL 的行为，不表示自动输入、自动执行命令，也不表示已经对特定 CLI 完成读图验证。所有 URL 使用保留的 example.com 演示域名。

以后有 Mac 环境时，优先补拍真实的截图标注与贴图状态，演示屏幕同样避免个人数据。

## 图标与矢量素材

`frontend/public/favicon.svg` 是统一图标母版：绿色渐变底、浅色图片卡片与上传箭头。Mac 菜单栏继续使用高对比单色截图模板图标，以适配系统深浅色外观；Android 启动图标本次不变。

沿用下方的 Playwright 安装方式后，可重新生成 Mac 的全部 10 个 AppIcon 文件、fnOS 的 64/256 像素图标，以及包含 16/32/48/64/128/256 六个尺寸的 `frontend/public/favicon.ico`：

```bash
PLAYWRIGHT_MODULE="$visual_tools/node_modules/playwright/index.mjs" \
  node scripts/generate-brand-assets.mjs
```

需要 Go、Node.js、Playwright 和 Chromium；已有浏览器可通过 `CHROMIUM_PATH` 指定。脚本只覆盖上述生成资源，不改变 AppIcon 清单、签名或包标识；临时母版 PNG 自动清理。SVG 是可直接编辑的源文件，无需图片生成服务。浏览器打开 `shot-interface.svg`（1440 × 940）、`shot-cli.svg`（1440 × 600）即可检查或导出，不应将导出的 PNG 称为应用实拍。

## 复现 Web 截图

先构建当前前端和后端：

```bash
make frontend-install
make build-amd64
```

截图脚本需要 Node.js、Playwright、Chromium 和中文字体。工具依赖安装在临时目录，不修改应用的依赖清单：

```bash
visual_tools=$(mktemp -d /tmp/pocketimg-visual-tools.XXXXXX)
npm install --prefix "$visual_tools" --no-audit --no-fund playwright@1.63.0
node "$visual_tools/node_modules/playwright/cli.js" install chromium
PLAYWRIGHT_MODULE="$visual_tools/node_modules/playwright/index.mjs" \
  node scripts/capture-docs.mjs
```

如使用已有 Chromium，可额外设置 `CHROMIUM_PATH` 指向可执行文件。`POCKETIMG_BINARY` 可覆盖后端路径，默认是 `dist/phone-image-host-linux-amd64`。环境应包含中文字体（本次使用 Noto CJK）。

脚本会覆盖这两张演示截图，使用随机回环端口，不连接生产实例；完成或失败后关闭浏览器、停止后端并清理临时数据。图库日期为拍摄时的实际日期，重新拍摄时可能变化。`shot-workflow.svg` 直接编辑 SVG 即可，不依赖图片生成服务。
