param(
  [string]$MyNickname = "",
  [string[]]$PrivateChat = @(),
  [string[]]$GroupChat = @(),
  [ValidateSet("at_me_only", "all")]
  [string]$GroupReplyMode = "at_me_only",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$LicenseKey = "",
  [switch]$FromBridge,
  [switch]$InstallDeps,
  [switch]$Activate,
  [switch]$SyncPersona,
  [switch]$StartBridge,
  [switch]$StartGateway,
  [switch]$StartWxauto,
  [switch]$AutoActivate,
  [switch]$RestartBridge,
  [switch]$RestartGateway,
  [switch]$RestartWxauto,
  [switch]$RestartStack,
  [switch]$SkipWeixinProcessCheck,
  [switch]$Visible,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LogsDir = Join-Path $ProjectRoot "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

if (-not $InstallDeps) {
  Write-Host "Skipping dependency install. Add -InstallDeps for first-time setup."
}

function Invoke-ChildPowerShell {
  param(
    [string[]]$Arguments,
    [string]$FailureMessage
  )

  & powershell @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw $FailureMessage
  }
}

if ($RestartStack) {
  $RestartBridge = $true
  $RestartGateway = $true
  $RestartWxauto = $true
}

if ($RestartBridge -or $RestartGateway -or $RestartWxauto) {
  $stopArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1")
  )
  if ($RestartBridge) {
    $stopArgs += "-StopBridge"
  }
  if ($RestartGateway) {
    $stopArgs += "-StopGateway"
  }
  if (-not $RestartWxauto) {
    $stopArgs += "-SkipWxauto"
  }
  Write-Host "Restart requested. Stopping selected AI Pet WeChat services first..."
  Invoke-ChildPowerShell -Arguments $stopArgs -FailureMessage "Failed to stop existing AI Pet WeChat services."

  if ($RestartBridge) {
    $StartBridge = $true
  }
  if ($RestartGateway) {
    $StartGateway = $true
  }
  if ($RestartWxauto) {
    $StartWxauto = $true
  }
}

$setupWxautoArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $PSScriptRoot "setup-wxauto-openclaw-channel.ps1")
)
if ($InstallDeps) {
  $setupWxautoArgs += "-InstallDeps"
}
Invoke-ChildPowerShell -Arguments $setupWxautoArgs -FailureMessage "wxauto channel setup failed."

if (-not [string]::IsNullOrWhiteSpace($LicenseKey)) {
  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "save-wxautox4-license.ps1"),
    "-LicenseKey",
    $LicenseKey
  ) -FailureMessage "wxautox4 license save failed."
}

if ($Activate) {
  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "activate-wxautox4.ps1")
  ) -FailureMessage "wxautox4 activation failed."
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

function Get-BridgeHealth {
  param([string]$Url)
  try {
    return Invoke-RestMethod -Method Get -Uri "$($Url.TrimEnd('/'))/health" -TimeoutSec 5
  } catch {
    return $null
  }
}

function Test-BridgePolicyReady {
  param([object]$Health)
  return $Health -and [bool]$Health.wechat_private_manual_review_enforced
}

function Assert-BridgePolicyReady {
  param(
    [string]$Url,
    [string]$Context
  )

  $health = Get-BridgeHealth -Url $Url
  if (-not (Test-BridgePolicyReady -Health $health)) {
    throw "AI Pet Bridge is not stable with the current WeChat safety policy after ${Context}. Check logs\aipet-bridge-console.log and restart it."
  }
}

