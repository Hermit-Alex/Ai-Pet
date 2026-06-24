param(
  [switch]$StopBridge,
  [switch]$StopGateway,
  [switch]$SkipWxauto,
  [switch]$OnlyClearStaleLock
)

$ErrorActionPreference = "Continue"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")

function Test-PidActive {
  param([int]$ProcessId)
  if ($ProcessId -le 0) {
    return $false
  }
  return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Clear-StaleWxautoChannelLock {
  $lockPath = $WxautoEnv.WxautoBridgeChannelLockPath
  if (-not (Test-Path -LiteralPath $lockPath)) {
    return
  }

  $lockPid = 0
  try {
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lockPid = [int]$lock.pid
  } catch {
    $lockPid = 0
  }

  if (-not (Test-PidActive -ProcessId $lockPid)) {
    Write-Host "Removing stale wxauto Bridge channel lock: $lockPath"
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    return
  }

  Write-Warning "wxauto Bridge channel lock is still owned by active pid=${lockPid}: $lockPath"
}

function Get-ListeningProcessIds {
  param([int]$Port)

  $ids = New-Object System.Collections.Generic.HashSet[int]

  try {
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
      if ($connection.OwningProcess -and [int]$connection.OwningProcess -gt 0) {
        [void]$ids.Add([int]$connection.OwningProcess)
      }
    }
  } catch {
    Write-Warning "Get-NetTCPConnection failed for port ${Port}: $($_.Exception.Message)"
  }

  try {
    $netstat = @(netstat -ano -p tcp 2>$null)
    $portPattern = "[:.]$Port$"
    foreach ($line in $netstat) {
      $text = ([string]$line).Trim()
      if ($text -notmatch "^\s*TCP\s+") {
        continue
      }
      $parts = @($text -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($parts.Count -lt 5) {
        continue
      }
      $localAddress = [string]$parts[1]
      $state = [string]$parts[3]
      $processIdText = [string]$parts[4]
      if ($state -ne "LISTENING" -or $localAddress -notmatch $portPattern) {
        continue
      }
      $processId = 0
      if ([int]::TryParse($processIdText, [ref]$processId) -and $processId -gt 0) {
        [void]$ids.Add($processId)
      }
    }
  } catch {
    Write-Warning "netstat fallback failed for port ${Port}: $($_.Exception.Message)"
  }

  return @($ids)
}

if ($OnlyClearStaleLock) {
  Clear-StaleWxautoChannelLock
  Write-Host "wxauto OpenClaw channel stale lock cleanup finished."
  return
}

$ports = @()
if (-not $SkipWxauto) {
  $ports += 8001
}
if ($StopBridge) {
  $ports += 8787
}
if ($StopGateway) {
  $ports += 18789
}

foreach ($port in $ports) {
  foreach ($processId in (Get-ListeningProcessIds -Port $port)) {
    if ($processId -and $processId -ne $PID) {
      Write-Host "Stopping process $processId on port $port"
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
  }
}

$patterns = @()
if (-not $SkipWxauto) {
  $patterns += "wxauto_channel.py"
  $patterns += "aipet_wxauto_bridge_channel.cli"
  $patterns += "AI Pet wxauto Bridge Channel"
  $patterns += "wxauto-restful-api"
  $patterns += "AI Pet wxauto"
}
if ($StopBridge) {
  $patterns += "run-bridge.ps1"
  $patterns += "aipet_bridge.app:app"
}
if ($StopGateway) {
  $patterns += "run-openclaw-gateway.ps1"
  $patterns += "openclaw gateway"
}

$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($process in $processes) {
  $commandLine = [string]$process.CommandLine
  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    continue
  }
  foreach ($pattern in $patterns) {
    if ($commandLine -like "*$pattern*") {
      if ($process.ProcessId -ne $PID) {
        Write-Host "Stopping process $($process.ProcessId): $pattern"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
      }
      break
    }
  }
}

if (-not $SkipWxauto) {
  Clear-StaleWxautoChannelLock
}

Write-Host "wxauto OpenClaw channel stop command finished."
