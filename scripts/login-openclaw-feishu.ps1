param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

Write-Host "OpenClaw Feishu login/setup will start in this terminal."
Write-Host "Choose manual setup if QR setup does not work."
Write-Host "Use a self-built Feishu app with bot enabled, WebSocket event subscription, and im.message.receive_v1."
Write-Host ""

& $OpenClawCmd channels login --channel feishu
