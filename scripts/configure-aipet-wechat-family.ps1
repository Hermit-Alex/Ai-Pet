param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$PetWechatName = "",
  [string[]]$PrivateContact = @(),
  [string[]]$FamilyGroup = @(),
  [string[]]$WakeWord = @(),
  [ValidateSet("observe", "private-auto", "family-group-manual", "family-group-auto")]
  [string]$Mode = "observe",
  [string]$QuietHoursStart = "",
  [string]$QuietHoursEnd = "",
  [int]$PrivateRateLimitMinutes = 0,
  [int]$PrivateRateLimitSeconds = 0,
  [int]$GroupRateLimitMinutes = 0,
  [int]$PrivateDailyLimit = 0,
  [int]$GroupDailyLimit = 0,
  [int]$MaxReplyChars = 0,
  [ValidateSet("at_me_only", "all")]
  [string]$GroupReplyMode = "at_me_only",
  [string[]]$GroupSenderWhitelist = @(),
  [string[]]$GroupSenderBlacklist = @(),
  [switch]$EmergencyStop,
  [switch]$NoEmergencyStop,
  [switch]$SkipWxautoConfig,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Repair-Text {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return ""
  }

  $text = [string]$Value
  for ($attempt = 0; $attempt -lt 3 -and $text -match "[\u0080-\u009F]"; $attempt++) {
    try {
      $latin1 = [Text.Encoding]::GetEncoding("iso-8859-1")
      $bytes = $latin1.GetBytes($text)
      $candidate = [Text.Encoding]::UTF8.GetString($bytes)
      if ($candidate -and $candidate -notmatch [char]0xFFFD) {
        $text = $candidate
      } else {
        break
      }
    } catch {
      # Keep original text if the runtime cannot load the code page.
      break
    }
  }

  return ($text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]", "").Trim()
}

function Repair-List {
  param([AllowNull()][object[]]$Values)
  $items = New-Object System.Collections.ArrayList
  foreach ($item in @($Values)) {
    $raw = Repair-Text ([string]$item)
    $normalized = $raw.Replace([string][char]0xFF0C, ",").Replace([string][char]0xFF1B, ";")
    foreach ($part in @($normalized -split "[,;\r\n]+")) {
      $text = Repair-Text $part
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        [void]$items.Add($text)
      }
    }
  }
  return $items.ToArray()
}

function Copy-ArrayList {
  param([AllowNull()][object[]]$Values)
  return @(Repair-List @($Values))
}

function ConvertTo-JsonBody {
  param([hashtable]$Value)
  return ,([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 16)))
}

function Invoke-BridgeJson {
  param(
    [ValidateSet("Get", "Put")]
    [string]$Method,
    [string]$Uri,
    [hashtable]$Body = $null
  )

  if ($Method -eq "Get") {
    return Invoke-RestMethod -Method Get -Uri $Uri
  }

  return Invoke-RestMethod `
    -Method Put `
    -Uri $Uri `
    -ContentType "application/json; charset=utf-8" `
    -Body (ConvertTo-JsonBody $Body)
}

$bridge = $BridgeUrl.TrimEnd("/")
$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$settingsUrl = "$bridge/pets/$encodedPetId/wechat/settings"
$current = Invoke-BridgeJson -Method Get -Uri $settingsUrl
$settings = $current.settings

$updated = @{}
foreach ($property in $settings.PSObject.Properties) {
  $name = [string]$property.Name
  $value = $property.Value
  if ($value -is [array]) {
    $updated[$name] = Copy-ArrayList @($value)
  } elseif ($value -is [string]) {
    $updated[$name] = Repair-Text $value
  } else {
    $updated[$name] = $value
  }
}

$cleanPetWechatName = Repair-Text $PetWechatName
if (-not [string]::IsNullOrWhiteSpace($cleanPetWechatName)) {
  $updated["pet_wechat_name"] = $cleanPetWechatName
}

if ($PrivateContact.Count -gt 0) {
  $updated["private_contact_allowlist"] = @(Repair-List $PrivateContact)
}
if ($FamilyGroup.Count -gt 0) {
  $updated["family_groups"] = @(Repair-List $FamilyGroup)
}
if ($WakeWord.Count -gt 0) {
  $updated["wake_words"] = @(Repair-List $WakeWord)
}

