param(
  [string]$ChannelRoot = "",
  [switch]$Visible
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($ChannelRoot)) {
  $ChannelRoot = Join-Path $ProjectRoot ".cache\openclaw-wechat-channel"
}

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
$WxautoxHome = $WxautoEnv.WxautoxHome
$ApiRoot = Join-Path $ChannelRoot "wxauto-restful-api"
$WxChannelRoot = Join-Path $ChannelRoot "wxauto-channel"

if (-not (Test-Path -LiteralPath $VenvPython)) {
  throw "Python venv not found. Run scripts\setup-dev.ps1 first."
}
if (-not (Test-Path -LiteralPath (Join-Path $ApiRoot "config.yaml"))) {
  throw "wxauto API config not found. Run scripts\configure-wxauto-openclaw-channel.ps1 first."
}
if (-not (Test-Path -LiteralPath (Join-Path $WxChannelRoot "config.yaml"))) {
  throw "wxauto channel config not found. Run scripts\configure-wxauto-openclaw-channel.ps1 first."
}
New-Item -ItemType Directory -Force -Path $WxautoxHome | Out-Null

powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-wxauto-openclaw-config.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "wxauto OpenClaw config validation failed."
}

$windowStyle = if ($Visible) { "Normal" } else { "Hidden" }

function ConvertTo-EncodedCommand {
  param([string]$Command)
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

$apiCommand = @"
`$host.UI.RawUI.WindowTitle = 'AI Pet wxauto API'
`$env:USERPROFILE = '$(($WxautoxHome).Replace("'", "''"))'
`$env:HOME = '$(($WxautoxHome).Replace("'", "''"))'
Set-Location -LiteralPath '$ApiRoot'
& '$VenvPython' '.\run.py'
"@

$channelCommand = @"
`$host.UI.RawUI.WindowTitle = 'AI Pet wxauto Channel'
`$env:USERPROFILE = '$(($WxautoxHome).Replace("'", "''"))'
`$env:HOME = '$(($WxautoxHome).Replace("'", "''"))'
Set-Location -LiteralPath '$WxChannelRoot'
& '$VenvPython' '.\wxauto_channel.py'
"@

$apiEncodedCommand = ConvertTo-EncodedCommand $apiCommand
$channelEncodedCommand = ConvertTo-EncodedCommand $channelCommand

function Start-EncodedPowerShellWindow {
  param(
    [string]$Title,
    [string]$EncodedCommand
  )

  try {
    Start-Process powershell -WindowStyle $windowStyle -ArgumentList @(
      "-NoExit",
      "-ExecutionPolicy",
      "Bypass",
      "-EncodedCommand",
      $EncodedCommand
    )
  } catch {
    $mode = if ($Visible) { "" } else { "/min" }
    cmd /c start "$Title" $mode powershell -NoExit -ExecutionPolicy Bypass -EncodedCommand $EncodedCommand
  }
}

Start-EncodedPowerShellWindow -Title "AI Pet wxauto API" -EncodedCommand $apiEncodedCommand

Start-Sleep -Seconds 2

Start-EncodedPowerShellWindow -Title "AI Pet wxauto Channel" -EncodedCommand $channelEncodedCommand

Write-Host "Started wxauto API and wxauto channel."
Write-Host "Window style: $windowStyle"
Write-Host "API docs: http://127.0.0.1:8001/docs"
Write-Host "Use -Visible for first-run debugging."
