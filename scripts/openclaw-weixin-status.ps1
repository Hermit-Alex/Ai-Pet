param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawEntry = Join-Path $OpenClawEnv.ProjectRoot ".cache\npm-prefix\node_modules\openclaw\openclaw.mjs"

function Invoke-OpenClaw {
  & node $OpenClawEntry @args
}

Write-Host "== Weixin plugin config =="
Invoke-OpenClaw config get plugins.entries.openclaw-weixin --json

Write-Host ""
Write-Host "== Channels =="
Invoke-OpenClaw channels list

Write-Host ""
Write-Host "== Agents =="
Invoke-OpenClaw agents list --bindings

Write-Host ""
Write-Host "== Family chat session config =="
Invoke-OpenClaw config get session --json

Write-Host ""
Write-Host "== Family chat tool policy =="
Invoke-OpenClaw config get tools --json

Write-Host ""
Write-Host "Pending pairing check:"
Write-Host "  node `"$OpenClawEntry`" pairing list openclaw-weixin --json"
