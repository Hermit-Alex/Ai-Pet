param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawEntry = Join-Path $OpenClawEnv.ProjectRoot ".cache\npm-prefix\node_modules\openclaw\openclaw.mjs"

function Invoke-OpenClaw {
  & node $OpenClawEntry @args
}

Write-Host "== Feishu plugin config =="
Invoke-OpenClaw config get plugins.entries.feishu --json

Write-Host ""
Write-Host "== Feishu channel config =="
Invoke-OpenClaw config get channels.feishu --json

Write-Host ""
Write-Host "== Channels =="
Invoke-OpenClaw channels list

Write-Host ""
Write-Host "== Agents =="
Invoke-OpenClaw agents list --bindings

Write-Host ""
Write-Host "== Family chat tool policy =="
Invoke-OpenClaw config get tools --json

Write-Host ""
Write-Host "Pending pairing check:"
Write-Host "  node `"$OpenClawEntry`" pairing list feishu --json"
