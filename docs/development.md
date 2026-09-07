# 本地构建与开发

以下用于开发或自定义部署。普通安装请从 [README](../README.md#快速开始) 进入，不需要手工准备 Token。

### 1. 准备 Token

复制示例配置：

```bash
cp tokens.example.json tokens.json
chmod 600 tokens.json
```

Token 文件是一个 JSON 对象。对象 key 是稳定空间 ID，value 是该空间的长期 Token：

```json
{
  "alice": "replace-with-a-long-random-token",
  "bob": "replace-with-another-long-random-token"
}
```

空间 ID 只能包含字母、数字、下划线和连字符，最多 64 个字符。

空间 ID 决定数据归属。轮换 Token 时只修改对应 value，不要修改空间 ID。

实际使用的 `tokens.json` 已被 `.gitignore` 排除，不应提交到仓库。

### 2. 构建 Linux x86_64 后端

```bash
make frontend-install
make build-amd64
```

输出文件：

```text
dist/phone-image-host-linux-amd64
```

### 3. 启动本地 HTTP 服务

```bash
PIH_TOKENS_FILE='./tokens.json' \
PIH_ADMIN_SPACE_ID='alice' \
PIH_COOKIE_SECURE=false \
./dist/phone-image-host-linux-amd64
```

默认监听地址为 `127.0.0.1:8080`。

`PIH_COOKIE_SECURE=false` 只适用于本机或可信局域网 HTTP。通过外部 HTTPS 入口使用时，应保留默认值 `true`。

只有一个配置空间时可以省略 `PIH_ADMIN_SPACE_ID`。配置多个空间时，必须明确指定其中一个管理员空间。

也可以通过 `PIH_TOKENS` 传入 JSON，或通过旧版 `PIH_TOKEN` 配置单空间。`PIH_TOKENS_FILE`、`PIH_TOKENS` 和 `PIH_TOKEN` 三者只能选择一个。

## 常用验证命令

```bash
make test
make build-amd64
make build-arm64
make android-test
make android-debug
```

macOS 环境还可以运行：

```bash
make macos-test
make macos-build
```
