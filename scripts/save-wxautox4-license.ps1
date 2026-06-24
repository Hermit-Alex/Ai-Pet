param(
  [Parameter(Mandatory = $true)]
  [string]$LicenseKey
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvPath = Join-Path $ProjectRoot ".env.local"

if (-not (Test-Path -LiteralPath $EnvPath)) {
  if (Test-Path -LiteralPath (Join-Path $ProjectRoot ".env.example")) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot ".env.example") -Destination $EnvPath
  } else {
    New-Item -ItemType File -Path $EnvPath | Out-Null
  }
}

$lines = @(Get-Content -LiteralPath $EnvPath -ErrorAction SilentlyContinue)
$updated = $false
$next = foreach ($line in $lines) {
  if ([string]$line -match "^\s*AIPET_WXAUTOX4_LICENSE_KEY\s*=") {
    $updated = $true
    "AIPET_WXAUTOX4_LICENSE_KEY=$LicenseKey"
  } else {
    $line
  }
}

if (-not $updated) {
  $next += ""
  $next += "# Local wxautox4 Plus activation code. Never commit .env.local."
  $next += "AIPET_WXAUTOX4_LICENSE_KEY=$LicenseKey"
}

Set-Content -LiteralPath $EnvPath -Value $next -Encoding UTF8

Write-Host "Saved wxautox4 activation code to local .env.local."
Write-Host "The value was not printed. .env.local is ignored by Git."
