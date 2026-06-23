param(
  [int]$Port = 8787
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $VenvPython)) {
  throw "Python virtual environment not found. Run scripts\setup-dev.ps1 -Install first."
}

$env:PYTHONPATH = Join-Path $ProjectRoot "src"
Set-Location $ProjectRoot
& $VenvPython -m uvicorn aipet_bridge.app:app --host 127.0.0.1 --port $Port --reload
