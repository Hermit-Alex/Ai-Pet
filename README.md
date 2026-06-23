# Ai-Pet

AI 宠是一个家庭宠物 Agent 项目。当前阶段先围绕“真实宠物微信号和家人私聊互动”做本地 MVP：Bridge 负责宠物档案、人格、记忆、私聊行为控制、日志审计和 OpenClaw 调用；本地前端控制台负责配置与测试；Windows 微信 sidecar 负责观察并操作真实桌面微信的当前私聊窗口。

当前实现坚持真实账号安全优先：不 Hook、不逆向协议、不自动加好友、不主动私聊陌生人、不处理群聊自动发送。私聊自动回复只面向显式 allowlist 联系人，并且需要显式开启。

## 当前能力

- 本地 Bridge API：`http://127.0.0.1:8787`
- 本地控制台：`http://127.0.0.1:8787/ui`
- 宠物档案、事件、记忆 SQLite 存储
- 猫咪人格问卷评分，生成 `persona_profile` 和 `system_prompt`
- 私聊联系人 allowlist、安静时段、频率限制、每日上限、紧急停止
- 私聊回复预览与发送审计接口：`POST /pets/{pet_id}/wechat/private-reply`、`POST /pets/{pet_id}/wechat/private-sent`
- 群聊接口保留为实验/兼容入口，当前 Milestone 不监听群聊、不自动回复群聊
- JSONL 日志审计：`logs/aipet-bridge.jsonl`、`logs/wechat-sidecar.jsonl`、`logs/audit-events.jsonl`、`logs/errors.jsonl`
- Windows 微信 sidecar CLI：支持桌面微信探测、私聊只读观察、allowlist 私聊低频自动回复

## 目录

```text
src/aipet_bridge          Bridge API、人格、微信策略、日志、前端控制台
src/aipet_wechat_sidecar  Windows 微信 sidecar CLI
tests                     单元测试
scripts                   本地开发和启动脚本
.data                     本地 SQLite 数据，已被 Git 忽略
logs                      本地 JSONL 日志，已被 Git 忽略
```

## 技术架构

当前 MVP 是一个本地优先、真实微信号安全优先的分层架构：

```text
┌────────────────────────────────────────────────────────────┐
│ 本地控制台 /ui                                             │
│ 档案、人格问卷、私聊策略、OpenClaw 单聊测试、日志查看        │
└──────────────────────────────┬─────────────────────────────┘
                               │ HTTP
┌──────────────────────────────▼─────────────────────────────┐
│ AI Pet Bridge (FastAPI, 127.0.0.1)                         │
│ 宠物档案、人格、记忆、微信策略、安全拦截、频控、日志审计       │
└───────────────┬──────────────────────────────┬─────────────┘
                │                              │
                │ SQLite                       │ OpenAI-compatible HTTP
┌───────────────▼──────────────┐     ┌────────▼──────────────┐
│ .data/aipet.sqlite3          │     │ OpenClaw Gateway       │
│ profile/persona/memory/seen  │     │ DeepSeek / local model │
└──────────────────────────────┘     └───────────────────────┘
                ▲
                │ HTTP
┌───────────────┴────────────────────────────────────────────┐
│ Windows WeChat Sidecar (uiautomation)                     │
│ inspect-ui / observe-private / run-private-autoreply       │
└───────────────┬────────────────────────────────────────────┘
                │ UIAutomation, no Hook, no protocol reverse
┌───────────────▼────────────────────────────────────────────┐
│ Windows 桌面微信客户端                                      │
│ 真实宠物微信号、allowlist 私聊联系人                         │
└────────────────────────────────────────────────────────────┘
```

### 核心组件

