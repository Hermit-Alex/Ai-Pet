param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [switch]$StopWxautoProcesses,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

function ConvertTo-JsonBody {
  param([hashtable]$Value)
  return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 16)))
}

function Copy-JsonValue {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }
  if ($Value -is [array]) {
    return @($Value)
  }
  return $Value
}

$bridge = $BridgeUrl.TrimEnd("/")
$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$settingsUrl = "$bridge/pets/$encodedPetId/wechat/settings"

$current = Invoke-RestMethod -Method Get -Uri $settingsUrl -TimeoutSec 10
$settings = $current.settings

$updated = @{}
foreach ($property in $settings.PSObject.Properties) {
  $updated[[string]$property.Name] = Copy-JsonValue $property.Value
}

$updated["emergency_stop"] = $true
$updated["manual_review"] = $true
$updated["auto_reply_enabled"] = $false
$updated["private_auto_reply_enabled"] = $false

Write-Host "AI Pet WeChat emergency stop:"
Write-Host "  bridge: $bridge"
Write-Host "  pet_id: $PetId"
Write-Host "  private contacts preserved: $(@($updated["private_contact_allowlist"]).Count)"
Write-Host "  family groups preserved: $(@($updated["family_groups"]).Count)"
Write-Host "  emergency_stop -> true"
Write-Host "  private_auto_reply_enabled -> false"
Write-Host "  group_auto_reply_enabled -> false"
Write-Host "  manual_review -> true"

if ($DryRun) {
  Write-Host ""
  Write-Host "Dry run only. Bridge settings were not changed."
} else {
  Invoke-RestMethod `
    -Method Put `
    -Uri $settingsUrl `
    -ContentType "application/json; charset=utf-8" `
    -Body (ConvertTo-JsonBody $updated) `
    -TimeoutSec 10 |
    Out-Null

  Write-Host ""
  Write-Host "Emergency stop applied. AI Pet Bridge will block WeChat auto replies."
}

if ($StopWxautoProcesses) {
  Write-Host ""
  if ($DryRun) {
    Write-Host "Dry run only. wxauto channel processes were not stopped."
  } else {
    Write-Host "Stopping wxauto channel processes..."
    & (Join-Path $PSScriptRoot "stop-wxauto-openclaw-channel.ps1")
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to stop wxauto channel processes."
    }
  }
}
