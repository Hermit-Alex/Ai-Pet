param(
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$OpenClawGatewayUrl = "http://127.0.0.1:18789",
  [string]$TargetName = "",
  [ValidateSet("repair_verify", "full_e2e", "verified")]
  [string]$RequiredPhase = "verified",
  [switch]$Strict
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot

function New-Check {
  param(
    [string]$Id,
    [string]$Label,
    [bool]$Ok,
    [string]$Phase,
    [string]$Detail = "",
    [string]$Action = ""
  )

  return [ordered]@{
    id = $Id
    label = $Label
    ok = [bool]$Ok
    phase = $Phase
    detail = $Detail
    action = $Action
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
  try {
    return Invoke-RestMethod -Method Get -Uri "$($BridgeUrl.TrimEnd('/'))/health" -TimeoutSec 5
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

function Test-ActivationText {
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

function Get-WxautoxActivationSummary {
  param([ValidateSet("current", "project", "default")] [string]$HomeMode)

  try {
    $args = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "activate-wxautox4.ps1"),
      "-CheckOnly"
    )
    if ($HomeMode -ne "current") {
      $args += @("-HomeMode", $HomeMode)
    }
    $output = powershell @args 2>&1
    $text = (($output | ForEach-Object { [string]$_ }) -join " ") -replace "\s+", " "
    return [pscustomobject]@{
      checked = $true
      activated = (Test-ActivationText -Text $text)
      exit_code = $LASTEXITCODE
    }
  } catch {
    return [pscustomobject]@{
      checked = $false
      activated = $false
      exit_code = 1
    }
  }
}

function Test-PidActive {
  param([int]$ProcessId)
  if ($ProcessId -le 0) {
    return $false
  }
  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-ChannelLockSummary {
  $lockPath = $WxautoEnv.WxautoBridgeChannelLockPath
  if (-not (Test-Path -LiteralPath $lockPath)) {
    return [pscustomobject]@{
      ok = $true
      detail = "not_present"
    }
  }

  try {
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockPid = [int]$lock.pid
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "unreadable"
    }
  }

  if (Test-PidActive -ProcessId $lockPid) {
    return [pscustomobject]@{
      ok = $true
      detail = "active"
    }
  }

  return [pscustomobject]@{
    ok = $false
    detail = "stale"
  }
}

function Get-LatestFullE2EProofSummary {
  $latestProof = Get-ChildItem `
    -LiteralPath $WxautoEnv.LogsDir `
    -Filter "aipet-wechat-full-e2e-proof-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $latestProof) {
    return [pscustomobject]@{
      ok = $false
      detail = "not_found"
      trace_id = ""
      target = ""
      model_path = ""
    }
  }

  try {
    $proof = Get-Content -LiteralPath $latestProof.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $ok = (
      [bool]$proof.requirements.require_openclaw -and
      [bool]$proof.requirements.require_real_send -and
      [bool]$proof.checks.openclaw_model_path_used -and
      [bool]$proof.checks.real_wechat_reply_sent -and
      [string]$proof.model_path -eq "openclaw"
    )
    return [pscustomobject]@{
      ok = $ok
      detail = $latestProof.FullName
      trace_id = [string]$proof.trace_id
      target = [string]$proof.target
      model_path = [string]$proof.model_path
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      detail = "unreadable"
      trace_id = ""
      target = ""
      model_path = ""
    }
  }
}

$checks = New-Object System.Collections.Generic.List[object]

$checks.Add((New-Check "local.wxauto_channel_source" "wxauto channel source" (Test-Path -LiteralPath $WxautoEnv.ChannelRoot) "repair_verify" $WxautoEnv.ChannelRoot "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-wxauto-openclaw-channel.ps1 -InstallDeps")) | Out-Null
$checks.Add((New-Check "local.python_venv" "Python venv" (Test-Path -LiteralPath $WxautoEnv.VenvPython) "repair_verify" $WxautoEnv.VenvPython "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-dev.ps1 -Install")) | Out-Null
$checks.Add((New-Check "local.wxautox4_cli" "wxautox4 CLI" (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe) "repair_verify" $WxautoEnv.Wxautox4Exe "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-wxauto-openclaw-channel.ps1 -InstallDeps")) | Out-Null
$checks.Add((New-Check "local.wxautox_home" "wxautox home" (Test-Path -LiteralPath $WxautoEnv.WxautoxHome) "repair_verify" "$($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)" "")) | Out-Null
$checks.Add((New-Check "secret.wxautox4_license" "wxautox4 license configured" (-not [string]::IsNullOrWhiteSpace($WxautoEnv.LicenseKey)) "repair_verify" ".env.local / process env" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\save-wxautox4-license.ps1 -LicenseKey <your-code>")) | Out-Null

$channelConfigPath = Join-Path $WxautoEnv.WxChannelRoot "config.yaml"
$configSummary = $null
if (Test-Path -LiteralPath $channelConfigPath) {
  $configSummary = Invoke-JsonProbe @"
import json
from aipet_wxauto_bridge_channel.channel import ChannelConfig
config = ChannelConfig.from_yaml(r"$channelConfigPath", bridge_url=r"$BridgeUrl")
targets = list(config.target_names)
print(json.dumps({
    "ok": True,
    "target_count": len(targets),
    "private_count": len([chat for chat in config.private_chats if chat.enabled]),
    "group_count": len([chat for chat in config.group_chats if chat.enabled]),
    "target_names": targets,
    "my_nickname": config.my_nickname,
    "allowed_message_types": list(config.allowed_message_types),
    "require_openclaw_for_send": config.require_openclaw_for_send,
}, ensure_ascii=False, separators=(",", ":")))
"@
}

$configOk = $false
$configDetail = "missing"
$targetConfigured = [string]::IsNullOrWhiteSpace($TargetName)
$targetDetail = "target_not_specified; first configured target can be used by live test scripts"
if ($configSummary -and [bool]$configSummary.ok) {
  $targetCount = [int]$configSummary.target_count
  $textOnly = @($configSummary.allowed_message_types).Count -eq 1 -and [string]@($configSummary.allowed_message_types)[0] -eq "text"
  $configuredTargets = @($configSummary.target_names | ForEach-Object { [string]$_ })
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $targetConfigured = $configuredTargets -contains $TargetName
    $targetDetail = "requested=$TargetName configured=$($configuredTargets -join ',')"
  } else {
    $targetDetail = "target_not_specified configured=$($configuredTargets -join ',')"
  }
  $configOk = (
    $targetCount -gt 0 -and
    -not [string]::IsNullOrWhiteSpace([string]$configSummary.my_nickname) -and
    $textOnly -and
    [bool]$configSummary.require_openclaw_for_send
  )
  $configDetail = "targets=$targetCount private=$($configSummary.private_count) group=$($configSummary.group_count) text_only=$textOnly require_openclaw=$($configSummary.require_openclaw_for_send)"
}
$checks.Add((New-Check "config.channel" "AI Pet wxauto channel config" $configOk "repair_verify" $configDetail "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-aipet-wechat-family.ps1 -Mode observe")) | Out-Null
$checks.Add((New-Check "config.target_name" "requested target is configured for wxauto listen" $targetConfigured "repair_verify" $targetDetail "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-aipet-wechat-family.ps1 -PrivateContact <contact>")) | Out-Null

$weixin = @(Get-Process Weixin, WeChat -ErrorAction SilentlyContinue)
$checks.Add((New-Check "desktop.wechat_process" "Windows WeChat desktop process" ($weixin.Count -gt 0) "repair_verify" "count=$($weixin.Count)" "open and log in the real pet WeChat account in Windows WeChat")) | Out-Null

$lock = Get-ChannelLockSummary
$lockAction = if ($lock.detail -eq "stale" -or $lock.detail -eq "unreadable") {
  "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-wxauto-openclaw-channel.ps1 -OnlyClearStaleLock"
} else {
  ""
}
$checks.Add((New-Check "runtime.channel_lock" "wxauto Bridge channel lock" ([bool]$lock.ok) "repair_verify" $lock.detail $lockAction)) | Out-Null

$activation = Get-WxautoxActivationSummary -HomeMode "current"
$checks.Add((New-Check "activation.wxautox4_current_home" "wxautox4 activated in selected runtime home" ([bool]$activation.activated) "full_e2e" "checked=$($activation.checked) exit_code=$($activation.exit_code)" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1")) | Out-Null

$bridgeHealth = Get-BridgeHealth
$bridgeOk = $bridgeHealth -and $bridgeHealth.status -eq "ok"
$checks.Add((New-Check "service.bridge" "AI Pet Bridge online" $bridgeOk "full_e2e" $BridgeUrl "scripts\restart-ai-pet-wechat-full.cmd")) | Out-Null
$checks.Add((New-Check "service.bridge_policy" "Bridge WeChat safety policy current" ($bridgeOk -and [bool]$bridgeHealth.wechat_private_manual_review_enforced) "full_e2e" "private_manual_review_enforced=$($bridgeHealth.wechat_private_manual_review_enforced)" "scripts\restart-ai-pet-wechat-full.cmd")) | Out-Null
$checks.Add((New-Check "service.bridge_openclaw" "Bridge OpenClaw configured" ($bridgeOk -and [bool]$bridgeHealth.openclaw_configured) "full_e2e" "" "set AIPET_OPENCLAW_BASE_URL and restart Bridge")) | Out-Null
$checks.Add((New-Check "service.openclaw_gateway" "OpenClaw Gateway online" (Test-HttpOk "$($OpenClawGatewayUrl.TrimEnd('/'))/health") "full_e2e" $OpenClawGatewayUrl "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1")) | Out-Null
$wxApiOnline = Test-HttpOk "$($WxApiBaseUrl.TrimEnd('/'))/"
$checks.Add((New-Check "service.wxauto_api" "wxauto API online" $wxApiOnline "full_e2e" $WxApiBaseUrl "scripts\restart-ai-pet-wechat-full.cmd")) | Out-Null
$checks.Add((New-Check "service.wxauto_activation_endpoint" "wxauto activation endpoint online" (Test-HttpOk "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check") "full_e2e" "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check" "scripts\restart-ai-pet-wechat-full.cmd")) | Out-Null

$runtimeContractOk = $false
$runtimeContractDetail = "skipped_offline"
if ($wxApiOnline) {
  try {
    $runtimeArgs = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "test-wxauto-runtime-contract.ps1"),
      "-WxApiBaseUrl",
      $WxApiBaseUrl,
      "-Strict"
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
      $runtimeArgs += @("-TargetName", $TargetName)
    }
    $runtimeOutput = powershell @runtimeArgs 2>&1
    $runtimeContractOk = $LASTEXITCODE -eq 0
    $runtimeContractDetail = if ($runtimeContractOk) { "ok" } else { "failed" }
  } catch {
    $runtimeContractOk = $false
    $runtimeContractDetail = "failed"
  }
}
$checks.Add((New-Check "runtime.wxauto_contract" "wxauto runtime contract" $runtimeContractOk "full_e2e" $runtimeContractDetail "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-wxauto-runtime-contract.ps1 -Strict")) | Out-Null

$proof = Get-LatestFullE2EProofSummary
$proofDetail = "$($proof.detail) trace_id=$($proof.trace_id) target=$($proof.target) model_path=$($proof.model_path)"
$checks.Add((New-Check "proof.full_e2e" "OpenClaw model path plus real WeChat send proof" ([bool]$proof.ok) "verified" $proofDetail "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName <contact> -TemporaryPrivateAuto -RestartStack")) | Out-Null

$allChecks = @($checks.ToArray())
$repairChecks = @($allChecks | Where-Object { $_.phase -eq "repair_verify" })
$fullChecks = @($allChecks | Where-Object { $_.phase -eq "repair_verify" -or $_.phase -eq "full_e2e" })
$verifiedChecks = @($allChecks)

$readyForRepairVerify = -not [bool]($repairChecks | Where-Object { -not [bool]$_.ok } | Select-Object -First 1)
$readyForFullE2E = -not [bool]($fullChecks | Where-Object { -not [bool]$_.ok } | Select-Object -First 1)
$fullE2EVerified = -not [bool]($verifiedChecks | Where-Object { -not [bool]$_.ok } | Select-Object -First 1)

$nextActions = @(
  $allChecks |
    Where-Object { -not [bool]$_.ok -and -not [string]::IsNullOrWhiteSpace([string]$_.action) } |
    ForEach-Object { [string]$_.action } |
    Select-Object -Unique
)

$result = [ordered]@{
  generated_at = [DateTimeOffset]::Now.ToString("o")
  project_root = $ProjectRoot
  target_name = $TargetName
  required_phase = $RequiredPhase
  phases = [ordered]@{
    ready_for_repair_verify = [bool]$readyForRepairVerify
    ready_for_full_e2e = [bool]$readyForFullE2E
    full_e2e_verified = [bool]$fullE2EVerified
  }
  summary = [ordered]@{
    ok_count = @($allChecks | Where-Object { [bool]$_.ok }).Count
    failed_count = @($allChecks | Where-Object { -not [bool]$_.ok }).Count
  }
  checks = $allChecks
  next_actions = $nextActions
}

$result | ConvertTo-Json -Depth 8

$requiredPhaseOk = switch ($RequiredPhase) {
  "repair_verify" { $readyForRepairVerify }
  "full_e2e" { $readyForFullE2E }
  "verified" { $fullE2EVerified }
}

if ($Strict -and -not $requiredPhaseOk) {
  exit 1
}
