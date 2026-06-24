param(
  [string]$WxApiBaseUrl = "http://127.0.0.1:8001",
  [string]$ConfigPath = "",
  [string]$TargetName = "",
  [int]$TimeoutSeconds = 5,
  [switch]$SkipWebSocket,
  [switch]$Strict
)

$ErrorActionPreference = "Continue"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")
$ProjectRoot = $WxautoEnv.ProjectRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $WxautoEnv.WxChannelRoot "config.yaml"
}

function Write-ContractCheck {
  param(
    [ValidateSet("OK", "WARN", "FAIL")]
    [string]$State,
    [string]$Name,
    [string]$Detail = ""
  )

  if ($State -eq "WARN") {
    $script:WarnCount += 1
  }
  if ($State -eq "FAIL") {
    $script:FailCount += 1
  }

  $line = "[$State] $Name"
  if (-not [string]::IsNullOrWhiteSpace($Detail)) {
    $line += " - $Detail"
  }
  Write-Host $line
}

function Invoke-PythonJson {
  param([string]$Code)
  try {
    $env:PYTHONPATH = Join-Path $ProjectRoot "src"
    $env:PYTHONIOENCODING = "utf-8"
    $output = $Code | & $WxautoEnv.VenvPython -
    $jsonLine = ($output | Where-Object { [string]$_ -match "^\{" } | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
      return $null
    }
    return $jsonLine | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{
      ok = $false
      error = $_.Exception.Message
    }
  }
}

$script:WarnCount = 0
$script:FailCount = 0

Write-Host "== AI Pet wxauto Runtime Contract Test =="
Write-Host "wxauto API: $WxApiBaseUrl"
Write-Host "config: $ConfigPath"
Write-Host ""

if (-not (Test-Path -LiteralPath $WxautoEnv.VenvPython)) {
  Write-ContractCheck -State "FAIL" -Name "Python venv" -Detail $WxautoEnv.VenvPython
  exit 1
}

$configProbe = Invoke-PythonJson @"
import json
from aipet_wxauto_bridge_channel.channel import ChannelConfig
config = ChannelConfig.from_yaml(r"$ConfigPath")
targets = list(config.target_names)
chosen = r"$TargetName".strip() or (targets[0] if targets else "")
print(json.dumps({
    "ok": True,
    "target_count": len(targets),
    "private_count": len([chat for chat in config.private_chats if chat.enabled]),
    "group_count": len([chat for chat in config.group_chats if chat.enabled]),
    "target": chosen,
    "my_nickname": config.my_nickname,
    "allowed_message_types": list(config.allowed_message_types),
    "require_openclaw_for_send": config.require_openclaw_for_send,
}, ensure_ascii=True))
"@

if (-not $configProbe -or -not $configProbe.ok) {
  Write-ContractCheck -State "FAIL" -Name "channel config parse" -Detail $configProbe.error
} else {
  $state = if ([int]$configProbe.target_count -gt 0) { "OK" } else { "FAIL" }
  Write-ContractCheck -State $state -Name "channel config targets" -Detail "private=$($configProbe.private_count) group=$($configProbe.group_count) target=$($configProbe.target)"
  $messageTypes = @($configProbe.allowed_message_types)
  $textOnly = $messageTypes.Count -eq 1 -and [string]$messageTypes[0] -eq "text"
  Write-ContractCheck -State ($(if ($textOnly) { "OK" } else { "FAIL" })) -Name "chat-only message types" -Detail ($messageTypes -join ",")
  Write-ContractCheck -State ($(if ([bool]$configProbe.require_openclaw_for_send) { "OK" } else { "FAIL" })) -Name "OpenClaw required for real send" -Detail "require_openclaw_for_send=$($configProbe.require_openclaw_for_send)"
}

$runtimeProbe = Invoke-PythonJson @"
import json
import sys
from urllib.parse import quote

import requests
from aipet_wxauto_bridge_channel.channel import ChannelConfig

base_url = r"$WxApiBaseUrl".rstrip("/")
timeout = int(r"$TimeoutSeconds")
target = r"$($configProbe.target)"
config = ChannelConfig.from_yaml(r"$ConfigPath")
headers = {
    "Authorization": f"Bearer {config.wxapi_token}",
    "Content-Type": "application/json",
}

