param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 180,
  [int]$PrivateRateLimitMinutes = 1,
  [switch]$SkipStartStack,
  [switch]$RestartStack,
  [switch]$DryRun,
  [switch]$Strict
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$CacheDir = Join-Path $ProjectRoot ".cache"
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

function Repair-Text {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return ""
  }

  $text = [string]$Value
  for ($attempt = 0; $attempt -lt 3 -and $text -match "[\u0080-\u009F]"; $attempt++) {
    try {
      $latin1 = [Text.Encoding]::GetEncoding("iso-8859-1")
      $bytes = $latin1.GetBytes($text)
      $candidate = [Text.Encoding]::UTF8.GetString($bytes)
      if ($candidate -and $candidate -notmatch [char]0xFFFD) {
        $text = $candidate
      } else {
        break
      }
    } catch {
      # Keep original text if the runtime cannot load the code page.
      break
    }
  }

  return ($text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]", "").Trim()
}

function ConvertTo-JsonBody {
  param([object]$Value)
  return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 16)))
}

function Convert-SettingsToHashtable {
  param([object]$Settings)
  $result = [ordered]@{}
  foreach ($property in $Settings.PSObject.Properties) {
    $value = $property.Value
    if ($value -is [array]) {
      $result[$property.Name] = @($value)
    } else {
      $result[$property.Name] = $value
    }
  }
  return $result
}

function Invoke-BridgeSettings {
  param(
    [ValidateSet("Get", "Put")]
    [string]$Method,
    [object]$Body = $null
  )

  $bridge = $BridgeUrl.TrimEnd("/")
  $encodedPetId = [System.Uri]::EscapeDataString($PetId)
  $uri = "$bridge/pets/$encodedPetId/wechat/settings"
  if ($Method -eq "Get") {
    return Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 10
  }
  return Invoke-RestMethod `
    -Method Put `
    -Uri $uri `
    -ContentType "application/json; charset=utf-8" `
    -Body (ConvertTo-JsonBody $Body) `
    -TimeoutSec 10
}

function Invoke-ChildPowerShell {
  param(
    [string[]]$Arguments,
    [string]$FailureMessage
  )

  $output = & powershell @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  foreach ($line in $output) {
    Write-Host ([string]$line)
  }
  if ($exitCode -ne 0) {
    throw $FailureMessage
  }
}

function Test-HttpOk {
  param([string]$Url)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
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

function Test-BridgePolicyReady {
  param([object]$Health)
  return $Health -and [bool]$Health.wechat_private_manual_review_enforced
}

function Ensure-BridgeAvailable {
  $bridgeHealthUrl = $BridgeUrl.TrimEnd("/") + "/health"
  $bridgeHealth = Get-BridgeHealth
  if (Test-BridgePolicyReady -Health $bridgeHealth) {
    return
  }

  if ($SkipStartStack) {
    if ($bridgeHealth) {
      throw "AI Pet Bridge at $BridgeUrl is reachable but not running the current WeChat safety policy, and -SkipStartStack was used."
    }
    throw "AI Pet Bridge is not reachable at $BridgeUrl and -SkipStartStack was used."
  }

  if ($bridgeHealth) {
    Write-Warning "AI Pet Bridge is reachable but outdated. Restarting Bridge before reading temporary E2E settings..."
  } else {
    Write-Host "AI Pet Bridge is not reachable. Starting Bridge before reading temporary E2E settings..."
  }
  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "setup-ai-pet-wechat-full.ps1"),
    "-FromBridge",
    "-StartBridge",
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  ) -FailureMessage "Failed to start AI Pet Bridge before private full E2E settings."

  $bridgeHealth = Get-BridgeHealth
  if (-not $bridgeHealth) {
    throw "AI Pet Bridge did not become reachable at $BridgeUrl."
  }
  if (-not (Test-BridgePolicyReady -Health $bridgeHealth)) {
    throw "AI Pet Bridge at $BridgeUrl is still not running the current WeChat safety policy."
  }
}

function Stop-WxautoRuntimeFailClosed {
  param([string]$Reason)

  Write-Warning "$Reason"
  Write-Warning "Stopping wxauto runtime as a fail-closed fallback."
  & powershell -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1")
}

function Restore-WxautoRuntimeAfterSettingsRestore {
  if ($SkipStartStack) {
    Write-Host "SkipStartStack was used; leaving wxauto runtime ownership to the caller."
    return $true
  }

  try {
    Invoke-ChildPowerShell -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "setup-ai-pet-wechat-full.ps1"),
      "-FromBridge",
      "-StartWxauto",
      "-RestartWxauto",
      "-AutoActivate",
      "-Visible",
      "-BridgeUrl",
      $BridgeUrl,
      "-PetId",
      $PetId
    ) -FailureMessage "Failed to restart wxauto runtime after restoring settings."
    Write-Host "wxauto runtime restarted with restored Bridge settings."
    return $true
  } catch {
    Stop-WxautoRuntimeFailClosed `
      -Reason "Failed to restart wxauto runtime after restoring settings: $($_.Exception.Message)"
    return $false
  }
}

Ensure-BridgeAvailable
$current = Invoke-BridgeSettings -Method Get
$finalExitCode = 0

