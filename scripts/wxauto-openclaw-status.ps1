param(
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$OpenClawGatewayUrl = "http://127.0.0.1:18789",
  [switch]$Strict
)

$ErrorActionPreference = "Continue"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$script:WarnCount = 0
$script:NextActions = New-Object System.Collections.Generic.List[string]

function Write-Check {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = "",
    [string]$Action = ""
  )

  $status = if ($Ok) { "OK" } else { "WARN" }
  if (-not $Ok) {
    $script:WarnCount += 1
    if (-not [string]::IsNullOrWhiteSpace($Action) -and -not $script:NextActions.Contains($Action)) {
      $script:NextActions.Add($Action) | Out-Null
    }
  }

  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host "[$status] $Name"
  } else {
    Write-Host "[$status] $Name - $Detail"
  }
}

function Test-Http {
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
    }
  }

  if (Test-PidActive -ProcessId $lockPid) {
    return [pscustomobject]@{
      Ok = $true
      Detail = "active pid=$lockPid started_at=$startedAt"
    }
  }

  return [pscustomobject]@{
    Ok = $false
    Detail = "stale pid=$lockPid path=$lockPath"
  }
}

function Invoke-StatusScript {
  param(
    [string]$ScriptName,
    [string[]]$Arguments = @()
  )

  try {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $ScriptName) @Arguments 2>&1
    return [pscustomobject]@{
      ExitCode = $LASTEXITCODE
      Text = (($output | ForEach-Object { [string]$_ }) -join " ") -replace "\s+", " "
    }
  } catch {
    return [pscustomobject]@{
      ExitCode = 1
      Text = $_.Exception.Message
    }
  }
}

function Test-ActivationText {
  param([string]$Text)

  $notActivatedText = [string]([char]0x672A) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $activatedText = [string]([char]0x5DF2) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $activationNegative = (
    $Text.Contains($notActivatedText) -or
    $Text -match "(?i)\bnot[_\s-]?activated\b"
  )
  $activationPositive = (
    $Text.Contains($activatedText) -or
    $Text -match "(?i)\bactivated\b" -or
    $Text -match "\bTrue\b"
  )
  return (-not $activationNegative) -and $activationPositive
}

function Get-WxautoxActivationStatus {
  param([ValidateSet("current", "project", "default")] [string]$HomeMode)

  $args = @("-CheckOnly")
  if ($HomeMode -ne "current") {
    $args += @("-HomeMode", $HomeMode)
  }
  $activation = Invoke-StatusScript -ScriptName "activate-wxautox4.ps1" -Arguments $args
  $activationText = [string]$activation.Text
  return [pscustomobject]@{
    HomeMode = $HomeMode
    ExitCode = $activation.ExitCode
    Text = $activationText
    Activated = ($activation.ExitCode -eq 0 -and (Test-ActivationText -Text $activationText))
  }
}

function Get-LatestFullE2EProofStatus {
  $latestProof = Get-ChildItem `
    -LiteralPath $WxautoEnv.LogsDir `
    -Filter "aipet-wechat-full-e2e-proof-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if (-not $latestProof) {
    return [pscustomobject]@{
      Ok = $false
      Detail = "not found"
    }
  }

  try {
    $proof = Get-Content -LiteralPath $latestProof.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      Ok = $false
      Detail = "unreadable proof: $($latestProof.FullName)"
    }
  }

  $requiresOpenClaw = [bool]$proof.requirements.require_openclaw
  $requiresRealSend = [bool]$proof.requirements.require_real_send
  $openclawUsed = [bool]$proof.checks.openclaw_model_path_used
  $realSent = [bool]$proof.checks.real_wechat_reply_sent
  $modelPath = [string]$proof.model_path
  $traceId = [string]$proof.trace_id
  $target = [string]$proof.target
  $outcomeEvent = [string]$proof.latest_outcome.event
  $ok = $requiresOpenClaw -and $requiresRealSend -and $openclawUsed -and $realSent -and $modelPath -eq "openclaw"

  $detail = "path=$($latestProof.FullName) trace_id=$traceId target=$target model_path=$modelPath outcome=$outcomeEvent generated_at=$($proof.generated_at)"
  return [pscustomobject]@{
    Ok = $ok
    Detail = $detail
  }
}

