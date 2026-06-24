param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [string]$OpenClawGatewayUrl = "http://127.0.0.1:18789",
  [string]$TargetName = "",
  [switch]$SkipSelfTest,
  [switch]$RunRuntimeContract,
  [switch]$RunE2E,
  [switch]$FullE2E,
  [switch]$Strict
)

$ErrorActionPreference = "Continue"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot

$script:WarnCount = 0
$script:FailCount = 0

function Write-DoctorCheck {
  param(
    [ValidateSet("OK", "WARN", "FAIL")]
    [string]$State,
    [string]$Name,
    [string]$Detail = "",
    [string]$Action = ""
  )

  if ($State -eq "WARN") {
    $script:WarnCount += 1
  }
  if ($State -eq "FAIL") {
    $script:FailCount += 1
  }

  $line = "[$State] $Name"
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $line += " - $Detail"
  }
  Write-Host $line
  if ($State -ne "OK" -and -not [string]::IsNullOrWhiteSpace($Action)) {
    Write-Host "      next: $Action"
  }
}

function Test-HttpOk {
  param([string]$Url)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
  } catch {
    return $false
  }
}

function Get-BridgeHealth {
  param([string]$Url)
  try {
    return Invoke-RestMethod -Method Get -Uri "$($Url.TrimEnd('/'))/health" -TimeoutSec 5
  } catch {
    return $null
  }
}