$updated = Convert-SettingsToHashtable $current.settings
$allowlist = New-Object System.Collections.Generic.List[string]
foreach ($name in @($updated["private_contact_allowlist"])) {
  $text = Repair-Text ([string]$name)
  if (-not [string]::IsNullOrWhiteSpace($text) -and -not $allowlist.Contains($text)) {
    $allowlist.Add($text) | Out-Null
  }
}

$TargetName = Repair-Text $TargetName

if ([string]::IsNullOrWhiteSpace($TargetName) -and $allowlist.Count -gt 0) {
  $TargetName = [string]$allowlist[0]
}

if ([string]::IsNullOrWhiteSpace($TargetName)) {
  throw "TargetName is required when the current private allowlist is empty."
}

if (-not $allowlist.Contains($TargetName)) {
  $allowlist.Add($TargetName) | Out-Null
}

$updated["private_contact_allowlist"] = @($allowlist)
$updated["private_auto_reply_enabled"] = $true
$updated["auto_reply_enabled"] = $false
$updated["manual_review"] = $false
$updated["emergency_stop"] = $false
$updated["quiet_hours_start"] = "00:00"
$updated["quiet_hours_end"] = "00:00"
$updated["private_rate_limit_minutes"] = [Math]::Max(1, $PrivateRateLimitMinutes)
$currentPrivateDailyLimit = 30
if ($updated.Contains("private_daily_limit") -and $null -ne $updated["private_daily_limit"]) {
  $currentPrivateDailyLimit = [int]$updated["private_daily_limit"]
}
$updated["private_daily_limit"] = [Math]::Max(30, $currentPrivateDailyLimit)
$updated["require_mention"] = $true

if ($DryRun) {
  Write-Host "AI Pet private full E2E dry run:"
  Write-Host "  target: $TargetName"
  Write-Host "  current_private_contacts: $(@($current.settings.private_contact_allowlist).Count)"
  Write-Host "  proposed_private_contacts: $(@($updated["private_contact_allowlist"]).Count)"
  Write-Host "  proposed_private_auto_reply_enabled: $($updated["private_auto_reply_enabled"])"
  Write-Host "  proposed_group_auto_reply_enabled: $($updated["auto_reply_enabled"])"
  Write-Host "  proposed_manual_review: $($updated["manual_review"])"
  Write-Host "  proposed_emergency_stop: $($updated["emergency_stop"])"
  Write-Host "  proposed_quiet_hours: $($updated["quiet_hours_start"])-$($updated["quiet_hours_end"])"
  Write-Host "  proposed_private_rate_limit_minutes: $($updated["private_rate_limit_minutes"])"
  Write-Host ""
  Write-Host "No Bridge settings were changed, no wxauto config was regenerated, and no live test was started."
  return
}

$snapshotPath = Join-Path $CacheDir ("aipet-wechat-settings-before-private-full-e2e-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$current.settings | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8

Write-Host "Saved current Bridge WeChat settings snapshot:"
Write-Host "  $snapshotPath"

$restoreSucceeded = $false
try {
  Invoke-BridgeSettings -Method Put -Body $updated | Out-Null
  Write-Host "Temporary private full E2E settings applied."
  Write-Host "  target: $TargetName"
  Write-Host "  private_auto_reply_enabled: true"
  Write-Host "  group_auto_reply_enabled: false"
  Write-Host "  manual_review: false for this temporary send test"
  Write-Host "  quiet_hours: disabled for this temporary test"
  Write-Host ""

  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "configure-wxauto-openclaw-channel.ps1"),
    "-FromBridge",
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  ) -FailureMessage "Failed to regenerate wxauto config for temporary full E2E settings."

  $liveArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "start-aipet-wechat-live-test.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId,
    "-TargetName",
    $TargetName,
    "-TimeoutSeconds",
    ([string]$TimeoutSeconds),
    "-FullE2E"
  )
  if ($SkipStartStack) {
    $liveArgs += "-SkipStartStack"
  }
  if ($RestartStack) {
    $liveArgs += "-RestartStack"
  }
  if ($Strict) {
    $liveArgs += "-Strict"
  }

  & powershell @liveArgs
  $liveExitCode = $LASTEXITCODE
  if ($liveExitCode -ne 0 -and $Strict) {
    $finalExitCode = $liveExitCode
  }
} finally {
  try {
    Invoke-ChildPowerShell -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "restore-aipet-wechat-settings.ps1"),
      "-SnapshotPath",
      $snapshotPath,
      "-BridgeUrl",
      $BridgeUrl,
      "-PetId",
      $PetId
    ) -FailureMessage "Failed to restore Bridge WeChat settings from snapshot."
    $restoreSucceeded = $true
  } catch {
    Write-Warning "Failed to restore Bridge WeChat settings automatically: $($_.Exception.Message)"
    Write-Warning "Restore manually with:"
    Write-Warning "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-aipet-wechat-settings.ps1 -SnapshotPath `"$snapshotPath`""
    $finalExitCode = 1
    if (-not $SkipStartStack) {
      Stop-WxautoRuntimeFailClosed `
        -Reason "Bridge settings restore failed; wxauto runtime must not keep temporary send settings."
    }
  }

  if ($restoreSucceeded) {
    Write-Host ""
    Write-Host "Original Bridge WeChat settings restored."
    $runtimeRestored = Restore-WxautoRuntimeAfterSettingsRestore
    if (-not $runtimeRestored) {
      $finalExitCode = 1
    }
  }
}

if ($finalExitCode -ne 0) {
  exit $finalExitCode
}
