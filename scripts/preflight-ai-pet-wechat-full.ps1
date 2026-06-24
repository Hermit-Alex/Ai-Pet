param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home"
)

$ErrorActionPreference = "Continue"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")

function Write-Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = "")
  $status = if ($Ok) { "OK" } else { "WARN" }
  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host "[$status] $Name"
  } else {
    Write-Host "[$status] $Name - $Detail"
  }
}

Write-Host "== AI Pet WeChat Full Preflight =="

Write-Host ""
Write-Host "== Local files =="
Write-Check "project venv" (Test-Path -LiteralPath $WxautoEnv.VenvPython) $WxautoEnv.VenvPython
Write-Check "wxauto source" (Test-Path -LiteralPath $WxautoEnv.ChannelRoot) $WxautoEnv.ChannelRoot
Write-Check "wxautox4 cli" (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe) $WxautoEnv.Wxautox4Exe
Write-Check "wxautox home" (Test-Path -LiteralPath $WxautoEnv.WxautoxHome) "$($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)"
Write-Check "local license configured" (-not [string]::IsNullOrWhiteSpace($WxautoEnv.LicenseKey)) ".env.local"

Write-Host ""
Write-Host "== Python packages =="
try {
  $importOutput = @"
import wxautox4
import fastapi
import websockets
import yaml
import aipet_wxauto_bridge_channel
print("imports_ok")
"@ | & $WxautoEnv.VenvPython -
  Write-Check "required imports" ($importOutput -match "imports_ok")
} catch {
  Write-Check "required imports" $false $_.Exception.Message
}

Write-Host ""
Write-Host "== Bridge =="
try {
  $health = Invoke-RestMethod -Uri "$($BridgeUrl.TrimEnd('/'))/health" -TimeoutSec 5
  Write-Check "Bridge health" ($health.status -eq "ok") "$BridgeUrl"
  Write-Check "Bridge WeChat policy version" ([bool]$health.wechat_private_manual_review_enforced) "private manual review enforced=$($health.wechat_private_manual_review_enforced)"
  Write-Check "Bridge OpenClaw configured" ([bool]$health.openclaw_configured) "full mode needs Bridge -> OpenClaw"
} catch {
  Write-Check "Bridge health" $false "not reachable at $BridgeUrl"
  Write-Check "Bridge WeChat policy version" $false "Bridge not reachable"
  Write-Check "Bridge OpenClaw configured" $false "Bridge not reachable"
}

try {
  $settings = Invoke-RestMethod -Uri "$($BridgeUrl.TrimEnd('/'))/pets/$PetId/wechat/settings" -TimeoutSec 5
  $privateCount = @($settings.settings.private_contact_allowlist).Count
  $groupCount = @($settings.settings.family_groups).Count
  Write-Check "Bridge WeChat settings" ($privateCount -gt 0 -or $groupCount -gt 0) "private=$privateCount group=$groupCount"
} catch {
  Write-Check "Bridge WeChat settings" $false "not reachable"
}

Write-Host ""
Write-Host "== wxauto config =="
try {
  $configOutput = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-wxauto-openclaw-config.ps1")
  $configOutputText = $configOutput -join " "
  $ok = $configOutputText -match "wxauto_config_ok"
  Write-Check "wxauto config parser" $ok ($configOutputText -replace "\s+", " ")
} catch {
  Write-Check "wxauto config parser" $false $_.Exception.Message
}

$channelConfigPath = Join-Path $WxautoEnv.WxChannelRoot "config.yaml"
if (Test-Path -LiteralPath $channelConfigPath) {
  $channelConfigText = Get-Content -LiteralPath $channelConfigPath -Raw
  Write-Check "AI Pet Bridge section in wxauto config" ($channelConfigText -match "(?m)^aipet_bridge:\s*$")
  Write-Check "OpenClaw token in wxauto config" ($channelConfigText -notmatch "token:\s*''" -and $channelConfigText -notmatch "your_openclaw_token_here")
}

Write-Host ""
Write-Host "== wxautox4 activation =="
if (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe) {
  New-Item -ItemType Directory -Force -Path $WxautoEnv.WxautoxHome | Out-Null
  $env:USERPROFILE = $WxautoEnv.WxautoxHome
  $env:HOME = $WxautoEnv.WxautoxHome
  $activationOutput = (& $WxautoEnv.Wxautox4Exe -k 2>&1 | Out-String)
  $activated = $activationOutput -match "已激活|activated|True"
  Write-Check "wxautox4 activation" $activated "if this warns inside Codex, re-run in desktop PowerShell"
} else {
  Write-Check "wxautox4 activation" $false "wxautox4 cli missing"
}

Write-Host ""
Write-Host "== Desktop WeChat =="
$weixin = @(Get-Process Weixin -ErrorAction SilentlyContinue)
Write-Check "Weixin.exe process" ($weixin.Count -gt 0) "count=$($weixin.Count)"

Write-Host ""
Write-Host "Preflight finished."
