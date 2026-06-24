param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 180,
  [switch]$FullE2E,
  [switch]$SkipOpenClawSelfTest,
  [switch]$DryRun,
  [switch]$SkipStartStack,
  [switch]$RestartStack,
  [switch]$Strict
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

function Repair-Text {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return ""
  }

  $text = [string]$Value
  if ($text -match "[\u0080-\u009F]") {
    try {
      $latin1 = [Text.Encoding]::GetEncoding("iso-8859-1")
      $bytes = $latin1.GetBytes($text)
      $candidate = [Text.Encoding]::UTF8.GetString($bytes)
      if ($candidate -and $candidate -notmatch [char]0xFFFD) {
        $text = $candidate
      }
    } catch {
      # Keep original text if the runtime cannot load the code page.
    }
  }

  return ($text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]", "").Trim()
}

function Invoke-ChildPowerShell {
  param(
    [string[]]$Arguments,
    [string]$FailureMessage
  )

  & powershell @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw $FailureMessage
  }
}

function Get-BridgeHealth {
  try {
    return Invoke-RestMethod -Method Get -Uri "$($BridgeUrl.TrimEnd('/'))/health" -TimeoutSec 5
  } catch {
    return $null
  }
}

function Assert-BridgePolicyReady {
  $health = Get-BridgeHealth
  if (-not $health) {
    throw "AI Pet Bridge is not reachable at $BridgeUrl."
  }
  if (-not [bool]$health.wechat_private_manual_review_enforced) {
    throw "AI Pet Bridge at $BridgeUrl is not running the current WeChat safety policy. Re-run with -RestartStack."
  }
}

function Get-DefaultTargetName {
  param(
    [string]$MaybeBridgeUrl,
    [string]$MaybePetId
  )

  try {
    $bridge = $MaybeBridgeUrl.TrimEnd("/")
    $encodedPetId = [System.Uri]::EscapeDataString($MaybePetId)
    $response = Invoke-RestMethod `
      -Method Get `
      -Uri "$bridge/pets/$encodedPetId/wechat/settings" `
      -TimeoutSec 10
    foreach ($name in @($response.settings.private_contact_allowlist)) {
      $text = Repair-Text ([string]$name)
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    }
    foreach ($name in @($response.settings.family_groups)) {
      $text = Repair-Text ([string]$name)
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    }
  } catch {
    Write-Warning "Could not read Bridge WeChat settings for default TargetName: $($_.Exception.Message)"
  }
  return ""
}

if (-not $SkipStartStack) {
  $startArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "setup-ai-pet-wechat-full.ps1"),
    "-FromBridge",
    "-StartBridge",
    "-StartGateway",
    "-StartWxauto",
    "-AutoActivate",
    "-Visible",
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  )
  if ($DryRun) {
    $startArgs += "-DryRun"
  }
  if ($RestartStack) {
    $startArgs += "-RestartStack"
  }
  Invoke-ChildPowerShell -Arguments $startArgs -FailureMessage "Failed to start AI Pet full WeChat stack."
}

Assert-BridgePolicyReady

if ($FullE2E -and -not $SkipOpenClawSelfTest) {
  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "test-openclaw-bridge-path.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId,
    "-Strict"
  ) -FailureMessage "OpenClaw self-test failed; refusing to wait for a real WeChat message in FullE2E mode."
}

if ([string]::IsNullOrWhiteSpace($TargetName)) {
  $TargetName = Get-DefaultTargetName -MaybeBridgeUrl $BridgeUrl -MaybePetId $PetId
}
if ([string]::IsNullOrWhiteSpace($TargetName)) {
  throw "TargetName is required when the Bridge WeChat private allowlist and family group list are empty or unavailable."
}

$waitArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $PSScriptRoot "wait-aipet-wechat-e2e.ps1"),
  "-BridgeUrl",
  $BridgeUrl,
  "-TimeoutSeconds",
  ([string]$TimeoutSeconds)
)
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  $waitArgs += @("-TargetName", $TargetName)
}
if ($FullE2E) {
  $waitArgs += "-FullE2E"
}
if ($Strict) {
  $waitArgs += "-Strict"
}

Write-Host "AI Pet live WeChat test is ready."
Write-Host "Send a new WeChat message from the configured private contact or family group now."
Write-Host ""

& powershell @waitArgs
if ($LASTEXITCODE -ne 0 -and $Strict) {
  exit $LASTEXITCODE
}
