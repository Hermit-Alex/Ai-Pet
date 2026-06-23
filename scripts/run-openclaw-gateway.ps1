param(
  [int]$Port = 18789
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$OpenClawPrefix = Join-Path $ProjectRoot ".cache\npm-prefix"
$OpenClawCmd = Join-Path $OpenClawPrefix "openclaw.cmd"
$OpenClawState = Join-Path $ProjectRoot ".openclaw"
$OpenClawConfig = Join-Path $OpenClawState "openclaw.json"

if (-not (Test-Path -LiteralPath $OpenClawCmd)) {
  throw "OpenClaw is not installed. Run npm.cmd install -g openclaw@latest with the project npm prefix first."
}

New-Item -ItemType Directory -Force -Path $OpenClawState | Out-Null

$env:PATH = "$OpenClawPrefix;$env:PATH"
$env:OPENCLAW_STATE_DIR = $OpenClawState
$env:OPENCLAW_CONFIG_PATH = $OpenClawConfig

Set-Location $ProjectRoot
& $OpenClawCmd gateway run --force --port $Port --bind loopback --compact