Write-Host "== Local files =="
Write-Check "wxauto channel source" (Test-Path -LiteralPath $WxautoEnv.ChannelRoot) $WxautoEnv.ChannelRoot
Write-Check "Python venv" (Test-Path -LiteralPath $WxautoEnv.VenvPython) $WxautoEnv.VenvPython
Write-Check "wxautox4 CLI" (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe) $WxautoEnv.Wxautox4Exe
Write-Check "wxautox home" (Test-Path -LiteralPath $WxautoEnv.WxautoxHome) "$($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)"
Write-Check "wxauto API config" (Test-Path -LiteralPath (Join-Path $WxautoEnv.ApiRoot "config.yaml")) (Join-Path $WxautoEnv.ApiRoot "config.yaml")
Write-Check "wxauto channel config" (Test-Path -LiteralPath (Join-Path $WxautoEnv.WxChannelRoot "config.yaml")) (Join-Path $WxautoEnv.WxChannelRoot "config.yaml")

Write-Host ""
Write-Host "== Secrets =="
Write-Check "wxautox4 activation code configured" (-not [string]::IsNullOrWhiteSpace($WxautoEnv.LicenseKey)) ".env.local / process env"

Write-Host ""
Write-Host "== wxautox4 activation =="
$activation = Get-WxautoxActivationStatus -HomeMode "current"
$activated = [bool]$activation.Activated
$alternateMode = if ($WxautoEnv.WxautoxHomeMode -eq "default") { "project" } else { "default" }
$alternateActivation = $null
if (-not $activated) {
  $alternateActivation = Get-WxautoxActivationStatus -HomeMode $alternateMode
}
$activationAction = if (-not [string]::IsNullOrWhiteSpace($WxautoEnv.LicenseKey)) {
  "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1"
} else {
  "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\save-wxautox4-license.ps1 -LicenseKey <your-code>"
}
$activationDetail = $activation.Text
if ($alternateActivation -and [bool]$alternateActivation.Activated) {
  $activationAction = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -Mode $alternateMode"
  $activationDetail = "$activationDetail alternate_${alternateMode}=activated"
}
Write-Check `
  -Name "wxautox4 activated" `
  -Ok $activated `
  -Detail $activationDetail `
  -Action $activationAction
if (-not $activated -and $alternateActivation) {
  $alternateAction = if ([bool]$alternateActivation.Activated) {
    "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -Mode $alternateMode"
  } else {
    "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\set-wxautox-home-mode.ps1 -CheckOnly"
  }
  Write-Check `
    -Name "wxautox4 $alternateMode home activation" `
    -Ok ([bool]$alternateActivation.Activated) `
    -Detail $alternateActivation.Text `
    -Action $alternateAction
}

Write-Host ""
Write-Host "== Services =="
$bridgeHealth = Get-BridgeHealth
$bridgeOk = $null -ne $bridgeHealth -and $bridgeHealth.status -eq "ok"
$bridgePolicyOk = $bridgeOk -and [bool]$bridgeHealth.wechat_private_manual_review_enforced
$openclawConfigured = $bridgeOk -and [bool]$bridgeHealth.openclaw_configured
Write-Check "AI Pet Bridge" $bridgeOk $BridgeUrl "scripts\restart-ai-pet-wechat-full.cmd"
Write-Check "Bridge WeChat policy" $bridgePolicyOk "private manual review enforced=$($bridgeHealth.wechat_private_manual_review_enforced)" "scripts\restart-ai-pet-wechat-full.cmd"
Write-Check "Bridge OpenClaw configured" $openclawConfigured "" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-bridge.ps1"
Write-Check "wxauto API" (Test-Http "$($WxApiBaseUrl.TrimEnd('/'))/") "" "scripts\restart-ai-pet-wechat-full.cmd"
Write-Check "wxauto API activation endpoint" (Test-Http "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check") "" "scripts\restart-ai-pet-wechat-full.cmd"
Write-Check "OpenClaw Gateway" (Test-Http "$($OpenClawGatewayUrl.TrimEnd('/'))/health") "" "scripts\restart-ai-pet-wechat-full.cmd"

