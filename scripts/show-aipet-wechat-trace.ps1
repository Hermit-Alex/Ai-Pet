param(
  [string]$TraceId = "",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [int]$Limit = 80
)

$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$OutputEncoding = [Console]::OutputEncoding

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LogsDir = Join-Path $ProjectRoot "logs"

function Get-BridgeLogs {
  param([string]$MaybeTraceId, [int]$Max)
  try {
    $uri = "$($BridgeUrl.TrimEnd('/'))/logs?limit=$Max"
    if (-not [string]::IsNullOrWhiteSpace($MaybeTraceId)) {
      $uri += "&trace_id=$([Uri]::EscapeDataString($MaybeTraceId))"
    }
    $response = Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 5
    if ($response.PSObject.Properties.Name -contains "value") {
      return @($response.value)
    }
    return @($response)
  } catch {
    return @()
  }
}

function Get-LocalLogs {
  param([string]$MaybeTraceId, [int]$Max)
  $records = New-Object System.Collections.Generic.List[object]
  $files = @(
    "wechat-sidecar.jsonl",
    "aipet-bridge.jsonl",
    "audit-events.jsonl",
    "errors.jsonl"
  )

  foreach ($file in $files) {
    $path = Join-Path $LogsDir $file
    if (-not (Test-Path -LiteralPath $path)) {
      continue
    }
    Get-Content -LiteralPath $path -Tail 1000 -Encoding UTF8 | ForEach-Object {
      try {
        $record = $_ | ConvertFrom-Json
      } catch {
        return
      }
      if (-not [string]::IsNullOrWhiteSpace($MaybeTraceId) -and $record.trace_id -ne $MaybeTraceId) {
        return
      }
      $records.Add($record) | Out-Null
    }
  }

  return @($records | Sort-Object ts -Descending | Select-Object -First $Max)
}

function Select-LatestTraceId {
  param([object[]]$Records)
  $candidate = $Records |
    Where-Object {
      $_.trace_id -and (
        $_.event -eq "wechat.wxauto.detected" -or
        $_.event -eq "wechat.private.detected" -or
        $_.event -eq "wechat.message.detected"
      )
    } |
    Sort-Object ts -Descending |
    Select-Object -First 1
  if ($candidate) {
    return [string]$candidate.trace_id
  }
  $candidate = $Records |
    Where-Object { $_.trace_id -and ($_.event -like "wechat.*" -or $_.event -like "bridge.*") } |
    Sort-Object ts -Descending |
    Select-Object -First 1
  if ($candidate) {
    return [string]$candidate.trace_id
  }
  return ""
}

function Get-FieldValue {
  param([object]$Record, [string[]]$Names)
  foreach ($name in $Names) {
    if ($Record.PSObject.Properties.Name -contains $name) {
      $value = [string]$Record.$name
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  }
  return ""
}

$records = Get-LocalLogs -MaybeTraceId $TraceId -Max $Limit
if ($records.Count -eq 0) {
  $records = Get-BridgeLogs -MaybeTraceId $TraceId -Max $Limit
}

if ([string]::IsNullOrWhiteSpace($TraceId)) {
  $TraceId = Select-LatestTraceId -Records $records
  if (-not [string]::IsNullOrWhiteSpace($TraceId)) {
    $records = Get-LocalLogs -MaybeTraceId $TraceId -Max $Limit
    if ($records.Count -eq 0) {
      $records = Get-BridgeLogs -MaybeTraceId $TraceId -Max $Limit
    }
  }
}

if ([string]::IsNullOrWhiteSpace($TraceId)) {
  Write-Host "No recent AI Pet WeChat trace found."
  Write-Host "Try after running scripts\test-aipet-wxauto-bridge-channel.ps1 or sending a real WeChat message."
  exit 0
}

if ($records.Count -eq 0) {
  Write-Host "No log records found for trace_id: $TraceId"
  exit 0
}

Write-Host "AI Pet WeChat trace:"
Write-Host "  trace_id: $TraceId"
Write-Host "  records: $($records.Count)"
Write-Host ""

$timeline = @($records | Sort-Object ts)
foreach ($record in $timeline) {
  $target = Get-FieldValue -Record $record -Names @("contact_name", "target_name", "group_name")
  $sender = Get-FieldValue -Record $record -Names @("sender_name")
  $result = Get-FieldValue -Record $record -Names @("result")
  $block = Get-FieldValue -Record $record -Names @("block_reason")
  $model = Get-FieldValue -Record $record -Names @("model_source")
  $summary = Get-FieldValue -Record $record -Names @("message_text_summary", "reply_text_summary", "error")

  $line = "{0}  {1,-30}  {2,-36}" -f $record.ts, $record.service, $record.event
  if ($target) {
    $line += " target=$target"
  }
  if ($sender) {
    $line += " sender=$sender"
  }
  if ($result) {
    $line += " result=$result"
  }
  if ($block) {
    $line += " block=$block"
  }
  if ($model) {
    $line += " model=$model"
  }
  Write-Host $line
  if ($summary) {
    Write-Host "    summary: $summary"
  }
}
