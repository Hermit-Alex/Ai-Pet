param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

Write-Host "== Plugins =="
& $OpenClawCmd plugins list

Write-Host ""
Write-Host "== Channels =="
& $OpenClawCmd channels list --all

Write-Host ""
Write-Host "== Agents =="
& $OpenClawCmd agents list --bindings

Write-Host ""
Write-Host "== Pending Weixin pairings =="
& $OpenClawCmd pairing list openclaw-weixin
