param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawEntry = Join-Path $OpenClawEnv.ProjectRoot ".cache\npm-prefix\node_modules\openclaw\openclaw.mjs"

& node $OpenClawEntry pairing list feishu --json
