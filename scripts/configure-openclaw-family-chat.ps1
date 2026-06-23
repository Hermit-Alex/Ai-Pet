param()

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$OpenClawCmd = $OpenClawEnv.OpenClawCmd

$patch = @'
{
  session: {
    dmScope: "per-account-channel-peer",
  },
  channels: {
    "openclaw-weixin": {
      dmPolicy: "pairing",
    },
  },
  tools: {
    profile: "minimal",
    deny: [
      "group:fs",
      "group:runtime",
      "group:web",
      "group:ui",
      "group:automation",
      "group:messaging",
      "group:nodes",
      "group:agents",
      "group:media",
      "group:plugins",
      "group:sessions",
    ],
    elevated: {
      enabled: false,
    },
  },
}
'@

$patch | & $OpenClawCmd config patch --stdin
if ($LASTEXITCODE -ne 0) {
  throw "Failed to apply OpenClaw family chat safety config."
}

& $OpenClawCmd config validate
if ($LASTEXITCODE -ne 0) {
  throw "OpenClaw config validation failed."
}

Write-Host "OpenClaw family chat safety config applied."
Write-Host ""
Write-Host "Effective session config:"
& $OpenClawCmd config get session --json
Write-Host ""
Write-Host "Effective tools config:"
& $OpenClawCmd config get tools --json
Write-Host ""
Write-Host "Restart the OpenClaw Gateway for tool-policy changes to take effect."