function Invoke-JsonProbe {
  param([string]$PythonCode)
  try {
    $env:PYTHONPATH = Join-Path $ProjectRoot "src"
    $output = $PythonCode | & $WxautoEnv.VenvPython -
    $jsonLine = ($output | Where-Object { [string]$_ -match "^\{" } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
      return $null
    }
    return $jsonLine | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-ActivationOutput {
  param([string]$Text)

  $notActivatedText = [string]([char]0x672A) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $activatedText = [string]([char]0x5DF2) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $negative = (
    $Text.Contains($notActivatedText) -or
    $Text -match "(?i)\bnot[_\s-]?activated\b"
  )
  $positive = (
    $Text.Contains($activatedText) -or
    $Text -match "\bTrue\b" -or
    $Text -match "(?i)\bactivated\b"
  )
  return (-not $negative) -and $positive
}

function Test-WxautoxActivated {
  param([ValidateSet("current", "project", "default")] [string]$HomeMode = "current")
  try {
    $output = powershell -NoProfile -ExecutionPolicy Bypass -File `
      (Join-Path $PSScriptRoot "activate-wxautox4.ps1") `
      -CheckOnly `
      -HomeMode $HomeMode
    $text = $output -join " "
    return (Test-ActivationOutput -Text $text)
  } catch {
    return $false
  }
}

function Test-PidActive {
  param([int]$ProcessId)
  if ($ProcessId -le 0) {
    return $false
  }
  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-WxautoChannelLockStatus {
  $lockPath = $WxautoEnv.WxautoBridgeChannelLockPath
  if (-not (Test-Path -LiteralPath $lockPath)) {
    return [pscustomobject]@{
      Ok = $true
      Detail = "not present"
      Action = ""
    }
  }

  try {
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockPid = [int]$lock.pid
    $startedAt = [string]$lock.started_at
  } catch {
    return [pscustomobject]@{
      Ok = $false
      Detail = "unreadable lock: $lockPath"
      Action = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-wxauto-openclaw-channel.ps1 -OnlyClearStaleLock"
    }
  }

  if (Test-PidActive -ProcessId $lockPid) {
    return [pscustomobject]@{
      Ok = $true
      Detail = "active pid=$lockPid started_at=$startedAt"
      Action = ""
    }
  }

  return [pscustomobject]@{
    Ok = $false
    Detail = "stale pid=$lockPid path=$lockPath"
    Action = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-wxauto-openclaw-channel.ps1 -OnlyClearStaleLock"
  }
}

function Invoke-DoctorScript {
  param(
    [string]$ScriptName,
    [string[]]$Arguments
  )
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $output = powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{
    ExitCode = $exitCode
    Text = (($output | ForEach-Object { [string]$_ }) -join " ") -replace "\s+", " "
  }
}

Write-Host "== AI Pet WeChat Full Doctor =="
Write-Host "Project: $ProjectRoot"
Write-Host ""

Write-Host "== Local Runtime =="
Write-DoctorCheck -State ($(if (Test-Path -LiteralPath $WxautoEnv.VenvPython) { "OK" } else { "FAIL" })) `
  -Name "Python venv" `
  -Detail $WxautoEnv.VenvPython `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install"
Write-DoctorCheck -State ($(if (Test-Path -LiteralPath $WxautoEnv.ChannelRoot) { "OK" } else { "FAIL" })) `
  -Name "wxauto channel source" `
  -Detail $WxautoEnv.ChannelRoot `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-wxauto-openclaw-channel.ps1 -InstallDeps"
Write-DoctorCheck -State ($(if (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe) { "OK" } else { "FAIL" })) `
  -Name "wxautox4 CLI" `
  -Detail $WxautoEnv.Wxautox4Exe `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-wxauto-openclaw-channel.ps1 -InstallDeps"
Write-DoctorCheck -State ($(if (Test-Path -LiteralPath $WxautoEnv.WxautoxHome) { "OK" } else { "WARN" })) `
  -Name "wxautox home" `
  -Detail "$($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)" `
  -Action "scripts will create this directory automatically"
Write-DoctorCheck -State ($(if (-not [string]::IsNullOrWhiteSpace($WxautoEnv.LicenseKey)) { "OK" } else { "FAIL" })) `
  -Name "wxautox4 license configured" `
  -Detail ".env.local / process env" `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\save-wxautox4-license.ps1 -LicenseKey <your-code>"

Write-Host ""
Write-Host "== Configuration =="
$configSummary = Invoke-JsonProbe @"
import json
from aipet_wxauto_bridge_channel.channel import ChannelConfig
config = ChannelConfig.from_yaml(r"$($WxautoEnv.WxChannelRoot)\config.yaml", bridge_url=r"$BridgeUrl", pet_id=r"$PetId")
print(json.dumps({
    "my_nickname": config.my_nickname,
    "private_count": len([chat for chat in config.private_chats if chat.enabled]),
    "group_count": len([chat for chat in config.group_chats if chat.enabled]),
    "targets": list(config.target_names),
    "bridge_url": config.bridge_url,
    "pet_id": config.pet_id,
}, ensure_ascii=False))
"@
if ($null -eq $configSummary) {
  Write-DoctorCheck -State "FAIL" -Name "wxauto channel config" -Detail "not parseable" -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-wxauto-openclaw-channel.ps1 -FromBridge"
} else {
  $targetCount = [int]$configSummary.private_count + [int]$configSummary.group_count
  $state = if ($targetCount -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$configSummary.my_nickname)) { "OK" } else { "WARN" }
  Write-DoctorCheck -State $state -Name "wxauto channel config" -Detail "private=$($configSummary.private_count) group=$($configSummary.group_count) pet=$($configSummary.pet_id)"
}

try {
  $configOutput = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-wxauto-openclaw-config.ps1")
  $ok = (($configOutput -join " ") -match "wxauto_config_ok")
  Write-DoctorCheck -State ($(if ($ok) { "OK" } else { "FAIL" })) -Name "reference config parser" -Detail (($configOutput -join " ") -replace "\s+", " ")
} catch {
  Write-DoctorCheck -State "FAIL" -Name "reference config parser" -Detail $_.Exception.Message
}

Write-Host ""
Write-Host "== Services =="
$bridgeHealth = Get-BridgeHealth -Url $BridgeUrl
Write-DoctorCheck -State ($(if ($bridgeHealth -and $bridgeHealth.status -eq "ok") { "OK" } else { "FAIL" })) `
  -Name "AI Pet Bridge" `
  -Detail $BridgeUrl `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1"
Write-DoctorCheck -State ($(if ($bridgeHealth -and [bool]$bridgeHealth.openclaw_configured) { "OK" } else { "WARN" })) `
  -Name "Bridge OpenClaw configured" `
  -Detail "full mode uses Bridge -> OpenClaw Gateway" `
  -Action "set AIPET_OPENCLAW_BASE_URL and restart scripts\run-bridge.ps1"
Write-DoctorCheck -State ($(if ($bridgeHealth -and [bool]$bridgeHealth.wechat_private_manual_review_enforced) { "OK" } else { "WARN" })) `
  -Name "Bridge WeChat policy version" `
  -Detail "private manual review enforced=$($bridgeHealth.wechat_private_manual_review_enforced)" `
  -Action "scripts\restart-ai-pet-wechat-full.cmd"
Write-DoctorCheck -State ($(if (Test-HttpOk "$($OpenClawGatewayUrl.TrimEnd('/'))/health") { "OK" } else { "WARN" })) `
  -Name "OpenClaw Gateway" `
  -Detail $OpenClawGatewayUrl `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1"
$wxApiOnline = Test-HttpOk "$($WxApiBaseUrl.TrimEnd('/'))/"
Write-DoctorCheck -State ($(if ($wxApiOnline) { "OK" } else { "WARN" })) `
  -Name "wxauto API" `
  -Detail $WxApiBaseUrl `
  -Action "scripts\start-ai-pet-wechat-full.cmd"
$wxActivationEndpointOnline = Test-HttpOk "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check"
Write-DoctorCheck -State ($(if ($wxActivationEndpointOnline) { "OK" } else { "WARN" })) `
  -Name "wxauto activation endpoint" `
  -Detail "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check" `
  -Action "scripts\start-ai-pet-wechat-full.cmd"

Write-Host ""
Write-Host "== Channel Lock =="
$lockStatus = Get-WxautoChannelLockStatus
Write-DoctorCheck -State ($(if ($lockStatus.Ok) { "OK" } else { "WARN" })) `
  -Name "wxauto Bridge channel single-instance lock" `
  -Detail $lockStatus.Detail `
  -Action $lockStatus.Action

Write-Host ""
Write-Host "== Runtime Contract =="
if ($wxApiOnline -or $RunRuntimeContract) {
  $runtimeArgs = @(
    "-WxApiBaseUrl",
    $WxApiBaseUrl,
    "-Strict"
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $runtimeArgs += @("-TargetName", $TargetName)
  }
  $runtime = Invoke-DoctorScript -ScriptName "test-wxauto-runtime-contract.ps1" -Arguments $runtimeArgs
  Write-DoctorCheck -State ($(if ($runtime.ExitCode -eq 0) { "OK" } else { "FAIL" })) `
    -Name "wxauto runtime contract" `
    -Detail $runtime.Text `
    -Action "scripts\start-ai-pet-wechat-full.cmd"
} else {
  Write-DoctorCheck -State "WARN" `
    -Name "wxauto runtime contract" `
    -Detail "skipped because wxauto API is offline" `
    -Action "scripts\start-ai-pet-wechat-full.cmd"
}

Write-Host ""
Write-Host "== WeChat Desktop =="
$weixin = @(Get-Process Weixin, WeChat -ErrorAction SilentlyContinue)
Write-DoctorCheck -State ($(if ($weixin.Count -gt 0) { "OK" } else { "WARN" })) `
  -Name "Windows WeChat desktop process" `
  -Detail "count=$($weixin.Count)" `
  -Action "open and log in the real pet WeChat account in Windows WeChat"

Write-Host ""
Write-Host "== Activation =="
$activated = Test-WxautoxActivated -HomeMode "current"
Write-DoctorCheck -State ($(if ($activated) { "OK" } else { "FAIL" })) `
  -Name "wxautox4 activation under E: runtime home" `
  -Detail $WxautoEnv.WxautoxHome `
  -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1"
if (-not $activated -and $WxautoEnv.WxautoxHomeMode -ne "default") {
  $defaultActivated = Test-WxautoxActivated -HomeMode "default"
  $defaultAction = if ($defaultActivated) {
    "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -Mode default"
  } else {
    "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -CheckOnly"
  }
  Write-DoctorCheck -State ($(if ($defaultActivated) { "OK" } else { "WARN" })) `
    -Name "wxautox4 activation under default Windows user home" `
    -Detail "mode=default" `
    -Action $defaultAction
}

Write-Host ""
Write-Host "== AI Pet Channel Self-Test =="
if ($SkipSelfTest) {
  Write-DoctorCheck -State "WARN" -Name "synthetic wxauto Bridge channel self-test" -Detail "skipped"
} else {
  try {
    $selfTest = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-aipet-wxauto-bridge-channel.ps1") -BridgeUrl $BridgeUrl -PetId $PetId
    $selfTestText = $selfTest -join " "
    $selfTestOk = $selfTestText -match "action:\s+(dry_run|blocked|manual_review|auto_disabled)"
    Write-DoctorCheck -State ($(if ($selfTestOk) { "OK" } else { "FAIL" })) `
      -Name "synthetic wxauto Bridge channel self-test" `
      -Detail ($selfTestText -replace "\s+", " ")
  } catch {
    Write-DoctorCheck -State "FAIL" -Name "synthetic wxauto Bridge channel self-test" -Detail $_.Exception.Message
  }
}

Write-Host ""
Write-Host "== Real Trace E2E Assertion =="
if ($FullE2E) {
  $RunE2E = $true
}
if ($RunE2E) {
  $e2eArgs = @("-BridgeUrl", $BridgeUrl)
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $e2eArgs += @("-TargetName", $TargetName)
  }
  if ($FullE2E) {
    $e2eArgs += @("-RequireOpenClaw", "-RequireRealSend", "-Strict")
  } else {
    $e2eArgs += @("-AllowDryRun", "-SkipBlockedTraces")
  }
  $e2e = Invoke-DoctorScript -ScriptName "assert-aipet-wechat-e2e.ps1" -Arguments $e2eArgs
  $e2eState = "FAIL"
  if ($e2e.ExitCode -eq 0 -and $e2e.Text -match "E2E ASSERTION:\s+OK") {
    $e2eState = "OK"
  } elseif ($e2e.ExitCode -eq 0 -and $e2e.Text -match "E2E ASSERTION:\s+NEEDS ACTION") {
    $e2eState = "WARN"
  }
  Write-DoctorCheck -State $e2eState `
    -Name ($(if ($FullE2E) { "full E2E assertion" } else { "recent E2E assertion" })) `
    -Detail $e2e.Text `
    -Action "send a real allowed WeChat message, then run doctor with -FullE2E"
} else {
  Write-DoctorCheck -State "WARN" `
    -Name "real trace E2E assertion" `
    -Detail "skipped" `
    -Action "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor-ai-pet-wechat-full.ps1 -RunE2E"
}

Write-Host ""
if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) {
  Write-Host "FINAL: READY"
} elseif ($script:FailCount -eq 0) {
  Write-Host "FINAL: READY WITH WARNINGS ($script:WarnCount warning(s))"
} else {
  Write-Host "FINAL: NEEDS ACTION ($script:FailCount failure(s), $script:WarnCount warning(s))"
}

if ($Strict -and $script:FailCount -gt 0) {
  exit 1
}
