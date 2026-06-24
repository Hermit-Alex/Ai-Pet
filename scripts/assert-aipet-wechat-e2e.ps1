param(
  [string]$TraceId = "",
  [string]$TargetName = "",
  [string]$BridgeUrl = "http://127.0.0.1:8787",
  [int]$Limit = 300,
  [int]$SinceMinutes = 0,
  [string]$AfterUtc = "",
  [switch]$RequireOpenClaw,
  [switch]$RequireRealSend,
  [switch]$AllowDryRun,
  [switch]$SkipBlockedTraces,
  [string]$ProofPath = "",
  [switch]$Strict
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
    Get-Content -LiteralPath $path -Tail 2000 -Encoding UTF8 | ForEach-Object {
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

function Record-MatchesTarget {
  param([object]$Record, [string]$MaybeTarget)
  if ([string]::IsNullOrWhiteSpace($MaybeTarget)) {
    return $true
  }
  $target = Get-FieldValue -Record $Record -Names @("contact_name", "target_name", "group_name")
  return $target -eq $MaybeTarget
}

function Trace-IsBlockedOnly {
  param([object[]]$TraceRecords)
  $events = @($TraceRecords | ForEach-Object { [string]$_.event })
  $hasBlockedOutcome = [bool](
    $events |
      Where-Object {
        $_ -in @(
          "wechat.wxauto.bridge_blocked",
          "wechat.wxauto.model_path_blocked",
          "wechat.wxauto.ignored",
          "wechat.private.ignored",
          "wechat.message.ignored"
        )
      } |
      Select-Object -First 1
  )
  $hasSendGateOrGeneration = [bool](
    $events |
      Where-Object {
        $_ -in @(
          "bridge.reply.started",
          "wechat.private.reply.generated",
          "wechat.reply.requested",
          "wechat.wxauto.dry_run",
          "wechat.wxauto.manual_review",
          "wechat.wxauto.auto_disabled",
          "wechat.wxauto.reply_sent",
          "wechat.private.reply.sent",
          "wechat.reply.sent"
        )
      } |
      Select-Object -First 1
  )
  return $hasBlockedOutcome -and -not $hasSendGateOrGeneration
}

function Select-LatestTraceId {
  param([object[]]$Records, [string]$MaybeTarget, [bool]$SkipBlockedOnly = $false)
  $candidates = @(
    $Records |
    Where-Object {
      $_.trace_id -and
      (Record-MatchesTarget -Record $_ -MaybeTarget $MaybeTarget) -and
      (
        $_.event -eq "wechat.wxauto.detected" -or
        $_.event -eq "wechat.private.detected" -or
        $_.event -eq "wechat.message.detected"
      )
    } |
    Sort-Object ts -Descending
  )
  foreach ($candidate in $candidates) {
    $candidateTraceId = [string]$candidate.trace_id
    if ($SkipBlockedOnly) {
      $traceRecords = @($Records | Where-Object { [string]$_.trace_id -eq $candidateTraceId })
      if (Trace-IsBlockedOnly -TraceRecords $traceRecords) {
        continue
      }
    }
    return $candidateTraceId
  }

  $candidates = @(
    $Records |
    Where-Object {
      $_.trace_id -and
      (Record-MatchesTarget -Record $_ -MaybeTarget $MaybeTarget) -and
      ($_.event -like "wechat.*" -or $_.event -like "bridge.*")
    } |
    Sort-Object ts -Descending
  )
  foreach ($candidate in $candidates) {
    $candidateTraceId = [string]$candidate.trace_id
    if ($SkipBlockedOnly) {
      $traceRecords = @($Records | Where-Object { [string]$_.trace_id -eq $candidateTraceId })
      if (Trace-IsBlockedOnly -TraceRecords $traceRecords) {
        continue
      }
    }
    return $candidateTraceId
  }
  return ""
}

function Has-Event {
  param([object[]]$Records, [string[]]$Events)
  return [bool]($Records | Where-Object { $Events -contains $_.event } | Select-Object -First 1)
}

function Has-ModelSource {
  param([object[]]$Records, [string]$ModelSource)
  return [bool](
    $Records |
      Where-Object {
        ($_.PSObject.Properties.Name -contains "model_source") -and
        ([string]$_.model_source -eq $ModelSource)
      } |
      Select-Object -First 1
  )
}

function Get-LatestOutcome {
  param([object[]]$Records)
  $outcomeEvents = @(
    "wechat.wxauto.reply_sent",
    "wechat.private.reply.sent",
    "wechat.reply.sent",
    "wechat.wxauto.dry_run",
    "wechat.wxauto.send_failed",
    "wechat.wxauto.bridge_blocked",
    "wechat.wxauto.model_path_blocked",
    "wechat.wxauto.manual_review",
    "wechat.wxauto.auto_disabled",
    "wechat.wxauto.ignored",
    "wechat.private.ignored",
    "wechat.message.ignored"
  )
  return $Records |
    Where-Object { $outcomeEvents -contains $_.event } |
    Sort-Object ts -Descending |
    Select-Object -First 1
}

function Write-Check {
  param(
    [bool]$Ok,
    [string]$Name,
    [string]$Detail = ""
  )
  if ($Ok) {
    $state = "OK"
  } else {
    $state = "FAIL"
    $script:FailCount += 1
  }
  $line = "[$state] $Name"
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $line += " - $Detail"
  }
  Write-Host $line
}

$records = Get-LocalLogs -MaybeTraceId $TraceId -Max $Limit
if ($records.Count -eq 0) {
  $records = Get-BridgeLogs -MaybeTraceId $TraceId -Max $Limit
}

if ($SinceMinutes -gt 0 -and -not [string]::IsNullOrWhiteSpace($AfterUtc)) {
  Write-Host "Use only one of -SinceMinutes or -AfterUtc."
  if ($Strict) {
    exit 1
  }
  exit 0
}

if ($SinceMinutes -gt 0) {
  $threshold = [DateTimeOffset]::UtcNow.AddMinutes(-1 * $SinceMinutes)
  $records = @(
    $records |
      Where-Object {
        try {
          [DateTimeOffset]::Parse([string]$_.ts) -ge $threshold
        } catch {
          $false
        }
      }
  )
}

if (-not [string]::IsNullOrWhiteSpace($AfterUtc)) {
  try {
    $threshold = [DateTimeOffset]::Parse($AfterUtc).ToUniversalTime()
  } catch {
    Write-Host "Invalid -AfterUtc value: $AfterUtc"
    if ($Strict) {
      exit 1
    }
    exit 0
  }
  $records = @(
    $records |
      Where-Object {
        try {
          [DateTimeOffset]::Parse([string]$_.ts).ToUniversalTime() -ge $threshold
        } catch {
          $false
        }
      }
  )
}

if ([string]::IsNullOrWhiteSpace($TraceId)) {
  $TraceId = Select-LatestTraceId `
    -Records $records `
    -MaybeTarget $TargetName `
    -SkipBlockedOnly ([bool]$SkipBlockedTraces)
  if (-not [string]::IsNullOrWhiteSpace($TraceId)) {
    $records = Get-LocalLogs -MaybeTraceId $TraceId -Max $Limit
    if ($records.Count -eq 0) {
      $records = Get-BridgeLogs -MaybeTraceId $TraceId -Max $Limit
    }
  }
}

if ([string]::IsNullOrWhiteSpace($TraceId) -or $records.Count -eq 0) {
  Write-Host "AI Pet WeChat E2E assertion:"
  Write-Host "  result: NO_TRACE"
  Write-Host "  hint: send a real WeChat message, then run this script again."
  if ($Strict) {
    exit 1
  }
  exit 0
}

$timeline = @($records | Sort-Object ts)
$latest = $timeline | Select-Object -Last 1
$first = $timeline | Select-Object -First 1
$target = ""
foreach ($record in $timeline) {
  $target = Get-FieldValue -Record $record -Names @("contact_name", "target_name", "group_name")
  if ($target) {
    break
  }
}

$detected = Has-Event -Records $timeline -Events @("wechat.wxauto.detected", "wechat.private.detected", "wechat.message.detected")
$bridgeStarted = Has-Event -Records $timeline -Events @("bridge.reply.started")
$generated = Has-Event -Records $timeline -Events @("wechat.private.reply.generated", "wechat.reply.requested")
$openclawCompleted = Has-Event -Records $timeline -Events @("bridge.openclaw.completed")
$openclawModel = Has-ModelSource -Records $timeline -ModelSource "openclaw"
$localFallback = Has-ModelSource -Records $timeline -ModelSource "local_fallback"
$sent = Has-Event -Records $timeline -Events @("wechat.wxauto.reply_sent", "wechat.private.reply.sent", "wechat.reply.sent")
$dryRun = Has-Event -Records $timeline -Events @("wechat.wxauto.dry_run")
$sendFailed = Has-Event -Records $timeline -Events @("wechat.wxauto.send_failed")
$modelPathBlocked = Has-Event -Records $timeline -Events @("wechat.wxauto.model_path_blocked")
$blocked = Has-Event -Records $timeline -Events @(
  "wechat.wxauto.bridge_blocked",
  "wechat.wxauto.model_path_blocked",
  "wechat.private.ignored",
  "wechat.message.ignored"
)
$manualReview = Has-Event -Records $timeline -Events @("wechat.wxauto.manual_review")
$autoDisabled = Has-Event -Records $timeline -Events @("wechat.wxauto.auto_disabled")
$outcome = Get-LatestOutcome -Records $timeline

$script:FailCount = 0
Write-Host "AI Pet WeChat E2E assertion:"
Write-Host "  trace_id: $TraceId"
Write-Host "  target: $target"
Write-Host "  records: $($timeline.Count)"
Write-Host "  first_ts: $($first.ts)"
Write-Host "  last_ts: $($latest.ts)"
Write-Host ""

Write-Check -Ok $detected -Name "wxauto/sidecar detected message"
Write-Check -Ok $bridgeStarted -Name "Bridge reply flow started"
Write-Check -Ok $generated -Name "reply generated or requested"

if ($RequireOpenClaw) {
  Write-Check -Ok ($openclawCompleted -or $openclawModel) -Name "OpenClaw model path used"
} else {
  $modelDetail = if ($openclawCompleted -or $openclawModel) {
    "openclaw"
  } elseif ($localFallback) {
    "local_fallback"
  } else {
    "unknown"
  }
  Write-Host "[INFO] model path - $modelDetail"
}

if ($RequireRealSend) {
  Write-Check -Ok $sent -Name "real WeChat reply sent"
} elseif ($AllowDryRun) {
  Write-Check -Ok ($sent -or $dryRun) -Name "reply reached send gate"
} else {
  $sendDetail = if ($sent) {
    "sent"
  } elseif ($dryRun) {
    "dry_run"
  } elseif ($sendFailed) {
    "send_failed"
  } elseif ($modelPathBlocked) {
    "model_path_blocked"
  } elseif ($manualReview) {
    "manual_review"
  } elseif ($autoDisabled) {
    "auto_disabled"
  } elseif ($blocked) {
    "blocked"
  } else {
    "unknown"
  }
  Write-Host "[INFO] send outcome - $sendDetail"
}

if ($outcome) {
  $detail = "event=$($outcome.event)"
  $reason = Get-FieldValue -Record $outcome -Names @("block_reason", "error")
  if ($reason) {
    $detail += " reason=$reason"
  }
  Write-Host "[INFO] latest outcome - $detail"
}

Write-Host ""
if ($script:FailCount -eq 0) {
  Write-Host "E2E ASSERTION: OK"
  if (-not [string]::IsNullOrWhiteSpace($ProofPath)) {
    $resolvedProofPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProofPath)
    $proofDir = Split-Path -Parent $resolvedProofPath
    if (-not [string]::IsNullOrWhiteSpace($proofDir)) {
      New-Item -ItemType Directory -Force -Path $proofDir | Out-Null
    }
    $modelPath = if ($openclawCompleted -or $openclawModel) {
      "openclaw"
    } elseif ($localFallback) {
      "local_fallback"
    } else {
      "unknown"
    }
    $outcomeEvent = ""
    $outcomeReason = ""
    if ($outcome) {
      $outcomeEvent = [string]$outcome.event
      $outcomeReason = Get-FieldValue -Record $outcome -Names @("block_reason", "error")
    }
    $proof = [ordered]@{
      proof_version = "2026-06-full-wechat-e2e"
      generated_at = [DateTimeOffset]::Now.ToString("o")
      trace_id = $TraceId
      target = $target
      first_ts = [string]$first.ts
      last_ts = [string]$latest.ts
      record_count = $timeline.Count
      requirements = [ordered]@{
        require_openclaw = [bool]$RequireOpenClaw
        require_real_send = [bool]$RequireRealSend
        allow_dry_run = [bool]$AllowDryRun
      }
      checks = [ordered]@{
        detected = [bool]$detected
        bridge_reply_started = [bool]$bridgeStarted
        reply_generated_or_requested = [bool]$generated
        openclaw_model_path_used = [bool]($openclawCompleted -or $openclawModel)
        real_wechat_reply_sent = [bool]$sent
        dry_run = [bool]$dryRun
      }
      model_path = $modelPath
      latest_outcome = [ordered]@{
        event = $outcomeEvent
        reason = $outcomeReason
      }
      note = "This proof contains only trace metadata and boolean checks, not full message text."
    }
    $proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedProofPath -Encoding UTF8
    Write-Host "proof_path: $resolvedProofPath"
  }
} else {
  Write-Host "E2E ASSERTION: NEEDS ACTION ($script:FailCount failure(s))"
}

if ($Strict -and $script:FailCount -gt 0) {
  exit 1
}
