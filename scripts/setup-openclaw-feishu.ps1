param(
  [switch]$InstallPlugin,
  [switch]$ForcePlugin,
  [string]$AgentId = "main",
  [string]$Model = "deepseek/deepseek-v4-flash",
  [string]$WorkspacePath = "",
  [string[]]$GroupAllowFrom = @(),
  [string[]]$AllowFrom = @()
)

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd
$ProjectRoot = $OpenClawEnv.ProjectRoot

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
  $WorkspacePath = Join-Path $ProjectRoot ".openclaw\workspace-ai-pet-feishu"
}

New-Item -ItemType Directory -Force -Path $WorkspacePath | Out-Null

if ($InstallPlugin) {
  $installArgs = @("plugins", "install", "@openclaw/feishu")
  if ($ForcePlugin) {
    $installArgs += "--force"
  }
  & $OpenClawCmd @installArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install @openclaw/feishu."
  }
}

& $OpenClawCmd config set plugins.entries.feishu.enabled true --strict-json
if ($LASTEXITCODE -ne 0) {
  throw "Failed to enable Feishu plugin."
}

$configureArgs = @("-File", (Join-Path $PSScriptRoot "configure-openclaw-feishu-family-chat.ps1"))
if ($GroupAllowFrom.Count -gt 0) {
  $configureArgs += "-GroupAllowFrom"
  $configureArgs += $GroupAllowFrom
}
if ($AllowFrom.Count -gt 0) {
  $configureArgs += "-AllowFrom"
  $configureArgs += $AllowFrom
}
powershell -NoProfile -ExecutionPolicy Bypass @configureArgs
if ($LASTEXITCODE -ne 0) {
  throw "Failed to apply Feishu family chat config."
}

$agents = & $OpenClawCmd agents list --json | ConvertFrom-Json
$agent = @($agents | Where-Object { $_.id -eq $AgentId })[0]

if ($null -eq $agent) {
  & $OpenClawCmd agents add $AgentId --workspace $WorkspacePath --model $Model --bind feishu --non-interactive
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to add OpenClaw agent '$AgentId'."
  }
} else {
  & $OpenClawCmd agents bind --agent $AgentId --bind feishu
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to bind OpenClaw agent '$AgentId' to Feishu."
  }
}

Write-Host "OpenClaw Feishu channel is configured."
Write-Host "Agent: $AgentId"
Write-Host "Workspace: $WorkspacePath"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Login Feishu: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\login-openclaw-feishu.ps1"
Write-Host "  2. Restart the gateway: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1"
Write-Host "  3. Add the bot to the family Feishu group and allowlist the group chat_id."
