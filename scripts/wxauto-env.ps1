param(
  [string]$WxautoxHomeOverride = ""
)

$ErrorActionPreference = "Stop"

function Import-AipetDotEnv {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  Get-Content -LiteralPath $Path | ForEach-Object {
    $line = [string]$_
    if ([string]::IsNullOrWhiteSpace($line)) {
      return
    }
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) {
      return
    }

    $parts = $trimmed.Split("=", 2)
    $name = $parts[0].Trim()
    $value = $parts[1].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    if (-not [string]::IsNullOrWhiteSpace($name)) {
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$EnvPath = Join-Path $ProjectRoot ".env.local"
Import-AipetDotEnv -Path $EnvPath

$ChannelRoot = [string]$env:AIPET_WXAUTO_CHANNEL_ROOT
if ([string]::IsNullOrWhiteSpace($ChannelRoot)) {
  $ChannelRoot = Join-Path $ProjectRoot ".cache\openclaw-wechat-channel"
}

$VenvPath = Join-Path $ProjectRoot ".venv"
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"
$Wxautox4Exe = Join-Path $VenvPath "Scripts\wxautox4.exe"
$PipCache = Join-Path $ProjectRoot ".cache\pip"
$WxautoxHome = [string]$env:AIPET_WXAUTOX_HOME
if (-not [string]::IsNullOrWhiteSpace($WxautoxHomeOverride)) {
  $WxautoxHome = $WxautoxHomeOverride
}
$WxautoxHomeMode = "project"
if ([string]::IsNullOrWhiteSpace($WxautoxHome)) {
  $WxautoxHome = Join-Path $ProjectRoot ".cache\wxautox-home"
} elseif ($WxautoxHome.Trim().ToLowerInvariant() -in @("default", "system", "user")) {
  $WxautoxHome = [Environment]::GetFolderPath("UserProfile")
  $WxautoxHomeMode = "default"
} elseif (-not [System.IO.Path]::IsPathRooted($WxautoxHome)) {
  $WxautoxHome = Join-Path $ProjectRoot $WxautoxHome
}
$ApiRoot = Join-Path $ChannelRoot "wxauto-restful-api"
$WxChannelRoot = Join-Path $ChannelRoot "wxauto-channel"
$LogsDir = Join-Path $ProjectRoot "logs"
$WxautoBridgeChannelLockPath = Join-Path $LogsDir "aipet-wxauto-bridge-channel.lock"

$LicenseKey = [string]$env:AIPET_WXAUTOX4_LICENSE_KEY
if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
  $LicenseKey = [string]$env:WXAUTOX4_LICENSE_KEY
}

[pscustomobject]@{
  ProjectRoot = $ProjectRoot
  EnvPath = $EnvPath
  ChannelRoot = $ChannelRoot
  VenvPath = $VenvPath
  VenvPython = $VenvPython
  Wxautox4Exe = $Wxautox4Exe
  PipCache = $PipCache
  WxautoxHome = $WxautoxHome
  WxautoxHomeMode = $WxautoxHomeMode
  ApiRoot = $ApiRoot
  WxChannelRoot = $WxChannelRoot
  LogsDir = $LogsDir
  WxautoBridgeChannelLockPath = $WxautoBridgeChannelLockPath
  LicenseKey = $LicenseKey
}
