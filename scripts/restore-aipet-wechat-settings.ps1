param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$SnapshotPath = "",
  [switch]$SkipWxautoConfig,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$CacheDir = Join-Path $ProjectRoot ".cache"

function ConvertTo-JsonBody {
  param([object]$Value)
  return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 16)))
}

function Find-LatestSnapshot {
  $latest = Get-ChildItem `
    -LiteralPath $CacheDir `
    -Filter "aipet-wechat-settings-before-private-full-e2e-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($latest) {
    return $latest.FullName
  }
  return ""
}

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
  $SnapshotPath = Find-LatestSnapshot
}

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
  throw "No settings snapshot found. Pass -SnapshotPath explicitly."
}

$resolvedSnapshot = (Resolve-Path -LiteralPath $SnapshotPath).Path
$snapshot = Get-Content -LiteralPath $resolvedSnapshot -Raw -Encoding UTF8 | ConvertFrom-Json

$privateCount = @($snapshot.private_contact_allowlist).Count
$groupCount = @($snapshot.family_groups).Count

Write-Host "AI Pet WeChat settings restore:"
Write-Host "  snapshot: $resolvedSnapshot"
Write-Host "  private contacts: $privateCount"
Write-Host "  family groups: $groupCount"
Write-Host "  private_auto_reply_enabled: $($snapshot.private_auto_reply_enabled)"
Write-Host "  group_auto_reply_enabled: $($snapshot.auto_reply_enabled)"
Write-Host "  emergency_stop: $($snapshot.emergency_stop)"

if ($DryRun) {
  Write-Host ""
  Write-Host "Dry run only. Bridge settings were not changed."
  return
}

$bridge = $BridgeUrl.TrimEnd("/")
$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$uri = "$bridge/pets/$encodedPetId/wechat/settings"
Invoke-RestMethod `
  -Method Put `
  -Uri $uri `
  -ContentType "application/json; charset=utf-8" `
  -Body (ConvertTo-JsonBody $snapshot) `
  -TimeoutSec 10 |
  Out-Null

if (-not $SkipWxautoConfig) {
  & (Join-Path $PSScriptRoot "configure-wxauto-openclaw-channel.ps1") `
    -FromBridge `
    -BridgeUrl $BridgeUrl `
    -PetId $PetId
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to regenerate wxauto config after restoring settings."
  }
}

Write-Host ""
Write-Host "Bridge WeChat settings restored."
Write-Host "wxauto config regenerated: $(-not $SkipWxautoConfig)"