- **Bridge 后端**：`src/aipet_bridge`，使用 FastAPI 提供本地 HTTP API。它是所有业务规则的中心，负责档案、人格、记忆、微信策略、回复生成、安全拦截、频率限制和审计日志。
- **本地数据库**：SQLite，默认位于 `.data/aipet.sqlite3`。保存宠物档案、事件、记忆、人设 JSON、微信策略、已处理消息指纹和回复记录。
- **本地控制台**：静态 HTML 页面，挂载在 `/ui`。用于配置宠物资料、私聊 allowlist、OpenClaw 单聊测试、紧急停止和日志查询。
- **OpenClaw/模型层**：Bridge 通过 OpenAI-compatible Chat Completions 调用 OpenClaw Gateway；如果 `AIPET_OPENCLAW_BASE_URL` 未配置，则使用本地安全兜底回复，保证测试链路不断。
- **Windows 微信 sidecar**：`src/aipet_wechat_sidecar`，通过原生 UIAutomation 观察和操作当前桌面微信窗口。当前只对 allowlist 私聊联系人支持低频自动回复；群聊监听和群聊发送暂停。
- **日志系统**：JSONL 文件位于 `logs/`，默认只记录摘要和结构化事件，不记录 API key、Authorization header、完整模型响应和完整聊天正文。

### 数据流

- **控制台测试流**：浏览器 `/ui` → Bridge `/wechat/private-reply` → 人格/记忆/私聊策略注入 → OpenClaw 或本地兜底 → JSONL 日志 → 控制台展示回复和 `trace_id`。
- **私聊自动回复流**：sidecar 读取当前微信私聊窗口 → 校验联系人在 `private_contact_allowlist` → Bridge 生成回复并做频控/安全拦截 → sidecar 二次确认当前窗口联系人和输入框 → 粘贴并回车发送 → Bridge 记录 `private-sent` 审计事件。
- **群聊流**：当前 Milestone 暂停。历史群聊预览接口保留用于后续恢复，不作为部署和测试路径。

### 安全边界

- 不使用 Hook、DLL 注入、协议逆向、数据库解密。
- 所有微信自动化只允许本地 `127.0.0.1` 服务和当前桌面微信客户端参与。
- 发送前必须满足 allowlist、非紧急停止、非安静时段、未超频、消息未重复、回复非空。
- sidecar 看不到微信 UI、联系人标题不匹配、找不到输入框、窗口最小化/锁屏/远程桌面断开时默认不发送。
- 私聊自动回复只处理显式配置的联系人；不处理陌生人、好友申请、公众号、文件传输助手和群聊自动发送。

### 当前限制

- OpenClaw 未配置时只能使用本地兜底回复，回复质量有限。
- sidecar 必须运行在登录宠物微信号的同一个 Windows 交互桌面中，Codex 后台执行通道通常看不到 UIAutomation 控件树。
- 当前私聊 UI 识别是 MVP 级启发式实现，依赖桌面微信版本、窗口布局和控件树可见性。
- Mac Mini M4 或树莓派适合运行 Bridge/RAG/设备接入，但个人微信 UIAutomation 通道仍需要 Windows 桌面微信通道机。

## 1. E 盘环境准备

本项目默认把 Python 虚拟环境、pip 缓存、数据和日志放在仓库目录，减少 C 盘占用。

```powershell
cd "E:\code\AI\Ai Pet"
powershell -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install
```

启用虚拟环境：

```powershell
.\.venv\Scripts\Activate.ps1
```

如果需要 Windows UIAutomation 探测能力，可安装可选依赖：

```powershell
.\.venv\Scripts\python.exe -m pip install --no-user -e ".[wechat]"
```

## 2. 本地配置

复制配置文件：

```powershell
Copy-Item .env.example .env.local
```

常用配置：

```text
AIPET_DATA_DIR=.data
AIPET_LOGS_DIR=logs
AIPET_DEFAULT_PET_ID=cat-home
AIPET_DEFAULT_PET_NAME=猫咪
AIPET_LOG_SENSITIVE=false
```

