param(
  [string[]]$GroupAllowFrom = @(),
  [string[]]$AllowFrom = @(),
  [switch]$OpenGroups,
  [switch]$DisableDms,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

$feishuConfig = [ordered]@{
  enabled = $true
  domain = "feishu"
  connectionMode = "websocket"
  dmPolicy = if ($DisableDms) { "disabled" } else { "pairing" }
  groupPolicy = if ($OpenGroups) { "open" } else { "allowlist" }
  requireMention = $true
  streaming = $false
  blockStreaming = $false
  typingIndicator = $false
  resolveSenderNames = $true
  textChunkLimit = 1200
  mediaMaxMb = 5
  tools = [ordered]@{
    bitable = $false
    base = $false
  }
  dynamicAgentCreation = [ordered]@{
    enabled = $false
  }
}

if ($GroupAllowFrom.Count -gt 0) {
  $feishuConfig.groupAllowFrom = @($GroupAllowFrom)
}

if ($AllowFrom.Count -gt 0) {
  $feishuConfig.allowFrom = @($AllowFrom)
}

$patch = [ordered]@{
  session = [ordered]@{
    dmScope = "per-account-channel-peer"
  }
  channels = [ordered]@{
    feishu = $feishuConfig
  }
  tools = [ordered]@{
    profile = "minimal"
    deny = @(
      "group:fs",
      "group:runtime",
      "group:web",
      "group:ui",
      "group:automation",
      "group:messaging",
      "group:nodes",
      "group:agents",
      "group:media",
      "group:plugins",
      "group:sessions"
    )
    elevated = [ordered]@{
      enabled = $false
    }
  }
}

$patchArgs = @("config", "patch", "--stdin")
if ($DryRun) {
  $patchArgs += "--dry-run"
}

$patchJson = $patch | ConvertTo-Json -Depth 20
$patchJson | & $OpenClawCmd @patchArgs
if ($LASTEXITCODE -ne 0) {
  throw "Failed to apply OpenClaw Feishu family chat safety config."
}

if (-not $DryRun) {
  & $OpenClawCmd config validate
  if ($LASTEXITCODE -ne 0) {
    throw "OpenClaw config validation failed."
  }
}

if ($DryRun) {
  Write-Host "OpenClaw Feishu family chat safety config dry run completed."
  Write-Host "No config was written."
} else {
  Write-Host "OpenClaw Feishu family chat safety config applied."
  Write-Host ""
  Write-Host "Effective Feishu config:"
  & $OpenClawCmd config get channels.feishu --json
  Write-Host ""
  Write-Host "Effective tools config:"
  & $OpenClawCmd config get tools --json
  Write-Host ""
  Write-Host "Restart the OpenClaw Gateway for channel/tool-policy changes to take effect."
}
