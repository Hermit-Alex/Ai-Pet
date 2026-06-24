param(
  [ValidateSet("project", "default")]
  [string]$Mode = "project",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvPath = Join-Path $ProjectRoot ".env.local"

function Set-EnvValue {
  param(
    [string]$Path,
    [string]$Name,
    [string]$Value
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot ".env.example")) {
      Copy-Item -LiteralPath (Join-Path $ProjectRoot ".env.example") -Destination $Path
    } else {
      New-Item -ItemType File -Path $Path | Out-Null
    }
  }

  $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
  $updated = $false
  $next = foreach ($line in $lines) {
    if ([string]$line -match "^\s*$([regex]::Escape($Name))\s*=") {
      $updated = $true
      "$Name=$Value"
    } else {
      $line
    }
  }
  if (-not $updated) {
    $next += ""
    $next += "$Name=$Value"
  }
  Set-Content -LiteralPath $Path -Value $next -Encoding UTF8
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

function Test-Mode {
  param([string]$ModeToCheck)
  try {
    $output = powershell -NoProfile -ExecutionPolicy Bypass -File `
      (Join-Path $PSScriptRoot "activate-wxautox4.ps1") `
      -CheckOnly `
      -HomeMode $ModeToCheck
    $text = $output -join " "
    $activated = Test-ActivationOutput -Text $text
    $homeLine = (($output | Where-Object { [string]$_ -like "wxautox home:*" }) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($homeLine)) {
      $homeLine = "wxautox home: <unknown>"
    }
    [pscustomobject]@{
      Mode = $ModeToCheck
      Activated = [bool]$activated
      Detail = $homeLine
    }
  } catch {
    [pscustomobject]@{
      Mode = $ModeToCheck
      Activated = $false
      Detail = $_.Exception.Message
    }
  }
}

if ($CheckOnly) {
  Write-Host "wxautox4 home mode check:"
  foreach ($item in @((Test-Mode -ModeToCheck "project"), (Test-Mode -ModeToCheck "default"))) {
    $status = if ($item.Activated) { "activated" } else { "not_activated" }
    Write-Host "  $($item.Mode): $status - $($item.Detail)"
  }
  return
}

$value = if ($Mode -eq "default") { "default" } else { ".cache/wxautox-home" }
Set-EnvValue -Path $EnvPath -Name "AIPET_WXAUTOX_HOME" -Value $value

Write-Host "Set AIPET_WXAUTOX_HOME=$value in .env.local"
Write-Host "Run this to verify:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor-ai-pet-wechat-full.ps1 -SkipSelfTest"
