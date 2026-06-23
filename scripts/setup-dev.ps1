param(
  [switch]$Install
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$VenvPath = Join-Path $ProjectRoot ".venv"
$CachePath = Join-Path $ProjectRoot ".cache\pip"
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"

New-Item -ItemType Directory -Force -Path $CachePath | Out-Null
$env:PIP_CACHE_DIR = $CachePath
$env:PIP_USER = "false"

if (-not (Test-Path -LiteralPath $VenvPython)) {
  python -m venv $VenvPath
}

if ($Install) {
  & $VenvPython -m pip install --no-user --upgrade pip
  & $VenvPython -m pip install --no-user -e "$ProjectRoot[dev]"
}

Write-Host "Virtual environment: $VenvPath"
Write-Host "Pip cache: $CachePath"
Write-Host "Activate with: $VenvPath\Scripts\Activate.ps1"
