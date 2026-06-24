param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TargetName = "",
  [string]$OutputPath = "",
  [int]$TailLines = 160,
  [switch]$IncludeOpenClawSelfTest
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot
$LogsDir = $WxautoEnv.LogsDir
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $LogsDir ("aipet-wechat-diagnostics-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Protect-DiagnosticText {
  param([AllowNull()][string]$Text)
  if ($null -eq $Text) {
    return ""
  }

  $safe = [string]$Text
  $safe = $safe -replace "sk-[A-Za-z0-9_-]{10,}", "sk-<redacted>"
  $safe = $safe -replace "(?i)(Authorization\s*:\s*Bearer\s+)[^\s""']+", '$1<redacted>'
  $safe = $safe -replace "(?im)(AIPET_WXAUTOX4_LICENSE_KEY\s*=\s*)[^\s#]+", '$1<redacted>'
  $safe = $safe -replace "(?im)((?:license[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|wxapi[_-]?token|authorization|token)\s*[:=]\s*)[""']?[^""'\s,}]+", '$1<redacted>'
  # wxautox4 activation codes and provider keys may not have a stable prefix.
  $safe = $safe -replace "\b[A-Za-z0-9_-]{40,}\b", "<redacted-long-token>"
  return $safe
}

function Add-Section {
  param(
    [System.Collections.Generic.List[string]]$Lines,
    [string]$Title,
    [AllowNull()][string]$Body
  )

  $Lines.Add("") | Out-Null
  $Lines.Add("## $Title") | Out-Null
  $Lines.Add((Protect-DiagnosticText -Text $Body)) | Out-Null
}

function Invoke-DiagnosticCommand {
  param(
    [string]$Label,
    [string[]]$Arguments
  )

  try {
    $output = & powershell @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    return @"
command: powershell $($Arguments -join ' ')
exit_code: $exitCode
$text
"@
  } catch {
    return @"
command: powershell $($Arguments -join ' ')
exit_code: 1
error: $($_.Exception.Message)
"@
  }
}

function Read-LogTail {
  param([string]$RelativePath)

  $path = Join-Path $ProjectRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    return "missing: $path"
  }

  try {
    $lines = Get-Content -LiteralPath $path -Tail $TailLines -Encoding UTF8 -ErrorAction Stop
    return (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  } catch {
    return "failed to read ${path}: $($_.Exception.Message)"
  }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("AI Pet WeChat Diagnostics") | Out-Null
$lines.Add("generated_at: $([DateTimeOffset]::Now.ToString('o'))") | Out-Null
$lines.Add("project_root: $ProjectRoot") | Out-Null
$lines.Add("bridge_url: $BridgeUrl") | Out-Null
$lines.Add("pet_id: $PetId") | Out-Null
if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
  $lines.Add("target_name: $TargetName") | Out-Null
}
$lines.Add("tail_lines: $TailLines") | Out-Null
$lines.Add("note: secrets, provider keys, authorization headers, wxapi tokens, and long activation-like tokens are redacted.") | Out-Null

Add-Section `
  -Lines $lines `
  -Title "Light Status" `
  -Body (Invoke-DiagnosticCommand -Label "status" -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "wxauto-openclaw-status.ps1"),
    "-BridgeUrl",
    $BridgeUrl
  ))

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
Add-Section `
  -Lines $lines `
  -Title "Doctor Snapshot" `
  -Body (Invoke-DiagnosticCommand -Label "doctor" -Arguments $doctorArgs)

Add-Section `
  -Lines $lines `
  -Title "Repair Plan" `
  -Body (Invoke-DiagnosticCommand -Label "repair-plan" -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "repair-and-verify-ai-pet-wechat-full.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId,
    "-TargetName",
    $TargetName
  ))

if ($IncludeOpenClawSelfTest) {
  Add-Section `
    -Lines $lines `
    -Title "OpenClaw Bridge Self-Test" `
    -Body (Invoke-DiagnosticCommand -Label "openclaw-self-test" -Arguments @(
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
    ))
} else {
  Add-Section `
    -Lines $lines `
    -Title "OpenClaw Bridge Self-Test" `
    -Body "skipped by default; re-run with -IncludeOpenClawSelfTest to probe Bridge -> OpenClaw without sending WeChat."
}

Add-Section `
  -Lines $lines `
  -Title "Git Status" `
  -Body ((git status --short 2>&1 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

$logFiles = @(
  "logs\wechat-sidecar.jsonl",
  "logs\aipet-bridge.jsonl",
  "logs\audit-events.jsonl",
  "logs\errors.jsonl",
  "logs\aipet-wxauto-bridge-channel.log",
  "logs\aipet-bridge-console.log"
)
foreach ($logFile in $logFiles) {
  Add-Section -Lines $lines -Title "Tail $logFile" -Body (Read-LogTail -RelativePath $logFile)
}

$outputText = ($lines | ForEach-Object { Protect-DiagnosticText -Text ([string]$_) }) -join [Environment]::NewLine
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
Set-Content -LiteralPath $resolvedOutput -Value $outputText -Encoding UTF8

Write-Host "AI Pet WeChat diagnostics exported:"
Write-Host "  $resolvedOutput"
