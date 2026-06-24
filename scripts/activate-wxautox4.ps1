param(
  [string]$LicenseKey = "",
  [switch]$ViaApi,
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [ValidateSet("current", "project", "default")]
  [string]$HomeMode = "current",
  [switch]$Diagnose,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

$wxautoxHomeOverride = ""
if ($HomeMode -eq "project") {
  $wxautoxHomeOverride = ".cache\wxautox-home"
} elseif ($HomeMode -eq "default") {
  $wxautoxHomeOverride = "default"
}

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1") -WxautoxHomeOverride $wxautoxHomeOverride
New-Item -ItemType Directory -Force -Path $WxautoEnv.WxautoxHome | Out-Null
$env:USERPROFILE = $WxautoEnv.WxautoxHome
$env:HOME = $WxautoEnv.WxautoxHome

if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
  $LicenseKey = [string]$WxautoEnv.LicenseKey
}

function ConvertTo-CommandLineArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Test-TcpPort {
  param(
    [string]$HostName,
    [int]$Port,
    [int]$TimeoutMs = 3000
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect($HostName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Write-WxautoxDiagnostics {
  Write-Host "wxautox4 activation diagnostics:"
  Write-Host "  home: $($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)"
  Write-Host "  cli: $($WxautoEnv.Wxautox4Exe)"
  Write-Host "  cli_exists: $(Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe)"
  Write-Host "  license_configured: $(-not [string]::IsNullOrWhiteSpace($LicenseKey))"
  Write-Host "  api_mode: $ViaApi"
  if ($ViaApi) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "$($WxApiBaseUrl.TrimEnd('/'))/" -TimeoutSec 3
      Write-Host "  wxauto_api_root: HTTP $($response.StatusCode)"
    } catch {
      Write-Host "  wxauto_api_root: unavailable - $($_.Exception.Message)"
    }
  }
  Write-Host "  license_server_tcp_443: $(Test-TcpPort -HostName 'license.wxauto.org' -Port 443)"
}

function Write-ScrubbedOutput {
  param([AllowNull()][string]$Text, [AllowNull()][string]$Secret)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return
  }
  $safe = $Text
  if (-not [string]::IsNullOrWhiteSpace($Secret)) {
    $safe = $safe.Replace($Secret, "<redacted>")
  }
  Write-Host $safe.Trim()
}

function Test-ActivationOutput {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $false
  }

  $notActivatedText = [string]([char]0x672A) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $activatedText = [string]([char]0x5DF2) + [string]([char]0x6FC0) + [string]([char]0x6D3B)
  $negative = (
    $Text.Contains($notActivatedText) -or
    $Text -match "(?i)\bnot[_\s-]?activated\b"
  )
  $positive = (
    $Text.Contains($activatedText) -or
    $Text -match "(?i)\btrue\b" -or
    $Text -match "(?i)\bactivated\b"
  )
  return (-not $negative) -and $positive
}

function Invoke-Wxautox4Cli {
  param([string[]]$Arguments)

  $processInfo = New-Object System.Diagnostics.ProcessStartInfo
  $processInfo.FileName = $WxautoEnv.Wxautox4Exe
  $processInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join " "
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $processInfo
  try {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $output = @($stdout, $stderr) -join [Environment]::NewLine
    $exitCode = $process.ExitCode
  } finally {
    $process.Dispose()
  }

  return [pscustomobject]@{
    Output = $output
    ExitCode = $exitCode
  }
}

if ($Diagnose) {
  Write-WxautoxDiagnostics
}

if ($ViaApi) {
  $checkUri = "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/check"
  $activateUri = "$($WxApiBaseUrl.TrimEnd('/'))/v1/activation/activate"

  if ($CheckOnly) {
    $status = Invoke-RestMethod -Method Get -Uri $checkUri
    Write-Host "wxautox4 activation status: $($status.data.status)"
    return
  }

  if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
    throw "Missing wxautox4 activation code. Set AIPET_WXAUTOX4_LICENSE_KEY in .env.local or pass -LicenseKey."
  }

  $payload = @{ license_key = $LicenseKey } | ConvertTo-Json -Depth 4
  $result = Invoke-RestMethod -Method Post -Uri $activateUri -ContentType "application/json" -Body $payload
  if ($result.success -eq $true) {
    Write-Host "wxautox4 activation succeeded via API."
  } else {
    throw "wxautox4 activation failed via API: $($result.message)"
  }

  $status = Invoke-RestMethod -Method Get -Uri $checkUri -TimeoutSec 30
  $statusText = ($status | ConvertTo-Json -Depth 8)
  $apiActivated = (
    [bool]$status.data.activated -or
    [string]$status.data.status -match "(?i)activated" -or
    (Test-ActivationOutput -Text $statusText)
  )
  if (-not $apiActivated) {
    Write-ScrubbedOutput -Text $statusText -Secret $LicenseKey
    throw "wxautox4 activation via API finished but verification still reports not activated."
  }
  Write-Host "wxautox4 activation verified via API."
  return
}

if (-not (Test-Path -LiteralPath $WxautoEnv.Wxautox4Exe)) {
  throw "wxautox4 CLI not found at $($WxautoEnv.Wxautox4Exe). Run setup-wxauto-openclaw-channel.ps1 -InstallDeps first."
}

if ($CheckOnly) {
  $status = Invoke-Wxautox4Cli -Arguments @("-k")
  Write-Host "wxautox home: $($WxautoEnv.WxautoxHome) mode=$($WxautoEnv.WxautoxHomeMode)"
  Write-ScrubbedOutput -Text $status.Output -Secret $LicenseKey
  if ($status.ExitCode -ne 0) {
    throw "wxautox4 status check failed with exit code $($status.ExitCode)."
  }
  return
}

if ([string]::IsNullOrWhiteSpace($LicenseKey)) {
  throw "Missing wxautox4 activation code. Set AIPET_WXAUTOX4_LICENSE_KEY in .env.local or pass -LicenseKey."
}

$activation = Invoke-Wxautox4Cli -Arguments @("-a", $LicenseKey)
Write-ScrubbedOutput -Text $activation.Output -Secret $LicenseKey
if ($activation.ExitCode -ne 0) {
  throw "wxautox4 activation failed with exit code $($activation.ExitCode)."
}

$status = Invoke-Wxautox4Cli -Arguments @("-k")
Write-ScrubbedOutput -Text $status.Output -Secret $LicenseKey
if ($status.ExitCode -ne 0) {
  throw "wxautox4 activation verification failed with exit code $($status.ExitCode)."
}
if (-not (Test-ActivationOutput -Text $status.Output)) {
  throw "wxautox4 activation command finished but verification still reports not activated."
}
Write-Host "wxautox4 activation command finished and verified."
