param(
  [string]$MyNickname = "",
  [string[]]$PrivateChat = @(),
  [string[]]$GroupChat = @(),
  [ValidateSet("at_me_only", "all")]
  [string]$GroupReplyMode = "at_me_only",
  [string[]]$SenderWhitelist = @(),
  [string[]]$SenderBlacklist = @(),
  [switch]$FromBridge,
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$ChannelRoot = "",
  [string]$WxApiToken = "",
  [string]$OpenClawToken = "",
  [string]$OpenClawGatewayUrl = "http://127.0.0.1:18789",
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [string]$WxApiHost = "127.0.0.1",
  [int]$WxApiPort = 8001,
  [string]$AgentId = "main"
)

$ErrorActionPreference = "Stop"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")

function ConvertTo-YamlScalar {
  param([AllowNull()][string]$Value)
  $Value = Repair-Text $Value
  if ([string]::IsNullOrEmpty($Value)) {
    return "''"
  }
  return "'" + $Value.Replace("'", "''") + "'"
}

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

function ConvertTo-YamlInlineList {
  param([AllowNull()][string[]]$Values)
  $clean = @(Repair-List $Values)
  if ($clean.Count -eq 0) {
    return "[]"
  }
  return "[" + (($clean | ForEach-Object { ConvertTo-YamlScalar ([string]$_) }) -join ", ") + "]"
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

function Set-Utf8NoBomFile {
  param(
    [string]$Path,
    [AllowNull()][object[]]$Value
  )

  $lines = @($Value | ForEach-Object { [string]$_ })
  if ($lines.Count -gt 0) {
    $lines[0] = $lines[0].TrimStart([char]0xFEFF)
  }
  $text = [string]::Join([Environment]::NewLine, $lines) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Get-BridgeWechatSettings {
  param(
    [string]$BridgeUrl,
    [string]$PetId
  )

  $env:AIPET_BRIDGE_SETTINGS_URL = $BridgeUrl
  $env:AIPET_BRIDGE_SETTINGS_PET_ID = $PetId
  $env:PYTHONIOENCODING = "utf-8"
  $code = @'
import json
import os
import urllib.parse
import urllib.request

base_url = os.environ["AIPET_BRIDGE_SETTINGS_URL"].rstrip("/")
pet_id = os.environ["AIPET_BRIDGE_SETTINGS_PET_ID"]
url = f"{base_url}/pets/{urllib.parse.quote(pet_id, safe='')}/wechat/settings"
with urllib.request.urlopen(url, timeout=10) as response:
    payload = json.loads(response.read().decode("utf-8"))
print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
'@

  $output = $code | & $WxautoEnv.VenvPython -
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to read Bridge WeChat settings from $BridgeUrl."
  }
  $jsonLine = ($output | Where-Object { [string]$_ -match "^\{" } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    throw "Bridge WeChat settings response was empty."
  }
  return ($jsonLine | ConvertFrom-Json)
}

$ProjectRoot = $WxautoEnv.ProjectRoot
if ([string]::IsNullOrWhiteSpace($ChannelRoot)) {
  $ChannelRoot = $WxautoEnv.ChannelRoot
}

$ApiRoot = Join-Path $ChannelRoot "wxauto-restful-api"
$WxChannelRoot = Join-Path $ChannelRoot "wxauto-channel"
if (-not (Test-Path -LiteralPath $ApiRoot) -or -not (Test-Path -LiteralPath $WxChannelRoot)) {
  throw "wxauto channel source not found. Run scripts\setup-wxauto-openclaw-channel.ps1 first."
}
$apiConfigPath = Join-Path $ApiRoot "config.yaml"
$channelConfigPath = Join-Path $WxChannelRoot "config.yaml"
$listenServicePath = Join-Path $ApiRoot "app\services\listen_service.py"

if ($FromBridge) {
  $wechatSettings = Get-BridgeWechatSettings -BridgeUrl $BridgeUrl -PetId $PetId
  $settings = $wechatSettings.settings

  if ([string]::IsNullOrWhiteSpace($MyNickname)) {
    $MyNickname = Repair-Text ([string]$settings.pet_wechat_name)
  }
  if ($PrivateChat.Count -eq 0) {
    $PrivateChat = @($settings.private_contact_allowlist | ForEach-Object { Repair-Text ([string]$_) })
  }
  if ($GroupChat.Count -eq 0) {
    $GroupChat = @($settings.family_groups | ForEach-Object { Repair-Text ([string]$_) })
  }
}

$MyNickname = Repair-Text $MyNickname
$PrivateChat = @(Repair-List $PrivateChat)
$GroupChat = @(Repair-List $GroupChat)
$SenderWhitelist = @(Repair-List $SenderWhitelist)
$SenderBlacklist = @(Repair-List $SenderBlacklist)

if ([string]::IsNullOrWhiteSpace($MyNickname)) {
  throw "Missing -MyNickname. It must match the pet WeChat account display name exactly."
}

if ([string]::IsNullOrWhiteSpace($WxApiToken)) {
  $WxApiToken = [string]$env:AIPET_WXAPI_TOKEN
}
if ([string]::IsNullOrWhiteSpace($WxApiToken) -and (Test-Path -LiteralPath $apiConfigPath)) {
  try {
    $existingApiConfig = Get-Content -LiteralPath $apiConfigPath -Raw -Encoding UTF8
    $match = [regex]::Match($existingApiConfig, "(?ms)^auth:\s*\r?\n(?:\s+.+\r?\n)*?\s+token:\s*['""]?([^'""\r\n#]+)")
    if ($match.Success) {
      $WxApiToken = Repair-Text $match.Groups[1].Value
    }
  } catch {
    $WxApiToken = ""
  }
}
if ([string]::IsNullOrWhiteSpace($WxApiToken)) {
  $WxApiToken = [Guid]::NewGuid().ToString("N")
}

if ([string]::IsNullOrWhiteSpace($OpenClawToken)) {
  $OpenClawToken = [string]$env:OPENCLAW_GATEWAY_TOKEN
}
if ([string]::IsNullOrWhiteSpace($OpenClawToken)) {
  $OpenClawToken = [string]$env:AIPET_OPENCLAW_GATEWAY_TOKEN
}
if ([string]::IsNullOrWhiteSpace($OpenClawToken)) {
  $openClawConfigPath = Join-Path $ProjectRoot ".openclaw\openclaw.json"
  if (Test-Path -LiteralPath $openClawConfigPath) {
    try {
      $openClawConfig = Get-Content -LiteralPath $openClawConfigPath -Raw | ConvertFrom-Json
      $OpenClawToken = [string]$openClawConfig.gateway.auth.token
    } catch {
      $OpenClawToken = ""
    }
  }
}

if ([string]::IsNullOrWhiteSpace($OpenClawToken)) {
  Write-Warning "OpenClawToken is empty. This is OK only if the Gateway is running without token auth."
}

New-Item -ItemType Directory -Force -Path `
  (Join-Path $ApiRoot "uploads"), `
  (Join-Path $ApiRoot "data"), `
  (Join-Path $ApiRoot "wxauto_logs"), `
  (Join-Path $ApiRoot "static"), `
  (Join-Path $ApiRoot "static\swagger-ui"), `
  (Join-Path $ApiRoot "static\redoc"), `
  (Join-Path $WxChannelRoot "tmp") | Out-Null

$apiConfig = @(
  "server:",
  "  host: $(ConvertTo-YamlScalar $WxApiHost)",
  "  port: $WxApiPort",
  "  reload: false",
  "upload:",
  "  base_dir: './uploads'",
  "  max_size: 10485760",
  "  allowed_types: []",
  "  chunk_size: 8192",
  "database:",
  "  type: 'sqlite'",
  "  sqlite:",
  "    path: './data/wxauto.db'",
  "  mysql:",
  "    host: 'localhost'",
  "    port: 3306",
  "    user: 'root'",
  "    password: 'password'",
  "    database: 'wxauto'",
  "    charset: 'utf8mb4'",
  "  mongodb:",
  "    host: 'localhost'",
  "    port: 27017",
  "    database: 'wxauto'",
  "    username: ''",
  "    password: ''",
  "wechat:",
  "  app_path: 'C:/Program Files/WeChat/WeChat.exe'",
  "  language: 'cn'",
  "  enable_file_logger: true",
  "  message_hash: true",
  "  default_message_xbias: 51",
  "  force_message_xbias: true",
  "  listen_interval: 1",
  "  listener_executor_workers: 4",
  "  search_chat_timeout: 5",
  "  note_load_timeout: 30",
  "storage:",
  "  default_save_path: './wxauto'",
  "  log_path: './wxauto_logs'",
  "logging:",
  "  level: 'INFO'",
  "  format: '%(asctime)s - %(levelname)s - %(message)s'",
  "  file: 'wxauto_api.log'",
  "auth:",
  "  token: $(ConvertTo-YamlScalar $WxApiToken)",
  "api:",
  "  prefix: '/v1'",
  "  docs_url: '/docs'",
  "  redoc_url: '/redoc'",
  "  openapi_url: '/openapi.json'",
  "performance:",
  "  max_workers: 4",
  "  timeout: 30",
  "  retry_attempts: 3",
  "  retry_delay: 1"
)

$channelConfig = @(
  "wxapi:",
  "  base_url: $(ConvertTo-YamlScalar $WxApiBaseUrl)",
  "  token: $(ConvertTo-YamlScalar $WxApiToken)",
  "aipet_bridge:",
  "  base_url: $(ConvertTo-YamlScalar $BridgeUrl)",
  "  pet_id: $(ConvertTo-YamlScalar $PetId)",
  "openclaw:",
  "  gateway_url: $(ConvertTo-YamlScalar $OpenClawGatewayUrl)",
  "  token: $(ConvertTo-YamlScalar $OpenClawToken)",
  "  agent_id: $(ConvertTo-YamlScalar $AgentId)",
  "my_nickname: $(ConvertTo-YamlScalar $MyNickname)",
  "allowed_message_types: ['text']",
  "require_openclaw_for_send: true",
  "private_debounce_seconds: 5",
  "private_batch_max_wait_seconds: 12",
  "private_batch_max_messages: 8",
  "private_rate_limited_max_retries: 3",
  "private_rate_limited_fallback_retry_seconds: 15",
  "temp_dir: './tmp'"
)

$privateItems = @($PrivateChat | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($privateItems.Count -eq 0) {
  $channelConfig += "private_chats: []"
} else {
  $channelConfig += "private_chats:"
  foreach ($name in $privateItems) {
    $channelConfig += "  - name: $(ConvertTo-YamlScalar ([string]$name))"
    $channelConfig += "    enabled: true"
  }
}

$groupItems = @($GroupChat | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($groupItems.Count -eq 0) {
  $channelConfig += "group_chats: []"
} else {
  $channelConfig += "group_chats:"
  foreach ($name in $groupItems) {
    $channelConfig += "  - name: $(ConvertTo-YamlScalar ([string]$name))"
    $channelConfig += "    enabled: true"
    $channelConfig += "    reply_mode: $GroupReplyMode"
    $channelConfig += "    sender_whitelist: $(ConvertTo-YamlInlineList $SenderWhitelist)"
    $channelConfig += "    sender_blacklist: $(ConvertTo-YamlInlineList $SenderBlacklist)"
  }
}

Set-Utf8NoBomFile -Path $apiConfigPath -Value $apiConfig
Set-Utf8NoBomFile -Path $channelConfigPath -Value $channelConfig

$safeContacts = @($privateItems + $groupItems | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_)
  } | Sort-Object -Unique)
if (Test-Path -LiteralPath $listenServicePath) {
  $safeContactPythonItems = @(
    $safeContacts | ForEach-Object {
      "'" + ([string]$_).Replace("\", "\\").Replace("'", "\'") + "'"
    }
  )
  $safeContactPythonSet = "{" + ($safeContactPythonItems -join ", ") + "}"
  $listenServiceLines = @(
    Get-Content -LiteralPath $listenServicePath -Encoding UTF8 | ForEach-Object {
      $line = [string]$_
      if ($line.TrimStart().StartsWith("SAFE_CONTACTS:")) {
        "SAFE_CONTACTS: Set[str] = $safeContactPythonSet"
      } elseif ($line.TrimStart().StartsWith("SANDBOX_MODE:")) {
        "SANDBOX_MODE: bool = True"
      } else {
        $line
      }
    }
  )
  Set-Utf8NoBomFile -Path $listenServicePath -Value $listenServiceLines
}

Write-Host "Wrote wxauto API config: $apiConfigPath"
Write-Host "Wrote wxauto channel config: $channelConfigPath"
Write-Host "wxapi token: <written to config>"
Write-Host ""
Write-Host "Safety defaults:"
Write-Host "  API host: $WxApiHost"
Write-Host "  API listen sandbox: true"
Write-Host "  API safe contacts: $($safeContacts.Count)"
Write-Host "  Group reply mode: $GroupReplyMode"
Write-Host "  Private chats: $($privateItems.Count)"
Write-Host "  Group chats: $($groupItems.Count)"