function Wait-HttpOk {
  param(
    [string]$Name,
    [string]$Url,
    [int]$TimeoutSeconds = 30
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

function Start-EncodedPowerShellWindow {
  param(
    [string]$Title,
    [string]$Command,
    [switch]$VisibleWindow
  )

  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
  $windowStyle = if ($VisibleWindow) { "Normal" } else { "Hidden" }
  try {
    Start-Process powershell -WindowStyle $windowStyle -ArgumentList @(
      "-NoExit",
      "-ExecutionPolicy",
      "Bypass",
      "-EncodedCommand",
      $encodedCommand
    )
  } catch {
    $mode = if ($VisibleWindow) { "" } else { "/min" }
    cmd /c start "$Title" $mode powershell -NoExit -ExecutionPolicy Bypass -EncodedCommand $encodedCommand
  }
}

if ($StartBridge) {
  $bridgeHealthUrl = $BridgeUrl.TrimEnd("/") + "/health"
  $bridgeHealth = Get-BridgeHealth -Url $BridgeUrl
  if ($bridgeHealth -and -not (Test-BridgePolicyReady -Health $bridgeHealth)) {
    Write-Warning "AI Pet Bridge is running but does not expose the current WeChat policy version. Restarting Bridge..."
    Invoke-ChildPowerShell -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1"),
      "-StopBridge",
      "-SkipWxauto"
    ) -FailureMessage "Failed to stop outdated AI Pet Bridge."
    $bridgeHealth = $null
  }

  if ($bridgeHealth -and $bridgeHealth.status -eq "ok") {
    Write-Host "AI Pet Bridge already running with current WeChat policy: $BridgeUrl"
  } else {
    $bridgeLogPath = Join-Path $LogsDir "aipet-bridge-console.log"
    $bridgeCommand = @"
Set-Location -LiteralPath '$($ProjectRoot.Replace("'", "''"))'
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\run-bridge.ps1' -NoReload *> '$($bridgeLogPath.Replace("'", "''"))'
"@
    Start-EncodedPowerShellWindow -Title "AI Pet Bridge" -Command $bridgeCommand -VisibleWindow:$Visible
    for ($attempt = 1; $attempt -le 15; $attempt++) {
      Start-Sleep -Seconds 1
      if (Test-HttpOk $bridgeHealthUrl) {
        Write-Host "AI Pet Bridge started: $BridgeUrl"
        break
      }
    }
  }

  $bridgeHealth = Get-BridgeHealth -Url $BridgeUrl
  if (-not $bridgeHealth) {
    if ($FromBridge) {
      throw "AI Pet Bridge is not reachable at $BridgeUrl, cannot read settings with -FromBridge."
    }
    Write-Warning "AI Pet Bridge is not reachable at $BridgeUrl."
  } elseif (-not (Test-BridgePolicyReady -Health $bridgeHealth)) {
    throw "AI Pet Bridge at $BridgeUrl is reachable but not running the current WeChat safety policy. Restart it before continuing."
  }

  Start-Sleep -Seconds 2
  Assert-BridgePolicyReady -Url $BridgeUrl -Context "startup stability check"
}

$configureArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  (Join-Path $PSScriptRoot "configure-wxauto-openclaw-channel.ps1"),
  "-GroupReplyMode",
  $GroupReplyMode,
  "-BridgeUrl",
  $BridgeUrl,
  "-PetId",
  $PetId
)

$shouldConfigureWxauto = (
  $FromBridge -or
  $StartWxauto -or
  -not [string]::IsNullOrWhiteSpace($MyNickname) -or
  $PrivateChat.Count -gt 0 -or
  $GroupChat.Count -gt 0
)

if ($shouldConfigureWxauto) {
  if ($FromBridge) {
    $configureArgs += "-FromBridge"
  }
  if (-not [string]::IsNullOrWhiteSpace($MyNickname)) {
    $configureArgs += "-MyNickname"
    $configureArgs += $MyNickname
  }
  if ($PrivateChat.Count -gt 0) {
    $configureArgs += "-PrivateChat"
    $configureArgs += $PrivateChat
  }
  if ($GroupChat.Count -gt 0) {
    $configureArgs += "-GroupChat"
    $configureArgs += $GroupChat
  }

  Invoke-ChildPowerShell -Arguments $configureArgs -FailureMessage "wxauto channel configuration failed."
} else {
  Write-Host "Skipping wxauto channel configuration. Pass -FromBridge, -MyNickname, -PrivateChat, -GroupChat, or -StartWxauto when configuration is needed."
}

if ($SyncPersona) {
  Invoke-ChildPowerShell -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "sync-openclaw-pet-persona.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  ) -FailureMessage "OpenClaw persona sync failed."
}

if ($StartGateway) {
  $gatewayHealthUrl = "http://127.0.0.1:18789/health"
  if (Test-HttpOk $gatewayHealthUrl) {
    Write-Host "OpenClaw Gateway already running: $gatewayHealthUrl"
  } else {
  $gatewayCommand = @"
Set-Location -LiteralPath '$((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)'
powershell -NoProfile -ExecutionPolicy Bypass -File '.\scripts\run-openclaw-gateway.ps1'
"@
    Start-EncodedPowerShellWindow -Title "AI Pet OpenClaw Gateway" -Command $gatewayCommand -VisibleWindow:$Visible
    if (-not (Wait-HttpOk -Name "OpenClaw Gateway" -Url $gatewayHealthUrl -TimeoutSeconds 30)) {
      throw "OpenClaw Gateway did not become healthy. Check the OpenClaw gateway window."
    }
  }
}

if ($StartWxauto) {
  $startWxautoArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "start-aipet-wxauto-bridge-channel.ps1"),
    "-BridgeUrl",
    $BridgeUrl,
    "-PetId",
    $PetId
  )
  if ($Visible) {
    $startWxautoArgs += "-Visible"
  }
  if ($DryRun) {
    $startWxautoArgs += "-DryRun"
  }
  if ($AutoActivate) {
    $startWxautoArgs += "-AutoActivate"
  }
  if ($SkipWeixinProcessCheck) {
    $startWxautoArgs += "-SkipWeixinProcessCheck"
  }
  Invoke-ChildPowerShell -Arguments $startWxautoArgs -FailureMessage "AI Pet wxauto Bridge channel start failed."
}

Write-Host "AI Pet full WeChat channel setup finished."
Write-Host ""
Write-Host "Useful checks:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1 -CheckOnly"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\wxauto-openclaw-status.ps1"
