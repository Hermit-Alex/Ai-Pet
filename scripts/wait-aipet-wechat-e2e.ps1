param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 180,
  [int]$PollSeconds = 5,
  [switch]$FullE2E,
  [switch]$Strict
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

if ($PollSeconds -lt 1) {
  $PollSeconds = 1
}

$afterUtc = [DateTimeOffset]::UtcNow.AddSeconds(-2).ToString("o")
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$assertScript = Join-Path $PSScriptRoot "assert-aipet-wechat-e2e.ps1"

Write-Host "== AI Pet WeChat Live E2E Wait =="
Write-Host "Started at UTC: $afterUtc"
Write-Host "Timeout: $TimeoutSeconds seconds"
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  Write-Host "Target: $TargetName"
}
if ($FullE2E) {
  Write-Host "Mode: full E2E, requires OpenClaw + real WeChat send"
} else {
  Write-Host "Mode: observe/dry-run friendly"
}
Write-Host ""
Write-Host "Now send a new message from an allowlisted WeChat contact."
Write-Host "Waiting for a new AI Pet WeChat trace..."
Write-Host ""

$seenTrace = $false
$lastAssertionText = ""
$lastAssertionExitCode = 0

while ((Get-Date) -lt $deadline) {
  $args = @(
    "-BridgeUrl",
    $BridgeUrl,
    "-AfterUtc",
    $afterUtc
  )
  if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
    $args += @("-TargetName", $TargetName)
  }
  if ($FullE2E) {
    $args += @("-RequireOpenClaw", "-RequireRealSend", "-Strict")
  } else {
    $args += @("-AllowDryRun", "-Strict")
  }

  $output = powershell -NoProfile -ExecutionPolicy Bypass -File $assertScript @args
  $exitCode = $LASTEXITCODE
  $text = ($output | ForEach-Object { [string]$_ }) -join "`n"

  if ($text -notmatch "result:\s+NO_TRACE") {
    if ($exitCode -eq 0) {
      Write-Host $text
      Write-Host ""
      Write-Host "LIVE E2E WAIT: OK"
      exit 0
    }
    if (-not $seenTrace) {
      Write-Host "Trace found; waiting for Bridge/OpenClaw/wxauto completion..."
      Write-Host ""
    }
    $seenTrace = $true
    $lastAssertionText = $text
    $lastAssertionExitCode = $exitCode
  }

  Start-Sleep -Seconds $PollSeconds
}

Write-Host "LIVE E2E WAIT: TIMEOUT"
if ($seenTrace) {
  Write-Host "A new trace was found after $afterUtc, but it never satisfied the requested assertion before timeout."
  Write-Host ""
  Write-Host $lastAssertionText
  Write-Host ""
  Write-Host "last_assertion_exit_code: $lastAssertionExitCode"
} else {
  Write-Host "No new AI Pet WeChat trace was found after $afterUtc."
  Write-Host "Check wxauto API, channel window, allowlist, exact contact/group name, and WeChat desktop visibility."
}
if ($Strict) {
  exit 1
}
