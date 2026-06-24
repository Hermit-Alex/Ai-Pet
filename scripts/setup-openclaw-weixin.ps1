param(
  [switch]$InstallPlugin,
  [switch]$ForcePlugin,
  [string]$AgentId = "main",
  [string]$Model = "deepseek/deepseek-v4-flash",
  [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd
$ProjectRoot = $OpenClawEnv.ProjectRoot

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
  $WorkspacePath = Join-Path $ProjectRoot ".openclaw\workspace-ai-pet-wechat"
}

New-Item -ItemType Directory -Force -Path $WorkspacePath | Out-Null

if ($InstallPlugin) {
  $installArgs = @("plugins", "install", "@tencent-weixin/openclaw-weixin")
  if ($ForcePlugin) {
    $installArgs += "--force"
  }
  & $OpenClawCmd @installArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install @tencent-weixin/openclaw-weixin."
  }
}

& $OpenClawCmd config set plugins.entries.openclaw-weixin.enabled true --strict-json
if ($LASTEXITCODE -ne 0) {
  throw "Failed to enable openclaw-weixin plugin."
}

& $OpenClawCmd config set session.dmScope per-account-channel-peer
if ($LASTEXITCODE -ne 0) {
  throw "Failed to set session.dmScope."
}

& $OpenClawCmd config set channels.openclaw-weixin.dmPolicy pairing
if ($LASTEXITCODE -ne 0) {
  throw "Failed to set openclaw-weixin dmPolicy."
}

$agents = & $OpenClawCmd agents list --json | ConvertFrom-Json
$agent = @($agents | Where-Object { $_.id -eq $AgentId })[0]

if ($null -eq $agent) {
  & $OpenClawCmd agents add $AgentId --workspace $WorkspacePath --model $Model --bind openclaw-weixin --non-interactive
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to add OpenClaw agent '$AgentId'."
  }
} else {
  & $OpenClawCmd agents bind --agent $AgentId --bind openclaw-weixin
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to bind OpenClaw agent '$AgentId' to openclaw-weixin."
  }
}

Write-Host "OpenClaw Weixin plugin is enabled."
Write-Host "Agent: $AgentId"
Write-Host "Workspace: $WorkspacePath"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Restart the gateway: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1"
Write-Host "  2. Login Weixin: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\login-openclaw-weixin.ps1"
Write-Host "  3. Ask each family contact to send a DM, then approve with openclaw-weixin pairing."
