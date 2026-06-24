param(
  [string]$ChannelRoot = "",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [int]$WaitSeconds = 30,
  [switch]$AutoActivate,
  [switch]$SkipActivationCheck,
  [switch]$SkipRuntimeContractCheck,
  [switch]$SkipWeixinProcessCheck,
  [switch]$Visible,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot
if ([string]::IsNullOrWhiteSpace($ChannelRoot)) {
  $ChannelRoot = $WxautoEnv.ChannelRoot
}

$VenvPython = $WxautoEnv.VenvPython
$WxautoxHome = $WxautoEnv.WxautoxHome
$LogsDir = $WxautoEnv.LogsDir
$ApiRoot = Join-Path $ChannelRoot "wxauto-restful-api"
$WxChannelRoot = Join-Path $ChannelRoot "wxauto-channel"
$ChannelConfigPath = Join-Path $WxChannelRoot "config.yaml"

if (-not (Test-Path -LiteralPath $VenvPython)) {
  throw "Python venv not found. Run scripts\setup-dev.ps1 first."
}
if (-not (Test-Path -LiteralPath (Join-Path $ApiRoot "config.yaml"))) {
  throw "wxauto API config not found. Run scripts\configure-wxauto-openclaw-channel.ps1 first."
}
if (-not (Test-Path -LiteralPath $ChannelConfigPath)) {
  throw "wxauto channel config not found. Run scripts\configure-wxauto-openclaw-channel.ps1 first."
}
New-Item -ItemType Directory -Force -Path $WxautoxHome, $LogsDir | Out-Null

if (-not $SkipWeixinProcessCheck) {
  $weixinProcesses = @(
    Get-Process Weixin, WeChat -ErrorAction SilentlyContinue
  )
  if ($weixinProcesses.Count -eq 0) {
    throw "Windows WeChat desktop is not running. Open and log in the real pet WeChat account before starting wxauto. Use -SkipWeixinProcessCheck only for API-level debugging."
  }
  Write-Host "Windows WeChat desktop process detected: count=$($weixinProcesses.Count)"
}

powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-wxauto-openclaw-config.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "wxauto config validation failed."
}

try {
  $bridgeHealth = Invoke-RestMethod -Method Get -Uri ($BridgeUrl.TrimEnd("/") + "/health") -TimeoutSec 3
  if (-not [bool]$bridgeHealth.wechat_private_manual_review_enforced) {
    throw "AI Pet Bridge is reachable but does not expose the current WeChat safety policy. Restart scripts\run-bridge.ps1 or use scripts\restart-ai-pet-wechat-full.cmd."
  }
} catch {
  throw "AI Pet Bridge is not ready at ${BridgeUrl}: $($_.Exception.Message)"
}

$windowStyle = if ($Visible) { "Normal" } else { "Hidden" }

function ConvertTo-EncodedCommand {
  param([string]$Command)
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function ConvertTo-PowerShellLiteral {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return "''"
  }
  return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Test-HttpOk {
  param([string]$Url)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
  } catch {
    return $false
  }
}

function Wait-HttpOk {
  param(
    [string]$Name,
    [string]$Url,
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-HttpOk $Url) {
      Write-Host "$Name is ready: $Url"
      return $true
    }
    Start-Sleep -Seconds 1
  }
  Write-Warning "$Name did not become ready within $TimeoutSeconds seconds: $Url"
  return $false
}

function Test-WxautoxActivated {
  param([string]$WxApiBaseUrl)
  try {
    $status = Invoke-RestMethod -Method Get -Uri "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check" -TimeoutSec 5
    return [bool]$status.data.activated
  } catch {
    Write-Warning "Could not query wxautox4 activation endpoint: $($_.Exception.Message)"
    return $false
  }
}