switch ($Mode) {
  "observe" {
    $updated["manual_review"] = $true
    $updated["auto_reply_enabled"] = $false
    $updated["private_auto_reply_enabled"] = $false
  }
  "private-auto" {
    $updated["manual_review"] = $false
    $updated["auto_reply_enabled"] = $false
    $updated["private_auto_reply_enabled"] = $true
  }
  "family-group-manual" {
    $updated["manual_review"] = $true
    $updated["auto_reply_enabled"] = $false
    $updated["private_auto_reply_enabled"] = $false
  }
  "family-group-auto" {
    $updated["manual_review"] = $false
    $updated["auto_reply_enabled"] = $true
    $updated["private_auto_reply_enabled"] = $true
  }
}

$updated["require_mention"] = ($GroupReplyMode -ne "all")

if ($EmergencyStop -and $NoEmergencyStop) {
  throw "Use only one of -EmergencyStop or -NoEmergencyStop."
}
if ($EmergencyStop) {
  $updated["emergency_stop"] = $true
}
if ($NoEmergencyStop) {
  $updated["emergency_stop"] = $false
}

if (-not [string]::IsNullOrWhiteSpace($QuietHoursStart)) {
  $updated["quiet_hours_start"] = Repair-Text $QuietHoursStart
}
if (-not [string]::IsNullOrWhiteSpace($QuietHoursEnd)) {
  $updated["quiet_hours_end"] = Repair-Text $QuietHoursEnd
}
if ($PrivateRateLimitMinutes -gt 0) {
  $updated["private_rate_limit_minutes"] = $PrivateRateLimitMinutes
}
if ($PrivateRateLimitSeconds -gt 0) {
  $updated["private_rate_limit_seconds"] = $PrivateRateLimitSeconds
} elseif ($PrivateRateLimitMinutes -gt 0) {
  $updated["private_rate_limit_seconds"] = $PrivateRateLimitMinutes * 60
}
if ($GroupRateLimitMinutes -gt 0) {
  $updated["rate_limit_minutes"] = $GroupRateLimitMinutes
}
if ($PrivateDailyLimit -gt 0) {
  $updated["private_daily_limit"] = $PrivateDailyLimit
}
if ($GroupDailyLimit -gt 0) {
  $updated["daily_limit"] = $GroupDailyLimit
}
if ($MaxReplyChars -gt 0) {
  $updated["max_reply_chars"] = $MaxReplyChars
}

$privateContacts = @($updated["private_contact_allowlist"])
$familyGroups = @($updated["family_groups"])
$petWechatName = [string]$updated["pet_wechat_name"]

if ($familyGroups.Count -gt 0 -and [string]::IsNullOrWhiteSpace($petWechatName)) {
  throw "Family group mode requires -PetWechatName so at_me_only matching can stay fail-closed."
}

if ($Mode -eq "family-group-auto" -and $familyGroups.Count -eq 0) {
  throw "Mode family-group-auto requires at least one -FamilyGroup."
}
if (($Mode -eq "private-auto" -or $Mode -eq "family-group-auto") -and $privateContacts.Count -eq 0) {
  Write-Warning "No private contacts are configured. Private auto reply will have no target."
}

if ($DryRun) {
  $updated | ConvertTo-Json -Depth 16
  return
}

$result = Invoke-BridgeJson -Method Put -Uri $settingsUrl -Body $updated

if (-not $SkipWxautoConfig) {
  & (Join-Path $PSScriptRoot "configure-wxauto-openclaw-channel.ps1") `
    -FromBridge `
    -BridgeUrl $BridgeUrl `
    -PetId $PetId `
    -GroupReplyMode $GroupReplyMode `
    -SenderWhitelist $GroupSenderWhitelist `
    -SenderBlacklist $GroupSenderBlacklist
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to regenerate wxauto channel config."
  }
}

$final = $result.settings
Write-Host "AI Pet WeChat family settings applied."
Write-Host "mode: $Mode"
Write-Host "pet_wechat_name: $($final.pet_wechat_name)"
Write-Host "private contacts: $(@($final.private_contact_allowlist).Count)"
Write-Host "family groups: $(@($final.family_groups).Count)"
Write-Host "manual_review: $($final.manual_review)"
Write-Host "private_auto_reply_enabled: $($final.private_auto_reply_enabled)"
Write-Host "group_auto_reply_enabled: $($final.auto_reply_enabled)"
Write-Host "require_mention: $($final.require_mention)"
Write-Host "private_rate_limit_seconds: $($final.private_rate_limit_seconds)"
Write-Host "emergency_stop: $($final.emergency_stop)"
Write-Host "wxauto config regenerated: $(-not $SkipWxautoConfig)"
