param(
  [string]$ContactName = "",
  [string]$MessageText = "aipet self test",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home"
)

$ErrorActionPreference = "Stop"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot
$VenvPython = $WxautoEnv.VenvPython
$ChannelConfigPath = Join-Path $WxautoEnv.WxChannelRoot "config.yaml"
$LogsDir = Join-Path $ProjectRoot "logs"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

if (-not (Test-Path -LiteralPath $VenvPython)) {
  throw "Python venv not found. Run scripts\setup-dev.ps1 -Install first."
}
if (-not (Test-Path -LiteralPath $ChannelConfigPath)) {
  throw "wxauto channel config not found. Run scripts\configure-wxauto-openclaw-channel.ps1 first."
}

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot ".cache"), $LogsDir | Out-Null
$env:PYTHONPATH = Join-Path $ProjectRoot "src"

$messagePath = Join-Path $ProjectRoot ".cache\aipet-wxauto-once-message.json"
$metadataPath = Join-Path $ProjectRoot ".cache\aipet-wxauto-once-message-meta.json"
$resultPath = Join-Path $ProjectRoot ".cache\aipet-wxauto-once-result.json"

$env:AIPET_SELFTEST_CONTACT_NAME = $ContactName
$env:AIPET_SELFTEST_MESSAGE_TEXT = $MessageText
$messageWriter = @"
import json
import os
import uuid
from aipet_wxauto_bridge_channel.channel import ChannelConfig

config = ChannelConfig.from_yaml(r"$ChannelConfigPath", bridge_url=r"$BridgeUrl", pet_id=r"$PetId")
contact = os.environ.get("AIPET_SELFTEST_CONTACT_NAME", "").strip()
if not contact:
    private = [chat.name for chat in config.private_chats if chat.enabled]
    if not private:
        raise SystemExit("no private chat target configured")
    contact = private[0]

message = {
    "who": contact,
    "sender": contact,
    "content": os.environ.get("AIPET_SELFTEST_MESSAGE_TEXT", "aipet self test"),
    "type": "text",
    "id": f"aipet-selftest-{uuid.uuid4().hex}",
    "chat_type": "private",
}
with open(r"$messagePath", "w", encoding="utf-8") as handle:
    json.dump(message, handle, ensure_ascii=False, separators=(",", ":"))
with open(r"$metadataPath", "w", encoding="utf-8") as handle:
    json.dump({"contact": contact}, handle, ensure_ascii=False, separators=(",", ":"))
"@
$messageWriter | & $VenvPython -

$ContactName = "<configured private target>"
try {
  $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($metadata.contact) {
    $ContactName = [string]$metadata.contact
  }
} catch {
  # Keep a generic label if the console cannot decode the contact name cleanly.
}

try {
  $channelOutput = & $VenvPython -m aipet_wxauto_bridge_channel.cli `
    --config $ChannelConfigPath `
    --bridge-url $BridgeUrl `
    --pet-id $PetId `
    --once-json $messagePath `
    --once-output $resultPath `
    --log-file (Join-Path $LogsDir "aipet-wxauto-bridge-channel.log")

  if (-not (Test-Path -LiteralPath $resultPath)) {
    throw "Channel self-test did not return JSON."
  }

  $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Host "AI Pet wxauto Bridge channel self-test result:"
  Write-Host "  contact: $ContactName"
  Write-Host "  action: $($result.action)"
  Write-Host "  reason: $($result.reason)"
  Write-Host "  trace_id: $($result.trace_id)"
  Write-Host "  sent: $($result.sent)"
  if ($result.decision -and $result.decision.block_reason) {
    Write-Host "  bridge_block_reason: $($result.decision.block_reason)"
  }
  if ($result.reply_text) {
    Write-Host "  reply_preview: $($result.reply_text)"
  }

  if ($result.action -in @("dry_run", "blocked", "manual_review", "auto_disabled")) {
    exit 0
  }

  throw "Unexpected self-test action: $($result.action)"
} finally {
  Remove-Item -LiteralPath $messagePath, $metadataPath, $resultPath -Force -ErrorAction SilentlyContinue
}