function Invoke-WxautoxActivationViaApi {
  param([string]$WxApiBaseUrl)
  $licenseKey = [string]$WxautoEnv.LicenseKey
  if ([string]::IsNullOrWhiteSpace($licenseKey)) {
    Write-Warning "AutoActivate requested but no wxautox4 license key is configured in .env.local."
    return $false
  }

  try {
    $payload = @{ license_key = $licenseKey } | ConvertTo-Json -Depth 4
    $result = Invoke-RestMethod `
      -Method Post `
      -Uri "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/activate" `
      -ContentType "application/json" `
      -Body $payload `
      -TimeoutSec 60
    if ($result.success -eq $true -or $result.data.activated -eq $true) {
      Write-Host "wxautox4 activation via local API succeeded."
      return $true
    }
    Write-Warning "wxautox4 activation via local API did not succeed: $($result.message)"
    return $false
  } catch {
    Write-Warning "wxautox4 activation via local API failed: $($_.Exception.Message)"
    return $false
  }
}

$apiCommand = @"
`$host.UI.RawUI.WindowTitle = 'AI Pet wxauto API'
`$env:USERPROFILE = '$(($WxautoxHome).Replace("'", "''"))'
`$env:HOME = '$(($WxautoxHome).Replace("'", "''"))'
Set-Location -LiteralPath '$(($ApiRoot).Replace("'", "''"))'
& '$(($VenvPython).Replace("'", "''"))' '.\run.py'
"@

$channelArgs = @(
  "--config",
  $ChannelConfigPath,
  "--bridge-url",
  $BridgeUrl,
  "--pet-id",
  $PetId,
  "--log-file",
  (Join-Path $LogsDir "aipet-wxauto-bridge-channel.log"),
  "--lock-file",
  $WxautoEnv.WxautoBridgeChannelLockPath
)
if ($DryRun) {
  $channelArgs += "--dry-run"
}
$channelArgLine = ($channelArgs | ForEach-Object { ConvertTo-PowerShellLiteral ([string]$_) }) -join " "

$channelCommand = @"
`$host.UI.RawUI.WindowTitle = 'AI Pet wxauto Bridge Channel'
`$env:USERPROFILE = '$(($WxautoxHome).Replace("'", "''"))'
`$env:HOME = '$(($WxautoxHome).Replace("'", "''"))'
Set-Location -LiteralPath '$(($ProjectRoot).Replace("'", "''"))'
`$env:PYTHONPATH = '$(Join-Path $ProjectRoot "src")'
& '$(($VenvPython).Replace("'", "''"))' -m aipet_wxauto_bridge_channel.cli $channelArgLine
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

function Stop-WxautoStartupFailClosed {
  param([string]$Reason)

  Write-Warning "$Reason"
  Write-Warning "Stopping wxauto API/channel startup as a fail-closed fallback."
  powershell -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1")
}

$wxApiBaseUrl = "http://127.0.0.1:8001"
$startupSucceeded = $false
try {
  Start-EncodedPowerShellWindow -Title "AI Pet wxauto API" -EncodedCommand $apiEncodedCommand

  if (-not (Wait-HttpOk -Name "wxauto API" -Url "$wxApiBaseUrl/" -TimeoutSeconds $WaitSeconds)) {
    throw "wxauto API did not start. Check $(Join-Path $ApiRoot 'wxauto_api.log')."
  }

  if (-not $SkipActivationCheck) {
    $activated = Test-WxautoxActivated -WxApiBaseUrl $wxApiBaseUrl
    if (-not $activated -and $AutoActivate) {
      Write-Host "wxautox4 is not activated under $WxautoxHome. Trying local API activation..."
      $activated = Invoke-WxautoxActivationViaApi -WxApiBaseUrl $wxApiBaseUrl
      if ($activated) {
        $activated = Test-WxautoxActivated -WxApiBaseUrl $wxApiBaseUrl
      }
    }

    if (-not $activated) {
      throw "wxautox4 is not activated under $WxautoxHome. Run scripts\activate-wxautox4.ps1 in desktop PowerShell, then start again."
    }
  }

  if (-not $SkipRuntimeContractCheck) {
    powershell -NoProfile -ExecutionPolicy Bypass -File `
      (Join-Path $PSScriptRoot "test-wxauto-runtime-contract.ps1") `
      -WxApiBaseUrl $wxApiBaseUrl `
      -ConfigPath $ChannelConfigPath `
      -TimeoutSeconds 5 `
      -Strict
    if ($LASTEXITCODE -ne 0) {
      throw "wxauto runtime contract check failed. Fix the wxauto API/runtime state before starting the channel."
    }
  }

  Start-EncodedPowerShellWindow -Title "AI Pet wxauto Bridge Channel" -EncodedCommand $channelEncodedCommand
  $startupSucceeded = $true
} catch {
  if (-not $startupSucceeded) {
    Stop-WxautoStartupFailClosed -Reason $_.Exception.Message
  }
  throw
}

Write-Host "Started wxauto API and AI Pet wxauto Bridge channel."
Write-Host "Window style: $windowStyle"
Write-Host "API docs: http://127.0.0.1:8001/docs"
Write-Host "Bridge URL: $BridgeUrl"
Write-Host "Dry run: $DryRun"
Write-Host "Auto activate: $AutoActivate"
