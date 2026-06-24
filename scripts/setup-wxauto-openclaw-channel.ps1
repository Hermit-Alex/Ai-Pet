param(
  [string]$RepoUrl = "https://github.com/SEUWanglibo/openclaw-wechat-channel.git",
  [string]$ChannelRoot = "",
  [switch]$InstallDeps,
  [switch]$InstallWxautox4,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot
if ([string]::IsNullOrWhiteSpace($ChannelRoot)) {
  $ChannelRoot = $WxautoEnv.ChannelRoot
}

$VenvPython = $WxautoEnv.VenvPython
$PipCache = $WxautoEnv.PipCache

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ChannelRoot), $PipCache | Out-Null

if (-not (Test-Path -LiteralPath $ChannelRoot)) {
  git clone --depth 1 $RepoUrl $ChannelRoot
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone $RepoUrl."
  }
} elseif ($Force) {
  git -C $ChannelRoot pull --ff-only
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to update $ChannelRoot."
  }
}

if ($InstallDeps -or $InstallWxautox4) {
  if (-not (Test-Path -LiteralPath $VenvPython)) {
    python -m venv (Join-Path $ProjectRoot ".venv")
  }

  $env:PIP_CACHE_DIR = $PipCache
  $env:PIP_USER = "false"

  & $VenvPython -m pip install --no-user --upgrade pip
}

if ($InstallDeps) {
  $apiRequirements = Join-Path $ChannelRoot "wxauto-restful-api\requirements.txt"
  $channelRequirements = Join-Path $ChannelRoot "wxauto-channel\requirements.txt"

  if (Test-Path -LiteralPath $apiRequirements) {
    & $VenvPython -m pip install --no-user -r $apiRequirements
  }
  if (Test-Path -LiteralPath $channelRequirements) {
    & $VenvPython -m pip install --no-user -r $channelRequirements
  } else {
    & $VenvPython -m pip install --no-user requests websockets pyyaml
  }
  & $VenvPython -m pip install --no-user -e "$ProjectRoot[wechat]"
}

if ($InstallDeps -or $InstallWxautox4) {
  & $VenvPython -m pip install --no-user wxautox4
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install wxautox4. Check Python version and network access."
  }
}

Write-Host "wxauto OpenClaw channel source: $ChannelRoot"
Write-Host "Pip cache: $PipCache"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Save and activate wxautox4 if needed:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\save-wxautox4-license.ps1 -LicenseKey <your-code>"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\activate-wxautox4.ps1"
Write-Host "  2. Configure local YAML:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\configure-wxauto-openclaw-channel.ps1 -MyNickname `"PetWeChatNickname`" -GroupChat `"FamilyGroupName`""
Write-Host "  3. Start OpenClaw Gateway:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-openclaw-gateway.ps1"
Write-Host "  4. Start wxauto API and AI Pet Bridge channel:"
Write-Host "     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-aipet-wxauto-bridge-channel.ps1 -Visible"
