# AI Pet

AI Pet（AI 宠）是一个面向家庭宠物的本地优先 AI Agent 项目。它的目标不是做一个普通聊天机器人，而是让家里的猫、狗拥有可维护的人格、记忆和状态表达，能以“宠物家庭成员”的身份参与家庭互动。

当前项目主线是：让真实宠物微信号在受控范围内和家庭成员私聊互动。微信只作为消息入口和出口；人格、记忆、频率控制、安全策略、日志审计和模型调用都由 AI Pet Bridge 统一处理。

## 当前功能

- 宠物档案：维护宠物名字、昵称、品种、年龄、健康备注等基础信息。
- 宠物人格：支持猫咪人格问卷生成 `persona_profile` 和 `system_prompt`，当前内置 CoCo / 猫仔的人格预设。
- 家庭记忆：记录驱虫、疫苗、洗澡、体检、喂食异常、外出等长期事件。
- 本地控制台：通过 `http://127.0.0.1:8787/ui` 管理宠物档案、人格、微信白名单、安全开关和日志。
- 微信私聊自动回复：真实宠物微信号可回复白名单联系人，目前配置为 `爸爸`、`妈妈`。
- 连续消息合并：家人连续发多条消息时，系统会短暂等待并合并理解后回复一次。
- 频控等待区：触发频率限制的消息不会直接丢弃，会进入等待区，冷却结束后集中回复。
- OpenClaw / DeepSeek 接入：回复由 OpenClaw Gateway 调用 DeepSeek 等 OpenAI-compatible 模型生成。
- 日志审计：使用 `trace_id` 串起消息检测、策略判断、模型生成和微信发送结果。

## 当前边界

- 当前稳定目标是微信私聊，不把微信群聊作为主功能。
- 只处理配置过的家庭联系人，不处理陌生人、不自动加好友、不主动拉群。
- 真实微信号发送前必须经过白名单、安静时段、频率限制、紧急停止和模型路径检查。
- OpenClaw 失败时不会把本地兜底回复发到真实微信号，默认 fail-closed。
- 聊天 Agent 不允许操作电脑文件、命令、浏览器或本机插件工具。
- 不泄露家庭住址、作息、账号密钥、摄像头内容、设备状态和健康记录等隐私。

## 本地服务

默认本机地址：

- Bridge API：`http://127.0.0.1:8787`
- 控制台：`http://127.0.0.1:8787/ui`
- API 文档：`http://127.0.0.1:8787/docs`
- OpenClaw Gateway：`http://127.0.0.1:18789`
- wxauto API：`http://127.0.0.1:8001`

## 快速启动

首次准备：

```powershell
cd "E:\code\AI\Ai Pet"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install
Copy-Item .env.example .env.local
```

在 `.env.local` 中配置 DeepSeek / OpenClaw / wxautox4 等本地密钥后，初始化数据：

```powershell
.\.venv\Scripts\python.exe -m aipet_bridge.cli init-db
.\.venv\Scripts\python.exe -m aipet_bridge.cli seed-demo
```

启动或重启完整微信链路：

```cmd
scripts\restart-ai-pet-wechat-full.cmd
```

停止完整微信链路：

```cmd
scripts\stop-ai-pet-wechat-full.cmd
```

## 测试

运行全量测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

检查当前微信链路状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wxauto-openclaw-status.ps1
```

检查 Bridge 是否能正常调用 OpenClaw：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-openclaw-bridge-path.ps1 -Strict
```

## 项目结构

```text
src/aipet_bridge                 Bridge API、人格、记忆、安全策略、控制台和日志
src/aipet_wxauto_bridge_channel  微信 wxauto 到 AI Pet Bridge 的受控通道
scripts                          本地启动、配置、诊断和验收脚本
tests                            自动化测试
.data                            本地 SQLite 数据，已忽略
logs                             本地运行日志，已忽略
```

## 文档约定

README 只保留项目介绍、当前功能和稳定入口。调研过程、排障记录、阶段性技术演进放在 `TECHNICAL_EVOLUTION.local.md`，该文件仅保留在本地，不提交到 Git。