def result(ok, **fields):
    fields["ok"] = ok
    print(json.dumps(fields, ensure_ascii=True, separators=(",", ":")))

session = requests.Session()
summary = {
    "root": False,
    "openapi": False,
    "has_send_route": False,
    "has_initialize_route": False,
    "has_listen_ws_route": False,
    "has_activation_route": False,
    "activation_endpoint": False,
    "activated": False,
    "wechat_initialize_endpoint": False,
    "wechat_initialized": False,
    "wechat_initialize_message": "",
    "listen_status": False,
    "listen_config": False,
    "listen_sandbox": False,
    "listen_safe_contacts_count": 0,
    "error": "",
}

try:
    root = session.get(base_url + "/", timeout=timeout)
    summary["root"] = root.status_code == 200

    try:
        openapi = session.get(base_url + "/openapi.json", timeout=timeout)
        if openapi.status_code == 200:
            data = openapi.json()
            paths = set((data.get("paths") or {}).keys())
            summary["openapi"] = True
            summary["has_send_route"] = "/v1/wechat/send" in paths
            summary["has_initialize_route"] = "/v1/wechat/initialize" in paths
            summary["has_listen_ws_route"] = "/v1/listen/ws" in paths
            summary["has_activation_route"] = "/v1/activation/check" in paths
    except Exception:
        pass

    try:
        activation = session.get(base_url + "/v1/activation/check", timeout=timeout)
        summary["activation_endpoint"] = activation.status_code == 200
        if activation.status_code == 200:
            payload = activation.json()
            summary["activated"] = bool((payload.get("data") or {}).get("activated"))
    except Exception:
        pass

    try:
        initialize = session.post(
            base_url + "/v1/wechat/initialize",
            headers=headers,
            json={},
            timeout=timeout,
        )
        summary["wechat_initialize_endpoint"] = initialize.status_code == 200
        if initialize.status_code == 200:
            payload = initialize.json()
            summary["wechat_initialized"] = bool(payload.get("success"))
            summary["wechat_initialize_message"] = str(payload.get("message") or "")[:160]
    except Exception as exc:
        summary["wechat_initialize_message"] = str(exc)[:160]

    try:
        listen_status = session.get(base_url + "/v1/listen/status", timeout=timeout)
        summary["listen_status"] = listen_status.status_code == 200
    except Exception:
        pass

    try:
        listen_config = session.get(base_url + "/v1/listen/config", timeout=timeout)
        summary["listen_config"] = listen_config.status_code == 200
        if listen_config.status_code == 200:
            payload = listen_config.json()
            data = payload.get("data") or {}
            summary["listen_sandbox"] = bool(data.get("sandbox_mode"))
            summary["listen_safe_contacts_count"] = len(data.get("safe_contacts") or [])
    except Exception:
        pass

    result(True, **summary)
except Exception as exc:
    summary["error"] = str(exc)
    result(False, **summary)
"@

