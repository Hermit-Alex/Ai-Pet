param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 180,
  [int]$PrivateRateLimitMinutes = 1,
  [switch]$TemporaryPrivateAuto,
  [switch]$SkipStartStack,
  [switch]$RestartStack,
  [switch]$DryRun,
  [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LogsDir = Join-Path $ProjectRoot "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

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

function Add-CommonArgs {
  param([string[]]$Arguments)

  $Arguments += @(
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId,
    "-TimeoutSeconds",
    ([string]$TimeoutSeconds)
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $Arguments += @("-TargetName", $TargetName)
  }
  if ($SkipStartStack) {
    $Arguments += "-SkipStartStack"
  }
  if ($RestartStack) {
    $Arguments += "-RestartStack"
  }
  return $Arguments
}

function New-PlanCommand {
  param([string[]]$Arguments)

  return [pscustomobject]@{
    executable = "powershell"
    arguments = @($Arguments)
  }
}

function New-ReadinessAuditArgs {
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "audit-ai-pet-wechat-full-readiness.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-RequiredPhase",
    "repair_verify",
    "-Strict"
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $args += @("-TargetName", $TargetName)
  }
  return $args
}

Write-Host "== AI Pet WeChat Full Verification =="
Write-Host "Bridge: $BridgeUrl"
Write-Host "Pet: $PetId"
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  Write-Host "Target: $TargetName"
}
Write-Host "Timeout: $TimeoutSeconds seconds"
Write-Host "Temporary private auto: $TemporaryPrivateAuto"
Write-Host "Restart stack: $RestartStack"
Write-Host "Skip start stack: $SkipStartStack"
Write-Host ""

if ($PlanOnly) {
  $commands = New-Object System.Collections.Generic.List[object]

  if ($DryRun) {
    if ($TemporaryPrivateAuto) {
      $commands.Add((New-PlanCommand -Arguments (Add-CommonArgs -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $PSScriptRoot "start-aipet-wechat-private-full-e2e.ps1"),
        "-PrivateRateLimitMinutes",
        ([string]$PrivateRateLimitMinutes),
        "-DryRun"
      )))) | Out-Null
    } else {
      $commands.Add((New-PlanCommand -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $PSScriptRoot "wxauto-openclaw-status.ps1")
      ))) | Out-Null
    }
  } elseif ($TemporaryPrivateAuto) {
    $commands.Add((New-PlanCommand -Arguments (New-ReadinessAuditArgs))) | Out-Null
    $commands.Add((New-PlanCommand -Arguments (Add-CommonArgs -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "start-aipet-wechat-private-full-e2e.ps1"),
      "-PrivateRateLimitMinutes",
      ([string]$PrivateRateLimitMinutes),
      "-Strict"
    )))) | Out-Null
  } else {
    $commands.Add((New-PlanCommand -Arguments (New-ReadinessAuditArgs))) | Out-Null
    $commands.Add((New-PlanCommand -Arguments (Add-CommonArgs -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "start-aipet-wechat-live-test.ps1"),
      "-FullE2E",
      "-Strict"
    )))) | Out-Null
  }

  if (-not $DryRun) {
    $doctorArgs = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "doctor-ai-pet-wechat-full.ps1"),
      "-BridgeUrl",
      $BridgeUrl,
      "-PetId",
      $PetId,
      "-FullE2E",
      "-Strict"
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
      $doctorArgs += @("-TargetName", $TargetName)
    }
    $commands.Add((New-PlanCommand -Arguments $doctorArgs)) | Out-Null
  }

  $planMode = if ($TemporaryPrivateAuto) { "temporary_private_auto" } else { "live_full_e2e" }
  $planCommands = @($commands.ToArray())
  [pscustomobject]@{
    mode = $planMode
    dry_run = [bool]$DryRun
    proof_export = (-not [bool]$DryRun)
    command_count = $commands.Count
    commands = $planCommands
  } | ConvertTo-Json -Depth 8
  return
}

if ($DryRun) {
  Write-Host "Dry run: no live WeChat wait will be started."
  if ($TemporaryPrivateAuto) {
    $previewArgs = Add-CommonArgs -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "start-aipet-wechat-private-full-e2e.ps1"),
      "-PrivateRateLimitMinutes",
      ([string]$PrivateRateLimitMinutes),
      "-DryRun"
    )
    Invoke-ChildPowerShell `
      -Arguments $previewArgs `
      -FailureMessage "Temporary private full E2E dry-run preview failed."
  } else {
    Invoke-ChildPowerShell `
      -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $PSScriptRoot "wxauto-openclaw-status.ps1")
      ) `
      -FailureMessage "Status dry-run check failed."
  }
  return
}

Invoke-ChildPowerShell `
  -Arguments (New-ReadinessAuditArgs) `
  -FailureMessage "AI Pet WeChat repair-readiness audit failed."

if ($TemporaryPrivateAuto) {
  $verifyArgs = Add-CommonArgs -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "start-aipet-wechat-private-full-e2e.ps1"),
    "-PrivateRateLimitMinutes",
    ([string]$PrivateRateLimitMinutes),
    "-Strict"
  )
  Invoke-ChildPowerShell `
    -Arguments $verifyArgs `
    -FailureMessage "Temporary private full E2E verification failed."
} else {
  $verifyArgs = Add-CommonArgs -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "start-aipet-wechat-live-test.ps1"),
    "-FullE2E",
    "-Strict"
  )
  Invoke-ChildPowerShell `
    -Arguments $verifyArgs `
    -FailureMessage "Full live WeChat verification failed."
}

$doctorArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $PSScriptRoot "doctor-ai-pet-wechat-full.ps1"),
  "-BridgeUrl",
  $BridgeUrl,
  "-PetId",
  $PetId,
  "-FullE2E",
  "-Strict"
)
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  $doctorArgs += @("-TargetName", $TargetName)
}

Invoke-ChildPowerShell `
  -Arguments $doctorArgs `
  -FailureMessage "Final full E2E doctor assertion failed."

$proofPath = Join-Path $LogsDir ("aipet-wechat-full-e2e-proof-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$proofArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $PSScriptRoot "assert-aipet-wechat-e2e.ps1"),
  "-BridgeUrl",
  $BridgeUrl,
  "-RequireOpenClaw",
  "-RequireRealSend",
  "-Strict",
  "-ProofPath",
  $proofPath
)
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  $proofArgs += @("-TargetName", $TargetName)
}
Invoke-ChildPowerShell `
  -Arguments $proofArgs `
  -FailureMessage "Full E2E proof export failed."

Write-Host ""
Write-Host "AI Pet full WeChat verification passed."
Write-Host "Full E2E proof exported:"
Write-Host "  $proofPath"
