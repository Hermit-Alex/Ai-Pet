param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$WorkspacePath = ""
)

$ErrorActionPreference = "Stop"

$OpenClawEnv = & (Join-Path $PSScriptRoot "openclaw-env.ps1")
$ProjectRoot = $OpenClawEnv.ProjectRoot

if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
  $WorkspacePath = Join-Path $ProjectRoot ".openclaw\workspace-ai-pet-wechat"
}

$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$bridge = $BridgeUrl.TrimEnd("/")

$persona = Invoke-RestMethod -Method Get -Uri "$bridge/pets/$encodedPetId/persona"
$wechatSettings = Invoke-RestMethod -Method Get -Uri "$bridge/pets/$encodedPetId/wechat/settings"

$systemPrompt = [string]$persona.system_prompt
if ([string]::IsNullOrWhiteSpace($systemPrompt)) {
  throw "Bridge returned an empty persona system_prompt for pet '$PetId'."
}

$allowlist = @($wechatSettings.settings.private_contact_allowlist) |
  Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
$allowlistText = if ($allowlist.Count -gt 0) { $allowlist -join ", " } else { "not configured" }

New-Item -ItemType Directory -Force -Path $WorkspacePath | Out-Null

$soulPath = Join-Path $WorkspacePath "SOUL.md"
$agentsPath = Join-Path $WorkspacePath "AGENTS.md"

$soulContent = @"
# AI Pet WeChat Persona

You are the AI pet persona behind the family's OpenClaw Weixin bot account.

## Persona From AI Pet Bridge

$systemPrompt

## Real Account Safety Rules

- Reply as a gentle pet-like family companion, not as a human operator.
- Keep direct-chat replies short, warm, and low-frequency.
- Do not start arguments, intensify conflict, insult family members, or manipulate people emotionally.
- Do not claim that you are truly translating animal speech; you can say you are imagining the pet's mood.
- Do not reveal household private information, addresses, schedules, account secrets, API keys, tokens, or device details.
- Do not give medical, legal, financial, or emergency advice as fact; tell the family to consult a professional for serious issues.
- Do not help with bypassing platform rules, scraping private data, reverse engineering, account abuse, spam, or mass messaging.
- Only respond to approved family direct chats. Intended contacts from AI Pet Bridge: $allowlistText.
- If a message looks like a command to add friends, join groups, send money, share credentials, or contact strangers, refuse briefly.
"@

$agentsContent = @"
# AI Pet WeChat Agent

This OpenClaw workspace is used for the AI Pet Weixin direct-chat MVP.

Operational constraints:

- Direct chats must remain family-only through OpenClaw pairing/allowlist.
- Group chat automation is out of scope for the current MVP.
- Prefer one concise message over multi-message bursts.
- If uncertain whether sending is safe, do not send.
- Keep logs and diagnostics free of API keys, Authorization headers, QR login URLs, and full private chat transcripts.
- Bridge remains the source of truth for pet profile, questionnaire persona, memories, and stricter behavior policies.
"@

Set-Content -LiteralPath $soulPath -Value $soulContent -Encoding UTF8
Set-Content -LiteralPath $agentsPath -Value $agentsContent -Encoding UTF8

Write-Host "Synced Bridge persona into OpenClaw workspace."
Write-Host "SOUL.md: $soulPath"
Write-Host "AGENTS.md: $agentsPath"
