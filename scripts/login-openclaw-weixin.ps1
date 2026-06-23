param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

Write-Host "OpenClaw Weixin login will show a QR code in this terminal."
Write-Host "Scan it with the WeChat account that will bind the OpenClaw bot channel, then confirm on the phone."
Write-Host "Treat the QR code as a login secret; do not share it."
Write-Host ""

& $OpenClawCmd channels login --channel openclaw-weixin --verbose
