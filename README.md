# AI Pet

AI Pet（AI 宠）是一个面向家庭宠物的本地优先 Agent 项目。目标是让猫、狗等家庭宠物拥有可持续维护的人格、记忆和状态表达，并能在严格行为控制下参与家庭聊天。

当前主线切回微信体验：使用 Windows 桌面微信登录真实宠物微信号，参考 [SEUWanglibo/openclaw-wechat-channel](https://github.com/SEUWanglibo/openclaw-wechat-channel) 的 `wxauto-restful-api + wxauto-channel` 分层方案。不过本项目默认不让 wxauto 通道直接调用 OpenClaw，而是使用 `aipet-wxauto-bridge-channel`：wxauto 只负责收发微信消息，回复决策、人格、记忆、频率限制、白名单、安全拦截和审计全部经过 AI Pet Bridge。

飞书方案保留为备选承接入口，不再作为家庭聊天主输出端。

## 当前能力

- 本地 Bridge API：`http://127.0.0.1:8787`
- 本地控制台：`http://127.0.0.1:8787/ui`
- 宠物档案、事件、记忆、人格问卷和 `system_prompt`
- 私聊联系人 allowlist、家庭群 allowlist、唤醒词、安静时段、频率限制、每日上限和紧急停止
- OpenClaw Gateway / DeepSeek OpenAI-compatible provider 接入
- wxauto / wxautox4 微信 PC 通道配置与启动脚本
- JSONL 审计日志，支持用 `trace_id` 串起检测、判断、生成和发送结果

## 架构

```text
家庭成员微信
  -> Windows 微信 PC（登录真实宠物微信号）
  -> wxauto-restful-api
  -> aipet-wxauto-bridge-channel
  -> AI Pet Bridge（人格、记忆、RAG、行为控制、审计）
  -> OpenClaw Gateway
  -> DeepSeek / OpenAI-compatible Model
  -> AI Pet Bridge
  -> wxauto-restful-api
  -> Windows 微信 PC
```

参考项目的原始 `wxauto-channel.py` 仍可作为调研和回退入口，但真实账号默认使用 AI Pet Bridge 通道，避免绕过白名单、频率限制和审计。

## 安全原则

- 默认只在本机局域环境运行，不暴露公网服务。
- 默认只处理配置过的家庭成员私聊或家庭群。
- 群聊默认 `at_me_only`，只响应明确 `@宠物微信昵称` 的消息。
- 私聊和群聊都必须经过 Bridge 的 allowlist、频控、安静时段和紧急停止。
- `manual_review=true` 时，私聊和群聊都只生成不发送；切换到 `private-auto` 或临时满血实发脚本时才会关闭人工审核。
- 微信通道默认只处理文本消息；图片、语音、视频和文件只记拦截日志，不进入 AI 回复链路。
- 不主动加好友、不主动拉群、不处理陌生人、不做扩散。
- 不泄露家庭隐私、账号密钥、设备画面、住址、行程等信息。
- OpenClaw 工具权限应保持收紧，聊天 Agent 不应操作本机文件、命令、浏览器或插件工具。
- wxauto / wxautox 属于桌面微信自动化生态，存在第三方组件授权和微信账号风控风险，只建议在真实家庭小范围、低频使用。

## 快速开始

在 Windows PowerShell 中执行：

```powershell
cd "E:\code\AI\Ai Pet"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install
Copy-Item .env.example .env.local
.\.venv\Scripts\python.exe -m aipet_bridge.cli init-db
.\.venv\Scripts\python.exe -m aipet_bridge.cli seed-demo
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1
```

打开：

- 控制台：`http://127.0.0.1:8787/ui`
- API 文档：`http://127.0.0.1:8787/docs`
- 健康检查：`http://127.0.0.1:8787/health`

运行测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

## 微信通道

首次准备：

```powershell
# 克隆参考通道并安装 wxauto / wxautox4 相关依赖，依赖会安装到当前项目 .venv
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-wxauto-openclaw-channel.ps1 -InstallDeps

# 保存并激活 wxautox4 授权码，真实授权码只写入 .env.local
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\save-wxautox4-license.ps1 -LicenseKey "<your-code>"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1

# 配置真实宠物微信号的安全边界，并同步生成 wxauto 配置
# 首次建议 observe 模式：只生成、不自动发送
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-aipet-wechat-family.ps1 `
  -PetWechatName "<宠物微信昵称>" `
  -PrivateContact "爸爸","妈妈" `
  -FamilyGroup "<家庭群准确群名>" `
  -Mode observe

# 紧急停止：保留白名单等配置，但立即关闭私聊/群聊自动回复并进入人工审核
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emergency-stop-aipet-wechat.ps1

# 如果需要更硬的刹车，同时停止 wxauto API / 通道进程
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emergency-stop-aipet-wechat.ps1 -StopWxautoProcesses

# 不碰真实微信发送，先用 synthetic wxauto 消息验证 Bridge 通道
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-aipet-wxauto-bridge-channel.ps1

# 汇总诊断满血版链路的所有前置条件
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor-ai-pet-wechat-full.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor-ai-pet-wechat-full.ps1 -RunE2E
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor-ai-pet-wechat-full.ps1 -FullE2E -Strict
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wxauto-openclaw-status.ps1 -Strict
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit-ai-pet-wechat-full-readiness.ps1

# wxauto API 启动后，检查激活状态、监听端点和 WebSocket 握手，不发送真实微信
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-wxauto-runtime-contract.ps1

# 检查 Bridge 是否真的能走 OpenClaw 模型路径，不发送真实微信
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-openclaw-bridge-path.ps1 -Strict

# 查看最近一次微信链路的 trace 时间线
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-aipet-wechat-trace.ps1

# 对最近一次微信链路做验收断言；最终满血验收使用严格模式
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-aipet-wechat-e2e.ps1 -AllowDryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\assert-aipet-wechat-e2e.ps1 -RequireOpenClaw -RequireRealSend -Strict

# 现场等待一条新微信消息并自动验收，适合真实桌面联调
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wait-aipet-wechat-e2e.ps1 -TargetName "爸爸"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wait-aipet-wechat-e2e.ps1 -TargetName "爸爸" -FullE2E -Strict

# 一键启动完整链路并进入现场验收等待
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-aipet-wechat-live-test.ps1 -TargetName "爸爸" -FullE2E -Strict

# 最终满血版验收入口：要求 OpenClaw 模型路径 + 真实微信发送
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair-and-verify-ai-pet-wechat-full.ps1 -TargetName "爸爸"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair-and-verify-ai-pet-wechat-full.ps1 -TargetName "爸爸" -Execute
scripts\repair-and-verify-ai-pet-wechat-full.cmd -TargetName "爸爸" -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName "爸爸" -TemporaryPrivateAuto -RestartStack -PlanOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName "爸爸" -RestartStack
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName "爸爸" -TemporaryPrivateAuto -RestartStack

# 临时开启指定联系人私聊自动回复，跑满血验收，结束后自动恢复原微信策略
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-aipet-wechat-private-full-e2e.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-aipet-wechat-private-full-e2e.ps1 -Strict
```

`-TargetName` 可以是私聊联系人备注名，也可以是家庭群的准确群名。家庭群默认建议使用 `-GroupReplyMode at_me_only`；如果显式使用 `-GroupReplyMode all`，wxauto 通道会把群消息交给 Bridge 决策，Bridge 仍会按家庭群 allowlist、唤醒词、安静时段、频率限制、每日上限和紧急停止来决定是否回复。

启动完整微信通道：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-openclaw-pet-persona.ps1 -PetId cat-home
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-aipet-wxauto-bridge-channel.ps1 -Visible
```

也可以使用总入口：

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preflight-ai-pet-wechat-full.ps1
scripts\start-ai-pet-wechat-full.cmd
scripts\restart-ai-pet-wechat-full.cmd
scripts\repair-and-verify-ai-pet-wechat-full.cmd -TargetName "爸爸"
scripts\repair-and-verify-ai-pet-wechat-full-desktop.cmd
scripts\stop-ai-pet-wechat-full.cmd
```

首次真实账号测试建议：

1. 确认 Windows 微信 PC 已登录宠物微信号，窗口未最小化。
2. 用 `scripts\configure-aipet-wechat-family.ps1` 配置宠物微信昵称、`爸爸` / `妈妈` 私聊白名单，以及家庭群准确群名。
3. 先使用 `-Mode observe` 观察链路；确认生成质量后再切换 `-Mode private-auto`。
4. 群聊保持 `at_me_only`；只有确认家庭群名、宠物微信昵称和 `trace_id` 都正确后，再考虑 `-Mode family-group-auto`。
5. 先检查 `logs\wechat-sidecar.jsonl`、`logs\aipet-bridge.jsonl` 和 `logs\audit-events.jsonl`，确认 `trace_id` 链路正常。

私聊白名单应使用 wxauto 监听目标里能准确打开聊天窗口的名称。实际消息里如果 `sender` 是微信昵称、`sender_remark` 才是备注名，AI Pet Bridge 通道会把两者都作为发送者别名参与白名单和自消息判断；排查“不回复”时优先查看 `logs\wechat-sidecar.jsonl` 中的 `sender_name`、`sender_remark` 和 `block_reason`。

wxautox4 的运行态目录默认是 `.cache\wxautox-home`，用于避免把服务锁、状态文件等写到 C 盘用户目录。需要调整时可在 `.env.local` 设置 `AIPET_WXAUTOX_HOME`。

如果之前已经在默认 C 盘用户目录激活过 wxautox4，切换到 `.cache\wxautox-home` 后仍需要重新运行一次 `scripts\activate-wxautox4.ps1`，让授权状态写入新的 E 盘运行态目录。

如果确认默认 Windows 用户目录下已经激活过，也可以在 `.env.local` 设置 `AIPET_WXAUTOX_HOME=default`，让 wxautox4 使用系统默认授权目录；其他依赖、缓存和项目文件仍保留在当前项目目录。

激活失败时先跑诊断模式，它不会提交激活请求，也不会打印授权码：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1 -Diagnose -CheckOnly
```

也可以使用脚本切换或检查两种授权目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -CheckOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -Mode default
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -Mode project
```

`start-aipet-wxauto-bridge-channel.ps1` 会先检查 Windows 微信桌面进程是否存在，避免在未登录宠物微信号时继续启动真实监听；随后等待 wxauto API 在线，再检查 `/v1/activation/check`。如果 E 盘运行态目录尚未激活，脚本会停止并提示先运行激活命令，不会继续启动监听通道；如果启动过程中激活或 runtime contract 检查失败，会停掉 wxauto API / channel 作为 fail-closed 回退。激活通过后，脚本会运行 `test-wxauto-runtime-contract.ps1` 检查 wxauto API 路由、监听状态和 WebSocket 握手，再启动 AI Pet Bridge 通道。通道运行日志写入 `logs\aipet-wxauto-bridge-channel.log`。

AI Pet Bridge 通道默认使用 `logs\aipet-wxauto-bridge-channel.lock` 做单实例锁；如果误开第二个通道会直接失败，避免同一个真实微信消息被多个监听进程重复回复。进程异常退出留下的 stale lock 会在 PID 不存在时自动清理。

完整启动入口会检查 Bridge 的微信安全策略版本；如果 8787 上仍是旧 Bridge，`setup-ai-pet-wechat-full.ps1` 会先重启 Bridge。直接启动 wxauto 通道时，如果 Bridge 不暴露当前安全策略版本，脚本会 fail-closed，不会继续监听真实微信。

`configure-wxauto-openclaw-channel.ps1` 还会同步给参考 wxauto API 的监听服务写入本地安全补丁：`SAFE_CONTACTS` 只包含当前私聊/群聊目标，`SANDBOX_MODE=true`。因此即使有人误连底层 `/v1/listen/ws`，也不能监听未配置的联系人或群聊。

AI Pet Bridge 通道会同时兼容 wxauto 消息中的 `type` / `msg_type`、`id` / `msg_id` 字段。发送微信消息时，即使 HTTP 状态码为 200，只要 wxauto 返回 `success=false`，也会按发送失败处理并写入 `logs\errors.jsonl`，避免真实账号误以为已经发出。

真实微信自动发送还有一层模型路径闸门：`aipet-wxauto-bridge-channel` 生成的配置默认包含 `require_openclaw_for_send: true`，因此只有 Bridge 返回 `model_source=openclaw` 时才会调用 wxauto 发送；如果 OpenClaw 临时失败并触发 `local_fallback`，通道会记录 `wechat.wxauto.model_path_blocked` 并 fail-closed，不会把兜底回复发到真实微信。dry-run 和控制台预览仍可用于观察兜底效果。

`test-aipet-wxauto-bridge-channel.ps1` 只走 synthetic 消息和 dry-run，不会发送真实微信。它返回 `dry_run` 表示已生成回复但未发送；如果短时间重复运行，返回 `blocked/rate_limited` 也是正常结果，说明 Bridge 频率限制正在生效。

`test-openclaw-bridge-path.ps1 -Strict` 会通过 Bridge 调用一次 OpenClaw 自测，不经过 wxauto，也不会发送微信。满血版真实发送前必须通过这个检查；`start-aipet-wechat-live-test.ps1 -FullE2E` 会在等待你发送真实微信消息前自动运行该自测，避免 OpenClaw 不通时把 `local_fallback` 回复发到真实账号。

`.cmd` 总入口默认带 `-AutoActivate`：wxauto API 启动后如果检测到 E 盘运行态目录尚未激活，会使用 `.env.local` 中保存的授权码调用本地 activation API 激活一次。授权码不会打印到控制台。若自动激活失败，再单独运行 `scripts\activate-wxautox4.ps1` 查看脱敏错误。

满血版验收时，`doctor-ai-pet-wechat-full.ps1 -FullE2E -Strict` 应通过。它会汇总本地环境、Bridge、OpenClaw Gateway、wxauto API、wxautox4 激活、runtime contract 和最近一次真实微信 trace。`show-aipet-wechat-trace.ps1` 里回复生成事件的 `model` 应为 `openclaw`。如果显示 `local_fallback`，说明安全兜底可用，但还不是完整 OpenClaw 模型链路。

如果 doctor 提示 `Bridge WeChat policy version` 为 WARN，说明当前运行中的 Bridge 进程不是最新安全语义，通常是代码更新后没有重启；运行 `scripts\restart-ai-pet-wechat-full.cmd` 后再验收。

如果 `restart` / `repair-and-verify` 提示 Bridge 启动后仍不可用或策略字段缺失，先查看 `logs\aipet-bridge-console.log`。完整启动入口会用无热重载模式启动 Bridge，并在启动后做短暂稳定性复查，避免旧进程残留或后台进程刚启动就退出时继续进入真实微信监听。

如果现场验收失败且输出太长，可以生成一份脱敏诊断包再排查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\export-aipet-wechat-diagnostics.ps1 -TargetName "爸爸"
```

诊断包默认只读状态和日志尾部，不发微信、不启动服务、不调用模型；API key、wxautox4 授权码、Authorization header、wxapi token 和疑似长 token 会被脱敏。`repair-and-verify -Execute` 失败时也会自动生成一份诊断包并打印路径。

真实微信消息发出后，可以运行 `assert-aipet-wechat-e2e.ps1 -RequireOpenClaw -RequireRealSend -Strict` 做最终断言。它会检查最近一次 trace 是否完成 wxauto 检测、Bridge 生成、OpenClaw 模型路径和真实微信发送；如果停在 dry-run、人工审核、频控、OpenClaw 失败或发送失败，会给出明确结论。

如果要做现场联调，先运行 `wait-aipet-wechat-e2e.ps1 -TargetName "爸爸" -FullE2E -Strict`，再从 `爸爸` 的微信发送一条新消息。脚本会只看启动后的新 trace，避免误用旧的 dry-run 日志。

等待脚本看到新 trace 后不会立刻失败；如果此时 Bridge 生成、OpenClaw 调用或 wxauto 发送事件还没写完，它会继续等到成功或超时。超时时会打印最后一次断言详情，能看到停在检测、生成、模型路径、发送还是策略拦截。

`verify-ai-pet-wechat-full.ps1` 严格验收通过后，会额外导出 `logs\aipet-wechat-full-e2e-proof-*.json`。该文件只包含 trace 元数据和布尔检查，不包含完整聊天正文，可作为“OpenClaw 模型路径 + 真实微信发送”已经跑通的留档证据。

`wxauto-openclaw-status.ps1` 会读取最新的 `aipet-wechat-full-e2e-proof-*.json` 并校验其中的 OpenClaw 与真实发送检查项；如果显示 `latest full E2E proof` 为 OK，说明本地已经有一份可复核的满血通过证据。

`audit-ai-pet-wechat-full-readiness.ps1` 输出机器可读 JSON，把状态分成 `ready_for_repair_verify`、`ready_for_full_e2e` 和 `full_e2e_verified` 三层。它不会打印授权码或 API key，适合现场运行后保存输出做排障。

如果传入 `-TargetName`，readiness audit 会检查该名称是否已经出现在 wxauto 私聊/群聊监听配置中；名字不完全匹配时会在 `config.target_name` 检查项中失败。

也可以直接运行 `start-aipet-wechat-live-test.ps1 -TargetName "爸爸" -FullE2E -Strict -RestartStack`，它会启动 Bridge、OpenClaw Gateway、wxauto API 和 AI Pet Bridge 通道，然后进入等待新消息的验收流程。`-TargetName` 可以换成家庭群准确群名。该脚本不会修改白名单或自动回复策略；如果当前仍是 observe/manual review 模式，严格满血验收会正常失败并提示原因。代码更新后建议加 `-RestartStack`，避免复用旧 Bridge 进程。

如果只是想短时间验证“私聊真实发送”，先运行 `start-aipet-wechat-private-full-e2e.ps1 -DryRun` 预览变更，再运行 `start-aipet-wechat-private-full-e2e.ps1 -Strict -RestartStack`。默认使用当前私聊白名单里的第一个联系人；也可以显式传 `-TargetName "妈妈"`。它会先确保 Bridge 可用，再保存当前微信策略，临时把目标联系人加入私聊白名单、开启私聊自动回复、关闭人工审核、关闭紧急停止和安静时段、保持群聊自动回复关闭；验收结束后自动恢复原策略、重新生成 wxauto 配置，并重启 wxauto 运行态以读取恢复后的配置。如果恢复后的 wxauto 重启失败，脚本会停掉 wxauto 通道作为 fail-closed 回退。

上述现场联调和临时实发入口都会校验 Bridge 是否暴露当前微信安全策略版本；如果检测到旧 Bridge，会要求 `-RestartStack` 或自动通过完整 setup 入口重启后再继续。

`repair-and-verify-ai-pet-wechat-full.ps1 -Execute` 适合在登录宠物微信号的 Windows 桌面 PowerShell 中直接运行。它会先清理 stale lock、激活 wxautox4、重启完整栈，再进入满血验收；任一子步骤失败时会自动输出脱敏的 `wxauto-openclaw-status` 和 `doctor` 快照，便于判断是授权、Bridge、OpenClaw Gateway、wxauto API、监听配置还是真实消息 trace 卡住。若只想要原始失败输出，可加 `-SkipFailureDiagnostics`。

如果临时实发验收中断或自动恢复失败，可以运行 `restore-aipet-wechat-settings.ps1` 恢复最近一次快照；也可以用 `-SnapshotPath` 指定脚本输出的快照文件。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-aipet-wechat-settings.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-aipet-wechat-settings.ps1
```

## 常用脚本

- `scripts\run-bridge.ps1`：启动 AI Pet Bridge。
- `scripts\setup-wxauto-openclaw-channel.ps1`：克隆参考微信通道并安装依赖。
- `scripts\configure-aipet-wechat-family.ps1`：配置家庭微信安全边界，并刷新 Bridge 与 wxauto 配置。
- `scripts\emergency-stop-aipet-wechat.ps1`：一键开启紧急停止，关闭私聊/群聊自动回复，可选停止 wxauto 通道进程。
- `scripts\configure-wxauto-openclaw-channel.ps1`：生成 wxauto API 和通道配置。
- `scripts\doctor-ai-pet-wechat-full.ps1`：汇总诊断满血版微信链路，给出 READY / NEEDS ACTION。
- `scripts\audit-ai-pet-wechat-full-readiness.ps1`：输出 JSON 版满血就绪审计，区分可执行修复验收、可跑 full E2E、已完成真实发送证明三个阶段。
- `scripts\test-wxauto-runtime-contract.ps1`：检查 wxauto API、授权状态、监听端点和 WebSocket 握手，不发送真实微信。
- `scripts\test-openclaw-bridge-path.ps1`：检查 Bridge 能否实际走 OpenClaw 模型路径，不发送真实微信。
- `scripts\test-aipet-wxauto-bridge-channel.ps1`：用 synthetic wxauto 消息自检 Bridge 通道，不发送真实微信。
- `scripts\show-aipet-wechat-trace.ps1`：按 `trace_id` 查看检测、策略、生成、发送或拦截全过程。
- `scripts\export-aipet-wechat-diagnostics.ps1`：导出脱敏诊断包，包含状态、doctor 快照、执行计划和关键日志尾部，方便现场验收失败后回传排查。
- `scripts\assert-aipet-wechat-e2e.ps1`：对最近一次微信 trace 做验收断言，严格模式用于满血版最终确认。
- `scripts\wait-aipet-wechat-e2e.ps1`：等待一条新微信消息并自动运行 E2E 断言，适合现场联调。
- `scripts\start-aipet-wechat-live-test.ps1`：启动完整微信链路并进入现场等待验收，不修改安全策略。
- `scripts\start-aipet-wechat-private-full-e2e.ps1`：临时开启单个私聊目标自动回复，完成满血验收后恢复原策略。
- `scripts\verify-ai-pet-wechat-full.ps1`：最终满血版验收总入口，要求 OpenClaw 模型路径和真实微信发送；可选 `-PlanOnly` 预览子命令，可选临时开启单个私聊目标自动回复并自动恢复。
- `scripts\repair-and-verify-ai-pet-wechat-full.ps1`：桌面一键修复与验收入口；默认只输出执行计划，传 `-Execute` 后依次清理 stale lock、激活 wxautox4、重启完整栈并进入满血验收，失败时自动输出脱敏诊断快照。
- `scripts\repair-and-verify-ai-pet-wechat-full.cmd`：上述修复与验收入口的非交互 cmd 包装，适合命令行和 CI，退出码会直接传回调用方。
- `scripts\repair-and-verify-ai-pet-wechat-full-desktop.cmd`：桌面双击入口；不传参数时默认执行修复与验收并在结束时暂停，方便查看扫码、启动和验收结果。需要指定联系人时可传 `-TargetName "爸爸" -Execute`。
- `scripts\restore-aipet-wechat-settings.ps1`：从临时验收前的快照恢复 Bridge 微信策略，并刷新 wxauto 配置。
- `scripts\start-aipet-wxauto-bridge-channel.ps1`：启动 wxauto API 和 AI Pet Bridge 通道。
- `scripts\restart-ai-pet-wechat-full.cmd`：停止并重启 Bridge、OpenClaw Gateway、wxauto API 和 Bridge 通道，适合代码更新后的实机验收。
- `scripts\start-wxauto-openclaw-channel.ps1`：启动参考项目的直连 OpenClaw 通道，主要用于对照调研。
- `scripts\wxauto-openclaw-status.ps1`：轻量排障入口，检查 Bridge 策略版本、wxautox4 激活、wxauto API、OpenClaw Gateway、配置 sandbox、runtime contract 和最近 trace，最后输出 READY / NEEDS ACTION 以及建议命令。
- `scripts\preflight-ai-pet-wechat-full.ps1`：完整微信链路预检。

## 目录结构

```text
src/aipet_bridge                 Bridge API、人格、策略、日志和本地控制台
src/aipet_wxauto_bridge_channel  wxauto 到 AI Pet Bridge 的微信通道
src/aipet_wechat_sidecar         Windows 微信 sidecar 早期实验通道
scripts                          本地开发、OpenClaw、微信和飞书辅助脚本
tests                            单元测试
.data                            本地 SQLite 数据，已被 Git 忽略
logs                             本地 JSONL 日志，已被 Git 忽略
```

## 文档约定

- README 只保留项目介绍、当前能力和稳定入口。
- 阶段性调研、排障过程和技术演进记录放在 `TECHNICAL_EVOLUTION.local.md`，该文件不提交到 Git。
- 新能力稳定后再同步更新 README。
