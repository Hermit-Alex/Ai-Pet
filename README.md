# Ai-Pet

AI 宠是一个家庭宠物 Agent 项目。当前阶段先围绕“真实宠物微信号进入家庭群互动”做本地 MVP：Bridge 负责宠物档案、人格、记忆、微信群行为控制、日志审计和 OpenClaw 调用；本地前端控制台负责配置与人工审核；Windows 微信 sidecar 负责观察真实桌面微信环境。

当前实现坚持真实账号安全优先：不 Hook、不逆向协议、不自动加好友、不主动私聊、不做陌生群扩散。默认观察模式和人工审核优先，自动回复需要显式开启。

## 当前能力

- 本地 Bridge API：`http://127.0.0.1:8787`
- 本地控制台：`http://127.0.0.1:8787/ui`
- 宠物档案、事件、记忆 SQLite 存储
- 猫咪人格问卷评分，生成 `persona_profile` 和 `system_prompt`
- 微信群 allowlist、唤醒词、安静时段、频率限制、人工审核、紧急停止
- 群聊回复预览接口：`POST /pets/{pet_id}/wechat/reply`
- 私聊回复预览与发送审计接口：`POST /pets/{pet_id}/wechat/private-reply`、`POST /pets/{pet_id}/wechat/private-sent`
- JSONL 日志审计：`logs/aipet-bridge.jsonl`、`logs/wechat-sidecar.jsonl`、`logs/audit-events.jsonl`、`logs/errors.jsonl`
- Windows 微信 sidecar CLI：支持桌面微信探测、私聊只读观察、allowlist 私聊低频自动回复；群聊自动发送暂未开放

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
│ 档案、人格问卷、微信策略、群聊/私聊测试、日志查看            │
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
│ 真实宠物微信号、allowlist 联系人/家庭群                     │
└────────────────────────────────────────────────────────────┘
```

### 核心组件

- **Bridge 后端**：`src/aipet_bridge`，使用 FastAPI 提供本地 HTTP API。它是所有业务规则的中心，负责档案、人格、记忆、微信策略、回复生成、安全拦截、频率限制和审计日志。
- **本地数据库**：SQLite，默认位于 `.data/aipet.sqlite3`。保存宠物档案、事件、记忆、人设 JSON、微信策略、已处理消息指纹和回复记录。
- **本地控制台**：静态 HTML 页面，挂载在 `/ui`。用于配置宠物资料、微信 allowlist、群聊/私聊测试、紧急停止和日志查询。
- **OpenClaw/模型层**：Bridge 通过 OpenAI-compatible Chat Completions 调用 OpenClaw Gateway；如果 `AIPET_OPENCLAW_BASE_URL` 未配置，则使用本地安全兜底回复，保证测试链路不断。
- **Windows 微信 sidecar**：`src/aipet_wechat_sidecar`，通过原生 UIAutomation 观察和操作当前桌面微信窗口。当前只对 allowlist 私聊联系人支持低频自动回复；群聊自动发送仍保持关闭。
- **日志系统**：JSONL 文件位于 `logs/`，默认只记录摘要和结构化事件，不记录 API key、Authorization header、完整模型响应和完整聊天正文。

### 数据流

- **控制台测试流**：浏览器 `/ui` → Bridge `/wechat/reply` 或 `/wechat/private-reply` → 人格/记忆/策略注入 → OpenClaw 或本地兜底 → JSONL 日志 → 控制台展示回复和 `trace_id`。
- **私聊自动回复流**：sidecar 读取当前微信私聊窗口 → 校验联系人在 `private_contact_allowlist` → Bridge 生成回复并做频控/安全拦截 → sidecar 二次确认当前窗口联系人和输入框 → 粘贴并回车发送 → Bridge 记录 `private-sent` 审计事件。
- **群聊流**：当前只支持测试台和手动桥接预览。群聊自动点击发送未开放，避免真实账号在群聊场景误发。

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

OpenClaw 没准备好时，可以先让 `AIPET_OPENCLAW_BASE_URL` 留空，Bridge 会使用本地安全兜底回复，方便先验证前端、人格和行为控制。

OpenClaw Gateway 准备好后再设置：

```text
AIPET_OPENCLAW_BASE_URL=http://127.0.0.1:18789/v1
AIPET_OPENCLAW_MODEL=ai-pet-wechat
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
3. 配置家庭微信群 allowlist、唤醒词、安静时段、频率限制。
4. 在测试台输入群名、发言人和消息，先只生成回复。
5. 人工确认或拒绝，查看日志里的 `trace_id`。

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
openclaw --version
```

初始化并启动 Gateway：

```powershell
openclaw onboard
openclaw agents add ai-pet-wechat --workspace "E:\code\AI\Ai Pet\.openclaw\workspace-ai-pet-wechat"
openclaw gateway run
```

OpenClaw 能通过 `http://127.0.0.1:18789/v1/chat/completions` 响应后，把 `.env.local` 的 `AIPET_OPENCLAW_BASE_URL` 设置为 `http://127.0.0.1:18789/v1`，重启 Bridge。

