# 产品展示素材

| 文件 | 来源 | 用途 |
| --- | --- | --- |
| `gallery.png` | 当前 Web 页面真实浏览器截图 | 图库概览 |
| `preview.png` | 当前 Web 页面真实浏览器截图 | 大图预览与操作 |
| `shot-workflow.svg` | 项目内手工维护的矢量说明图 | Mac 截图到分享的流程，非应用实拍 |

Web 截图为 1280 × 780 CSS 像素、2 倍像素密度。使用隔离的本地图床、临时演示账号，通过正常登录及上传接口填充 18 张项目原创几何排版样张。样张不是产品界面，也不代表图床具备排版或绘图功能。截图没有合成按钮或修改应用 DOM，不包含真实用户数据、Token 或生产地址。

本批素材没有使用 AI 生成图片；Mac 工作流程图明确注明“非应用实拍”。以后有 Mac 环境时，优先补拍真实的截图标注与贴图状态，演示屏幕同样避免个人数据。

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
