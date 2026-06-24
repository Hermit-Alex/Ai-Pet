param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 180,
  [int]$PrivateRateLimitMinutes = 1,
  [ValidateSet("temporary-private-auto", "live")]
  [string]$Mode = "temporary-private-auto",
  [switch]$SkipActivation,
  [switch]$SkipFailureDiagnostics,
  [switch]$Execute
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

function New-PlanCommand {
  param([string[]]$Arguments)

  return [pscustomobject]@{
    executable = "powershell"
    arguments = @($Arguments)
  }
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

function Invoke-BestEffortPowerShell {
  param(
    [string]$Label,
    [string[]]$Arguments
  )

  Write-Host ""
  Write-Host "== $Label =="
  try {
    & powershell @Arguments
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "$Label exited with code $LASTEXITCODE."
    }
  } catch {
    Write-Warning "$Label failed: $($_.Exception.Message)"
  }
}

function Write-FailureDiagnostics {
  param([string]$FailedCommand)

  Write-Host ""
  Write-Warning "AI Pet full WeChat repair-and-verify stopped before completion."
  if (-not [string]::IsNullOrWhiteSpace($FailedCommand)) {
    Write-Warning "Failed command: $FailedCommand"
  }
  Write-Host "Collecting a sanitized local status snapshot. API keys and wxautox4 license values are not printed by these scripts."
  Write-Host "If Bridge startup is involved, also check logs\aipet-bridge-console.log."

  Invoke-BestEffortPowerShell `
    -Label "AI Pet WeChat status" `
    -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "wxauto-openclaw-status.ps1"),
      "-BridgeUrl",
      $BridgeUrl
    )

  $auditArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "audit-ai-pet-wechat-full-readiness.ps1"),
    "-BridgeUrl",
    $BridgeUrl
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $auditArgs += @("-TargetName", $TargetName)
  }
  Invoke-BestEffortPowerShell `
    -Label "AI Pet WeChat readiness audit" `
    -Arguments $auditArgs

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
    "-SkipSelfTest"
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $doctorArgs += @("-TargetName", $TargetName)
  }

  Invoke-BestEffortPowerShell `
    -Label "AI Pet WeChat doctor snapshot" `
    -Arguments $doctorArgs

  $exportArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "export-aipet-wechat-diagnostics.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $exportArgs += @("-TargetName", $TargetName)
  }
  Invoke-BestEffortPowerShell `
    -Label "AI Pet WeChat diagnostics export" `
    -Arguments $exportArgs
}

function New-CommandPlan {
  $commands = New-Object System.Collections.Generic.List[object]

  $commands.Add((New-PlanCommand -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1"),
    "-OnlyClearStaleLock"
  ))) | Out-Null

  if (-not $SkipActivation) {
    $commands.Add((New-PlanCommand -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "activate-wxautox4.ps1")
    ))) | Out-Null
  }

  $verifyArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "verify-ai-pet-wechat-full.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId,
    "-TimeoutSeconds",
    ([string]$TimeoutSeconds),
    "-PrivateRateLimitMinutes",
    ([string]$PrivateRateLimitMinutes),
    "-RestartStack"
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $verifyArgs += @("-TargetName", $TargetName)
  }
  if ($Mode -eq "temporary-private-auto") {
    $verifyArgs += "-TemporaryPrivateAuto"
  }
  $commands.Add((New-PlanCommand -Arguments $verifyArgs)) | Out-Null

  return @($commands.ToArray())
}

$planCommands = New-CommandPlan

if (-not $Execute) {
  Write-Host "AI Pet full WeChat repair-and-verify plan."
  Write-Host "No command was executed. Re-run with -Execute on the desktop PowerShell session to apply it."
  Write-Host ""
  [pscustomobject]@{
    mode = $Mode
    execute = $false
    skip_activation = [bool]$SkipActivation
    failure_diagnostics = (-not [bool]$SkipFailureDiagnostics)
    command_count = $planCommands.Count
    commands = $planCommands
  } | ConvertTo-Json -Depth 8
  return
}

Write-Host "== AI Pet Full WeChat Repair And Verify =="
Write-Host "Mode: $Mode"
Write-Host "Bridge: $BridgeUrl"
Write-Host "Pet: $PetId"
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  Write-Host "Target: $TargetName"
}
Write-Host "Skip activation: $SkipActivation"
Write-Host "Failure diagnostics: $(-not [bool]$SkipFailureDiagnostics)"
Write-Host ""

$failedCommand = ""
try {
  foreach ($command in $planCommands) {
    $args = @($command.arguments)
    $failedCommand = "powershell $($args -join ' ')"
    Write-Host "Running: $failedCommand"
    Invoke-ChildPowerShell `
      -Arguments $args `
      -FailureMessage "Repair-and-verify command failed: $($args -join ' ')"
  }
} catch {
  Write-Warning $_.Exception.Message
  if (-not $SkipFailureDiagnostics) {
    Write-FailureDiagnostics -FailedCommand $failedCommand
  }
  throw
}

Write-Host ""
Write-Host "AI Pet full WeChat repair-and-verify flow finished."
