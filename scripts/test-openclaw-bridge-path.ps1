param(
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [string]$PetId = "cat-home",
  [string]$TraceId = "",
  [switch]$Strict
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$bridge = $BridgeUrl.TrimEnd("/")
$encodedPetId = [System.Uri]::EscapeDataString($PetId)
$uri = "$bridge/pets/$encodedPetId/openclaw/self-test"
if (-not [string]::IsNullOrWhiteSpace($TraceId)) {
  $bodyJson = @{ trace_id = $TraceId } | ConvertTo-Json -Depth 8
} else {
  $bodyJson = '{"trace_id":null}'
}

Write-Host "== AI Pet Bridge OpenClaw Self-Test =="
Write-Host "Bridge: $BridgeUrl"
Write-Host "Pet: $PetId"
Write-Host ""

try {
  $result = Invoke-RestMethod `
    -Method Post `
    -Uri $uri `
    -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) `
    -TimeoutSec 60
} catch {
  $statusCode = $null
  if ($_.Exception.Response) {
    try {
      $statusCode = [int]$_.Exception.Response.StatusCode
    } catch {
      $statusCode = $null
    }
  }

  Write-Host "[FAIL] Bridge OpenClaw self-test request failed - $($_.Exception.Message)"
  if ($statusCode -eq 404) {
    Write-Host "Hint: the Bridge process on $BridgeUrl is likely an older version. Restart the stack before retrying:"
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-ai-pet-wechat-full.ps1 -TargetName `"<contact>`" -TemporaryPrivateAuto -RestartStack"
  }
  if ($Strict) {
    exit 1
  }
  return
}

Write-Host "trace_id: $($result.trace_id)"
Write-Host "configured: $($result.configured)"
Write-Host "ok: $($result.ok)"
Write-Host "model_source: $($result.model_source)"
if ($result.reply_text_summary) {
  Write-Host "reply_text_summary: $($result.reply_text_summary)"
}
if ($result.block_reason) {
  Write-Host "block_reason: $($result.block_reason)"
}
if ($result.error) {
  Write-Host "error: $($result.error)"
}

if ($result.ok -eq $true -and [string]$result.model_source -eq "openclaw") {
  Write-Host "OPENCLAW SELF-TEST: OK"
  return
}

Write-Host "OPENCLAW SELF-TEST: NEEDS ACTION"
if ($Strict) {
  exit 1
}
