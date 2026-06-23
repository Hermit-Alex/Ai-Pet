param(
  [Parameter(Mandatory = $true)]
  [string]$Code
)

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

& $OpenClawCmd pairing approve feishu $Code
