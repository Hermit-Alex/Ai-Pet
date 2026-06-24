param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$PetWechatName = "",
  [string[]]$PrivateContact = @(),
  [string[]]$FamilyGroup = @(),
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Repair-Text {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) {
    return ""
  }

  $text = [string]$Value
  if ($text -match "[\u0080-\u009F]") {
    try {
      $latin1 = [Text.Encoding]::GetEncoding("iso-8859-1")
      $bytes = $latin1.GetBytes($text)
      $candidate = [Text.Encoding]::UTF8.GetString($bytes)
      if ($candidate -and $candidate -notmatch [char]0xFFFD) {
        $text = $candidate
      }
    } catch {
      # Keep original text if the runtime cannot load the code page.
    }
  }

  return ($text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]", "").Trim()
}

function Repair-List {
  param([AllowNull()][object[]]$Values)
  $items = New-Object System.Collections.ArrayList
  foreach ($item in @($Values)) {
    $raw = Repair-Text ([string]$item)
    foreach ($part in @($raw -split "[,，;\r\n]+")) {
      $text = Repair-Text $part
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        [void]$items.Add($text)
      }
    }
  }
  return $items.ToArray()
}

$bridge = $BridgeUrl.TrimEnd("/")
$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$current = Invoke-RestMethod -Method Get -Uri "$bridge/pets/$encodedPetId/wechat/settings"
$settings = $current.settings

$repaired = [ordered]@{}
$arrayFields = @(
  "family_groups",
  "private_contact_allowlist",
  "wake_words"
)
foreach ($property in $settings.PSObject.Properties) {
  $value = $property.Value
  if ($arrayFields -contains $property.Name) {
    $repaired[$property.Name] = @(Repair-List @($value))
  } elseif ($value -is [array]) {
    $repaired[$property.Name] = @(Repair-List @($value))
  } elseif ($value -is [string]) {
    $repaired[$property.Name] = Repair-Text $value
  } else {
    $repaired[$property.Name] = $value
  }
}

if (-not [string]::IsNullOrWhiteSpace($PetWechatName)) {
  $repaired.pet_wechat_name = Repair-Text $PetWechatName
}
if ($PrivateContact.Count -gt 0) {
  $repaired.private_contact_allowlist = @(Repair-List $PrivateContact)
}
if ($FamilyGroup.Count -gt 0) {
  $repaired.family_groups = @(Repair-List $FamilyGroup)
}

if ($DryRun) {
  $repaired | ConvertTo-Json -Depth 12
  return
}

$body = $repaired | ConvertTo-Json -Depth 12
$result = Invoke-RestMethod -Method Put -Uri "$bridge/pets/$encodedPetId/wechat/settings" -ContentType "application/json; charset=utf-8" -Body $body

Write-Host "Bridge WeChat settings repaired."
Write-Host "pet_wechat_name: $($result.settings.pet_wechat_name)"
Write-Host "private contacts: $(@($result.settings.private_contact_allowlist).Count)"
Write-Host "family groups: $(@($result.settings.family_groups).Count)"