if (-not $runtimeProbe -or -not $runtimeProbe.ok) {
  Write-ContractCheck -State "FAIL" -Name "wxauto API root" -Detail $runtimeProbe.error
} else {
  Write-ContractCheck -State ($(if ($runtimeProbe.root) { "OK" } else { "FAIL" })) -Name "wxauto API root" -Detail $WxApiBaseUrl
  Write-ContractCheck -State ($(if ($runtimeProbe.openapi) { "OK" } else { "WARN" })) -Name "OpenAPI document" -Detail "/openapi.json"
  Write-ContractCheck -State ($(if ($runtimeProbe.has_send_route) { "OK" } else { "WARN" })) -Name "send route present" -Detail "/v1/wechat/send"
  Write-ContractCheck -State ($(if ($runtimeProbe.has_initialize_route) { "OK" } else { "FAIL" })) -Name "WeChat initialize route present" -Detail "/v1/wechat/initialize"
  Write-ContractCheck -State ($(if ($runtimeProbe.has_listen_ws_route) { "OK" } else { "WARN" })) -Name "listen WebSocket route present" -Detail "/v1/listen/ws"
  Write-ContractCheck -State ($(if ($runtimeProbe.has_activation_route) { "OK" } else { "WARN" })) -Name "activation route present" -Detail "/v1/activation/check"
  Write-ContractCheck -State ($(if ($runtimeProbe.activation_endpoint) { "OK" } else { "FAIL" })) -Name "activation endpoint reachable" -Detail "activated=$($runtimeProbe.activated)"
  Write-ContractCheck -State ($(if ($runtimeProbe.activated) { "OK" } else { "FAIL" })) -Name "wxautox4 activated" -Detail "runtime API check"
  Write-ContractCheck -State ($(if ($runtimeProbe.wechat_initialize_endpoint) { "OK" } else { "FAIL" })) -Name "WeChat initialize endpoint reachable" -Detail "/v1/wechat/initialize"
  Write-ContractCheck -State ($(if ($runtimeProbe.wechat_initialized) { "OK" } else { "FAIL" })) -Name "WeChat desktop initialized" -Detail $runtimeProbe.wechat_initialize_message
  Write-ContractCheck -State ($(if ($runtimeProbe.listen_status) { "OK" } else { "WARN" })) -Name "listen status endpoint" -Detail "/v1/listen/status"
  Write-ContractCheck -State ($(if ($runtimeProbe.listen_config) { "OK" } else { "WARN" })) -Name "listen config endpoint" -Detail "/v1/listen/config"
  Write-ContractCheck -State ($(if ($runtimeProbe.listen_sandbox) { "OK" } else { "FAIL" })) -Name "listen sandbox enabled" -Detail "safe_contacts=$($runtimeProbe.listen_safe_contacts_count)"
  Write-ContractCheck -State ($(if ([int]$runtimeProbe.listen_safe_contacts_count -gt 0) { "OK" } else { "FAIL" })) -Name "listen safe contacts loaded" -Detail "count=$($runtimeProbe.listen_safe_contacts_count)"
}

if (-not $SkipWebSocket) {
  $target = [string]$configProbe.target
  if ([string]::IsNullOrWhiteSpace($target)) {
    Write-ContractCheck -State "FAIL" -Name "WebSocket handshake" -Detail "no configured target"
  } else {
    $wsProbe = Invoke-PythonJson @"
import asyncio
import json

from aipet_wxauto_bridge_channel.channel import build_listen_ws_url
import websockets

base_url = r"$WxApiBaseUrl".rstrip("/")
target = r"$target"
timeout = int(r"$TimeoutSeconds")
url = build_listen_ws_url(base_url, target, auto_start=False)

async def main():
    try:
        async with websockets.connect(url, open_timeout=timeout, close_timeout=timeout) as ws:
            raw = await asyncio.wait_for(ws.recv(), timeout=timeout)
            payload = json.loads(raw)
            print(json.dumps({
                "ok": payload.get("type") == "status",
                "event_type": payload.get("type", ""),
                "status": (payload.get("data") or {}).get("status", ""),
                "who": (payload.get("data") or {}).get("who", ""),
            }, ensure_ascii=True, separators=(",", ":")))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=True, separators=(",", ":")))

asyncio.run(main())
"@
    if ($wsProbe -and $wsProbe.ok) {
      Write-ContractCheck -State "OK" -Name "WebSocket handshake" -Detail "target=$($wsProbe.who) status=$($wsProbe.status)"
    } else {
      Write-ContractCheck -State "FAIL" -Name "WebSocket handshake" -Detail $wsProbe.error
    }
  }
}

Write-Host ""
if ($script:FailCount -eq 0 -and $script:WarnCount -eq 0) {
  Write-Host "RUNTIME CONTRACT: OK"
} elseif ($script:FailCount -eq 0) {
  Write-Host "RUNTIME CONTRACT: OK WITH WARNINGS ($script:WarnCount warning(s))"
} else {
  Write-Host "RUNTIME CONTRACT: NEEDS ACTION ($script:FailCount failure(s), $script:WarnCount warning(s))"
}

if ($Strict -and $script:FailCount -gt 0) {
  exit 1
}