## 6. 真实微信号上线流程

真实宠物微信号按长期账号处理，建议三阶段上线：

1. 观察模式：sidecar 只探测微信窗口和 Bridge 状态，不发送消息。
2. 人工审核：微信群消息进入测试台或 sidecar 后，只生成回复，由人复制或确认发送。
3. 小流量自动：只在家庭群 allowlist、明确 @ 或唤醒、非安静时段、未超频时启用。

检查 sidecar 状态：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sidecar-status.ps1
```

手动把一条群消息送入 Bridge 预览：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli `
  --bridge-url http://127.0.0.1:8787 `
  --pet-id cat-home `
  manual-message `
  --group "家庭群" `
  --sender "老婆" `
  --message "@猫咪 你在干嘛" `
  --mentioned
```

当前 sidecar 仍不做群聊自动点击发送。后续实现群聊自动发送时，必须继续保持 fail-closed：群名不确定、不在 allowlist、窗口识别失败、消息重复、频率超限、紧急停止时都不能发送。

## 6.1 私聊联系人低频自动回复

第一版私聊自动回复只支持 allowlist 联系人，并且要求微信主窗口在当前桌面可见、未锁屏、未最小化。不使用 Hook、协议逆向或数据库解密。

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
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8789 inspect-ui --limit 80
```

打开其中一个 allowlist 联系人的私聊窗口，做只读观察：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8789 observe-private --contact "联系人昵称"
```

如果能看到 `ok: true`、`contact_name` 和 `latest_message`，先用 dry-run 跑自动回复循环：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8789 run-private-autoreply --contact "联系人昵称" --dry-run
```

确认日志和回复内容正确后，再移除 `--dry-run` 开启低频自动发送：

```powershell
.\.venv\Scripts\python.exe -m aipet_wechat_sidecar.cli --bridge-url http://127.0.0.1:8789 run-private-autoreply --contact "联系人昵称"
```

安全规则：

- 当前聊天标题必须匹配 allowlist 联系人。
- Bridge 返回 `should_reply=true` 且 `auto_reply_enabled=true` 才会发送。
- 找不到输入框、联系人不匹配、消息重复、紧急停止、超频都会停止发送。
- 关闭方式：在控制台勾选 Emergency stop，或直接停止 sidecar PowerShell。

## 7. 日志和审计

日志默认只记录摘要，不记录完整群聊正文、API key、Authorization header、完整模型响应。

查看日志：

- 控制台日志页：`http://127.0.0.1:8787/ui`
- API：`GET /logs?trace_id=...`
- 文件目录：`logs/`

关键事件：

- `wechat.message.detected`
- `wechat.message.ignored`
- `wechat.reply.requested`
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

1. 打开控制台微信群配置页。
2. 点击“立即停用自动化”。
3. 确认 `emergency_stop=true`、`auto_reply_enabled=false`。

## 8. 测试

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

测试覆盖：

- 宠物状态和记忆检索
- 人格问卷生成
- 非 allowlist 群拦截
- 默认人工审核
- 消息去重

## 9. 后续部署形态

Mac Mini M4 或树莓派适合运行 Bridge、RAG、设备接入、传感器聚合、日志和前端控制台。

普通个人微信群通道仍需要 Windows 桌面微信通道机，因为当前方案依赖 Windows 微信 UI 自动化。长期产品化不建议依赖个人微信自动化，应评估 QQ Bot、企业微信、公众号/小程序、自有 App 或硬件中控作为正式通道。
