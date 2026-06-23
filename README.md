# AI Pet

AI Pet（AI 宠）是一个面向家庭宠物的本地优先 Agent 项目。它希望让宠物不只是被记录的对象，而是能以安全、低频、拟人化的方式参与家庭聊天、健康提醒、日常记忆和智能设备联动。

当前项目以“家庭宠物聊天 MVP”为主线：本地 Bridge 负责宠物档案、人格、记忆、策略和日志；OpenClaw 负责模型与聊天通道；飞书机器人作为优先输出端；微信相关能力保留为实验通道。

## 项目目标

- 为猫、狗等家庭宠物建立可持续维护的 AI 人格。
- 用问卷、家庭记忆、健康事件和实时状态生成稳定的宠物人设。
- 让宠物 Agent 能在家庭聊天场景里自然互动。
- 保持真实账号、家庭隐私和自动化行为边界可控。
- 后续沉淀成可复用的 AI 宠物家庭部署方案。

## 当前能力

- 本地 Bridge API：`http://127.0.0.1:8787`
- 本地控制台：`http://127.0.0.1:8787/ui`
- 宠物档案、事件、记忆和人格数据的 SQLite 存储
- 猫咪人格问卷评分，生成 `persona_profile` 和 `system_prompt`
- 私聊 allowlist、安静时段、频率限制、每日上限和紧急停止
- JSONL 审计日志，支持按 `trace_id` 串起一次回复链路
- OpenClaw Gateway / DeepSeek 接入
- OpenClaw Feishu channel 配置脚本
- OpenClaw Weixin 和 Windows 微信 sidecar 实验能力

## 架构概览

```text
家庭成员
  │
  │ 飞书群聊 / bot 私聊
  ▼
OpenClaw Feishu Channel
  │
  ▼
OpenClaw Gateway ── DeepSeek / OpenAI-compatible Model
  │
  ▼
AI Pet Bridge
  ├─ 宠物档案
  ├─ 人格问卷与 system prompt
  ├─ 记忆与家庭事件
  ├─ 行为控制策略
  ├─ 频率限制与安全拦截
  └─ JSONL 日志审计
```

微信相关能力目前只作为实验和回归路线保留，不作为正式家庭输出端。

## 安全原则

- 默认本地运行，不暴露公网服务。
- 默认只处理 allowlist 家庭成员或家庭群。
- 群聊要求明确唤醒或 `@宠物 bot`。
- 自动回复低频、短句、温和，不争吵、不刷屏。
- 不主动添加好友，不主动私聊陌生人，不做群扩散。
- 不泄露家庭隐私、账号密钥、设备画面、住址、行程等信息。
- OpenClaw 工具权限默认收紧，聊天 Agent 不应操作本机文件、命令、浏览器或插件工具。

## 快速开始

在 Windows PowerShell 中执行：

```powershell
cd "E:\code\AI\Ai Pet"
powershell -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install
Copy-Item .env.example .env.local
.\.venv\Scripts\python.exe -m aipet_bridge.cli init-db
.\.venv\Scripts\python.exe -m aipet_bridge.cli seed-demo
powershell -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1
```

打开：

- 控制台：`http://127.0.0.1:8787/ui`
- API 文档：`http://127.0.0.1:8787/docs`
- 健康检查：`http://127.0.0.1:8787/health`

运行测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

## OpenClaw 与飞书

OpenClaw 用于承接模型和聊天通道。当前推荐飞书作为正式家庭聊天端，微信保留为实验通道。

常用脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-openclaw-feishu.ps1 -InstallPlugin
powershell -ExecutionPolicy Bypass -File .\scripts\login-openclaw-feishu.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\openclaw-feishu-status.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\sync-openclaw-pet-persona.ps1 -PetId cat-home
```

飞书接入需要自建飞书应用、启用机器人、配置事件订阅和必要权限。真实家庭使用前，建议先在小范围测试群里观察回复风格和频率。

## 目录结构

```text
src/aipet_bridge          Bridge API、人格、策略、日志和本地控制台
src/aipet_wechat_sidecar  Windows 微信 sidecar 实验通道
scripts                   本地开发、OpenClaw、飞书和微信辅助脚本
tests                     单元测试
.data                     本地 SQLite 数据，已被 Git 忽略
logs                      本地 JSONL 日志，已被 Git 忽略
```

## 文档

- [01_AI宠_可行性研究与家庭部署方案.md](./01_AI宠_可行性研究与家庭部署方案.md)：项目早期可行性研究和家庭部署方案。
- `TECHNICAL_EVOLUTION.local.md`：本地技术演进记录，不纳入 Git，用于保存阶段性部署细节、调研过程和实验路线。

README 只作为项目介绍和当前入口文档。后续新增稳定能力时，再同步更新本文件；阶段性尝试、排障记录和临时技术决策放入本地技术演进文档。

## Roadmap

- 飞书人格问卷承接：用飞书多维表格表单视图收集宠物人格问卷。
- Bridge 原生 Feishu Adapter：让飞书消息完整经过 Bridge 的 RAG、频控、状态注入和审计链路。
- 家庭记忆系统：沉淀驱虫、洗澡、疫苗、就医、外出和偏好等长期记忆。
- 宠物状态接入：连接喂食器、摄像头、安防设备和猫叫声识别服务。
- 轻量化部署：支持 Mac Mini M4、树莓派或其他家庭边缘设备运行核心服务。