Write-Host ""
Write-Host "== Desktop WeChat =="
$weixin = @(Get-Process Weixin, WeChat -ErrorAction SilentlyContinue)
Write-Check "Windows WeChat desktop process" ($weixin.Count -gt 0) "count=$($weixin.Count)" "open and log in the real pet WeChat account in Windows WeChat"

Write-Host ""
Write-Host "== Channel lock =="
$lockStatus = Get-WxautoChannelLockStatus
$lockAction = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-wxauto-openclaw-channel.ps1"
if (-not $lockStatus.Ok -and [string]$lockStatus.Detail -match "stale|unreadable") {
  $lockAction = "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-wxauto-openclaw-channel.ps1 -OnlyClearStaleLock"
}
Write-Check "wxauto Bridge channel single-instance lock" $lockStatus.Ok $lockStatus.Detail $lockAction

Write-Host ""
Write-Host "== Config validation =="
$configCheck = Invoke-StatusScript -ScriptName "test-wxauto-openclaw-config.ps1"
Write-Check "wxauto config parser" ($configCheck.ExitCode -eq 0 -and $configCheck.Text -match "wxauto_config_ok") $configCheck.Text "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-wxauto-openclaw-channel.ps1 -FromBridge"

$channelConfigPath = Join-Path $WxautoEnv.WxChannelRoot "config.yaml"
if (Test-Path -LiteralPath $channelConfigPath) {
  $configText = Get-Content -LiteralPath $channelConfigPath -Raw
  $hasNickname = $configText -match "(?m)^my_nickname:\s*(.+)$"
  $hasBridge = $configText -match "(?m)^aipet_bridge:\s*$"
  $privateCount = ([regex]::Matches($configText, "(?m)^\s*-\s+name:\s+")).Count
  Write-Check "my_nickname configured" $hasNickname "" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-aipet-wechat-family.ps1 -Mode observe"
  Write-Check "AI Pet Bridge channel config" $hasBridge "" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-wxauto-openclaw-channel.ps1 -FromBridge"
  Write-Check "listener entries" ($privateCount -gt 0) "$privateCount configured target(s)" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-aipet-wechat-family.ps1 -PrivateContact <contact1>,<contact2>"
} else {
  Write-Check "config summary" $false "wxauto channel config missing" "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-wxauto-openclaw-channel.ps1 -FromBridge"
}

Write-Host ""
Write-Host "== Runtime contract =="
if (Test-Http "$($WxApiBaseUrl.TrimEnd('/'))/") {
  $runtime = Invoke-StatusScript -ScriptName "test-wxauto-runtime-contract.ps1" -Arguments @(
    "-WxApiBaseUrl",
    $WxApiBaseUrl,
    "-Strict"
  )
  Write-Check "wxauto runtime contract" ($runtime.ExitCode -eq 0) $runtime.Text "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-wxauto-runtime-contract.ps1 -Strict"
} else {
  Write-Check "wxauto runtime contract" $false "skipped because wxauto API is offline" "scripts\restart-ai-pet-wechat-full.cmd"
}

Write-Host ""
Write-Host "== Recent trace =="
$trace = Invoke-StatusScript -ScriptName "assert-aipet-wechat-e2e.ps1" -Arguments @(
  "-BridgeUrl",
  $BridgeUrl,
  "-AllowDryRun",
  "-SkipBlockedTraces"
)
Write-Check "recent E2E trace" ($trace.ExitCode -eq 0 -and $trace.Text -match "E2E ASSERTION:\s+OK") $trace.Text "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wait-aipet-wechat-e2e.ps1 -TargetName <contact> -FullE2E -Strict"

Write-Host ""
Write-Host "== Full E2E Proof =="
$proofStatus = Get-LatestFullE2EProofStatus
Write-Check "latest full E2E proof" $proofStatus.Ok $proofStatus.Detail "powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName <contact> -TemporaryPrivateAuto -RestartStack"

Write-Host ""
if ($script:WarnCount -eq 0) {
  Write-Host "FINAL: READY"
} else {
  Write-Host "FINAL: NEEDS ACTION ($script:WarnCount warning(s))"
  if ($script:NextActions.Count -gt 0) {
    Write-Host ""
    Write-Host "Suggested next actions:"
    foreach ($action in $script:NextActions) {
      Write-Host "  $action"
    }
  }
  if ($Strict) {
    exit 1
  }
}