当前单聊 MVP 的正式模型入口是 OpenClaw Gateway。OpenClaw 没准备好时，可以先让 `AIPET_OPENCLAW_BASE_URL` 留空，Bridge 会使用本地安全兜底回复做冒烟测试；真正测试宠物人格回复质量前，需要配置 OpenClaw。

OpenClaw Gateway 准备好后再设置：

```text
AIPET_OPENCLAW_BASE_URL=http://127.0.0.1:18789/v1
AIPET_OPENCLAW_API_KEY=<OpenClaw gateway token>
AIPET_OPENCLAW_MODEL=openclaw/default
```

不要把 `.env.local` 提交到 Git。

## 3. 初始化数据库

```powershell
.\.venv\Scripts\python.exe -m aipet_bridge.cli init-db
.\.venv\Scripts\python.exe -m aipet_bridge.cli seed-demo
```

## 4. 启动 Bridge 和控制台

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1
```

如果 `8787` 已被旧服务占用，可以换端口：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1 -Port 8788
```

打开：

- 控制台：`http://127.0.0.1:8787/ui`，换端口时相应改成 `8788`
- API 文档：`http://127.0.0.1:8787/docs`
- 健康检查：`http://127.0.0.1:8787/health`

在控制台里按顺序完成：

1. 填写宠物档案。
2. 完成人格问卷并生成人格。
3. 配置私聊联系人 allowlist、安静时段、频率限制和每日上限。
4. 在测试台输入联系人昵称和消息，先只生成回复。
5. 查看回复结果、`trace_id` 和日志链路。

## 5. OpenClaw 部署建议

Windows PowerShell 里 `npm.ps1` 可能被执行策略拦截，优先使用 `npm.cmd`。

把 npm 全局目录和缓存放到项目目录：

```powershell
cd "E:\code\AI\Ai Pet"
New-Item -ItemType Directory -Force -Path .\.cache\npm-prefix, .\.cache\npm-cache
npm.cmd config set prefix "E:\code\AI\Ai Pet\.cache\npm-prefix"
npm.cmd config set cache "E:\code\AI\Ai Pet\.cache\npm-cache"
npm.cmd install -g openclaw@latest
```

把 OpenClaw 的 npm bin 加到当前终端 PATH：

```powershell
$env:PATH = "E:\code\AI\Ai Pet\.cache\npm-prefix;$env:PATH"
openclaw.cmd --version
```

把 OpenClaw 状态也放到项目目录，并初始化本地配置：

```powershell
$env:OPENCLAW_STATE_DIR = "E:\code\AI\Ai Pet\.openclaw"
$env:OPENCLAW_CONFIG_PATH = "E:\code\AI\Ai Pet\.openclaw\openclaw.json"

openclaw.cmd setup `
  --non-interactive `
  --accept-risk `
  --mode local `
  --workspace "E:\code\AI\Ai Pet\.openclaw\workspace-ai-pet-wechat"
```

安装 DeepSeek provider、设置默认模型，并启用 OpenAI-compatible Chat Completions：

```powershell
openclaw.cmd plugins install @openclaw/deepseek-provider
openclaw.cmd models set deepseek/deepseek-v4-flash
openclaw.cmd config set gateway.http.endpoints.chatCompletions.enabled true --strict-json
```

把 DeepSeek API key 放进 OpenClaw 本地环境文件，不要提交：

```powershell
"DEEPSEEK_API_KEY=<your-deepseek-key>" | Set-Content -Encoding UTF8 "E:\code\AI\Ai Pet\.openclaw\.env"
```

启动 Gateway：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1
```

OpenClaw 能通过 `http://127.0.0.1:18789/v1/chat/completions` 响应后，把 `.env.local` 的 `AIPET_OPENCLAW_BASE_URL` 设置为 `http://127.0.0.1:18789/v1`，`AIPET_OPENCLAW_MODEL` 设置为 `openclaw/default`，`AIPET_OPENCLAW_API_KEY` 设置为 OpenClaw Gateway token，然后重启 Bridge。

## 6. 真实微信号单聊上线流程

真实宠物微信号按长期账号处理，当前只上线私聊路径，建议三阶段执行：

1. 只读观察：sidecar 只探测微信窗口和当前私聊窗口，不发送消息。
2. dry-run：sidecar 读取 allowlist 联系人的消息，调用 Bridge/OpenClaw 生成回复，但不发送。
3. 小流量自动：只对 allowlist 联系人、非安静时段、未超频、未触发紧急停止的消息发送。

检查 sidecar 状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sidecar-status.ps1
```

### 私聊联系人低频自动回复

第一版私聊自动回复只支持 allowlist 联系人，并且要求微信主窗口在当前桌面可见、未锁屏、未最小化。不使用 Hook、协议逆向或数据库解密。当前 sidecar 只读取当前打开的私聊窗口，不后台遍历所有联系人。

在控制台的 WeChat 页面配置：

```text
Private contact allowlist: 填两个允许自动回复的联系人昵称
Private low-frequency auto reply: 勾选
Private interval minutes: 默认 5
Private daily limit: 默认 30
Emergency stop: 确认未勾选
```

先在登录微信的同一个桌面 PowerShell 中做只读检查：

```powershell
cd "E:\code\AI\Ai Pet"
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8787 inspect-ui
```

打开其中一个 allowlist 联系人的私聊窗口，做只读观察：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8787 observe-private --contact "联系人昵称"
```

如果能看到 `ok: true`、`contact_name` 和 `latest_message`，先用 dry-run 跑自动回复循环：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8787 run-private-autoreply --contact "联系人昵称" --dry-run
```

确认日志和回复内容正确后，再移除 `--dry-run` 开启低频自动发送：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8787 run-private-autoreply --contact "联系人昵称"
```

安全规则：

- 当前聊天标题必须匹配 allowlist 联系人。
- Bridge 返回 `should_reply=true` 且 `auto_reply_enabled=true` 才会发送。
- 找不到输入框、联系人不匹配、消息重复、紧急停止、超频都会停止发送。
- 关闭方式：在控制台勾选 Emergency stop，或直接停止 sidecar PowerShell。

## 7. 日志和审计

日志默认只记录摘要，不记录完整私聊正文、API key、Authorization header、完整模型响应。

查看日志：

- 控制台日志页：`http://127.0.0.1:8787/ui`
- API：`GET /logs?trace_id=...`
- 文件目录：`logs/`

关键事件：

- `wechat.private.detected`
- `wechat.private.ignored`
- `wechat.private.reply.generated`
- `wechat.private.reply.sent`
- `wechat.manual.approved`
- `wechat.manual.rejected`
- `bridge.reply.started`
- `bridge.openclaw.completed`
- `bridge.openclaw.failed`
- `bridge.safety.blocked`
- `bridge.rate_limited`
- `memory.read`
- `memory.write`

紧急停止：

1. 打开控制台 WeChat 页面。
2. 点击“立即停用自动化”。
3. 确认 `emergency_stop=true`、`private_auto_reply_enabled=false`、`auto_reply_enabled=false`。

## 8. 测试

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

测试覆盖：

- 宠物状态和记忆检索
- 人格问卷生成
- 私聊联系人 allowlist 拦截
- 私聊自动回复生成
- 消息去重和频率限制
- 群聊接口兼容性拦截

## 9. 后续部署形态

Mac Mini M4 或树莓派适合运行 Bridge、RAG、设备接入、传感器聚合、日志和前端控制台。

个人微信私聊通道仍需要 Windows 桌面微信通道机，因为当前方案依赖 Windows 微信 UI 自动化。长期产品化不建议依赖个人微信自动化，应评估 QQ Bot、企业微信、公众号/小程序、自有 App 或硬件中控作为正式通道。群聊监听和群聊回复作为后续能力单独评估，不进入当前 MVP。
