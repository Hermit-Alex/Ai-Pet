from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any


@dataclass(frozen=True)
class BridgeClient:
    base_url: str
    pet_id: str

    def post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.base_url.rstrip('/')}{path}"
        request = urllib.request.Request(
            url=url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))

    def health(self) -> dict[str, Any]:
        url = f"{self.base_url.rstrip('/')}/health"
        with urllib.request.urlopen(url, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    def get(self, path: str) -> dict[str, Any]:
        url = f"{self.base_url.rstrip('/')}{path}"
        with urllib.request.urlopen(url, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))

    def preview_reply(
        self,
        *,
        group_name: str,
        sender_name: str,
        message_text: str,
        mentioned: bool,
    ) -> dict[str, Any]:
        return self.post(
            f"/pets/{self.pet_id}/wechat/reply",
            {
                "group_name": group_name,
                "sender_name": sender_name,
                "message_text": message_text,
                "mentioned": mentioned,
                "observed_at": datetime.now(tz=UTC).isoformat(),
            },
        )

    def preview_private_reply(
        self,
        *,
        contact_name: str,
        message_text: str,
        message_fingerprint: str,
    ) -> dict[str, Any]:
        return self.post(
            f"/pets/{self.pet_id}/wechat/private-reply",
            {
                "contact_name": contact_name,
                "message_text": message_text,
                "message_fingerprint": message_fingerprint,
                "observed_at": datetime.now(tz=UTC).isoformat(),
            },
        )

    def record_private_sent(
        self,
        *,
        contact_name: str,
        trace_id: str,
        message_fingerprint: str,
    ) -> dict[str, Any]:
        return self.post(
            f"/pets/{self.pet_id}/wechat/private-sent",
            {
                "contact_name": contact_name,
                "trace_id": trace_id,
                "message_fingerprint": message_fingerprint,
            },
        )

    def wechat_settings(self) -> dict[str, Any]:
        return self.get(f"/pets/{self.pet_id}/wechat/settings")["settings"]


@dataclass(frozen=True)
class PrivateChatSnapshot:
    ok: bool
    contact_name: str | None
    latest_message: str | None
    reason: str
    texts_seen: list[str]


class PrivateChatAutomator:
    EXCLUDED_TEXTS = {
        "微信",
        "WeChat",
        "Weixin",
        "搜索",
        "通讯录",
        "聊天信息",
        "发送",
        "表情",
        "文件",
        "截图",
        "语音",
        "视频",
        "朋友圈",
    }

    def __init__(self) -> None:
        try:
            import uiautomation as auto  # type: ignore[import-not-found]
        except ImportError as exc:
            raise RuntimeError("uiautomation_not_installed") from exc
        self.auto = auto

    def observe_current_private_chat(
        self,
        *,
        allowlist: list[str],
        expected_contact: str | None = None,
    ) -> PrivateChatSnapshot:
        window = self._find_wechat_window()
        if window is None:
            return PrivateChatSnapshot(False, None, None, "wechat_window_not_found", [])

        texts = self._collect_texts(window)
        contact = self._guess_contact(texts=texts, allowlist=allowlist, expected_contact=expected_contact)
        if not contact:
            return PrivateChatSnapshot(False, None, None, "contact_not_confirmed", texts[:80])

        latest = self._guess_latest_message(texts=texts, contact_name=contact)
        if not latest:
            return PrivateChatSnapshot(False, contact, None, "latest_message_not_found", texts[:80])
        return PrivateChatSnapshot(True, contact, latest, "ok", texts[:80])

    def send_reply_to_current_private_chat(
        self,
        *,
        contact_name: str,
        reply_text: str,
        allowlist: list[str],
    ) -> tuple[bool, str]:
        if contact_name not in allowlist:
            return False, "contact_not_allowed"
        before = self.observe_current_private_chat(allowlist=allowlist, expected_contact=contact_name)
        if not before.ok or before.contact_name != contact_name:
            return False, f"contact_recheck_failed:{before.reason}"
        if not reply_text.strip():
            return False, "empty_reply"

        window = self._find_wechat_window()
        if window is None:
            return False, "wechat_window_not_found"
        edit = self._find_input_control(window)
        if edit is None:
            return False, "input_control_not_found"
        try:
            edit.SetFocus()
            self.auto.SetClipboardText(reply_text)
            self.auto.SendKeys("{Ctrl}v", waitTime=0.05)
            self.auto.SendKeys("{Enter}", waitTime=0.05)
        except Exception as exc:  # noqa: BLE001 - UI automation has broad COM exceptions.
            return False, f"send_failed:{exc}"
        return True, "sent"

    def _find_wechat_window(self):
        root = self.auto.GetRootControl()
        markers = ("wechat", "weixin", "微信", "mmui")
        candidates = []
        for control in root.GetChildren():
            name = control.Name or ""
            class_name = control.ClassName or ""
            haystack = f"{name} {class_name}".lower()
            if any(marker in haystack for marker in markers):
                candidates.append(control)
        if candidates:
            return candidates[0]
        for name in ("微信", "WeChat", "Weixin"):
            window = self.auto.WindowControl(Name=name, searchDepth=1)
            if window.Exists(1):
                return window
        return None

    def _collect_texts(self, root, *, limit: int = 500) -> list[str]:
        texts: list[str] = []
        stack = [root]
        seen = 0
        while stack and seen < limit:
            control = stack.pop()
            seen += 1
            name = (control.Name or "").strip()
            if name and name not in texts:
                texts.append(name)
            try:
                children = control.GetChildren()
            except Exception:  # noqa: BLE001
                children = []
            stack.extend(reversed(children))
        return texts

    def _guess_contact(
        self,
        *,
        texts: list[str],
        allowlist: list[str],
        expected_contact: str | None,
    ) -> str | None:
        if expected_contact:
            return expected_contact if expected_contact in texts else None
        for contact in allowlist:
            if contact in texts:
                return contact
        return None

    def _guess_latest_message(self, *, texts: list[str], contact_name: str) -> str | None:
        candidates = []
        for text in texts:
            clean = " ".join(text.split())
            if not clean or clean == contact_name or clean in self.EXCLUDED_TEXTS:
                continue
            if clean.startswith("http://") or clean.startswith("https://"):
                continue
            if len(clean) > 500:
                continue
            candidates.append(clean)
        return candidates[-1] if candidates else None

    def _find_input_control(self, root):
        matches = []
        stack = [root]
        seen = 0
        while stack and seen < 600:
            control = stack.pop()
            seen += 1
            control_type = control.ControlTypeName or ""
            name = control.Name or ""
            class_name = control.ClassName or ""
            haystack = f"{name} {class_name} {control_type}".lower()
            if "edit" in haystack or "richedit" in haystack:
                matches.append(control)
            try:
                children = control.GetChildren()
            except Exception:  # noqa: BLE001
                children = []
            stack.extend(reversed(children))
        return matches[-1] if matches else None


class WeChatWindowProbe:
    def probe(self) -> dict[str, Any]:
        processes = self._processes()
        try:
            import uiautomation as auto  # type: ignore[import-not-found]
        except ImportError:
            return {
                "processes": processes,
                "ui_available": False,
                "reason": "uiautomation_not_installed",
                "safe_to_send": False,
            }

        candidates = []
        root = auto.GetRootControl()
        root_children = root.GetChildren()
        for name in ("微信", "WeChat", "Weixin"):
            window = auto.WindowControl(Name=name, searchDepth=1)
            if window.Exists(1):
                candidates.append({"name": name, "automation_id": window.AutomationId})
        if not candidates:
            for control in root_children:
                name = control.Name or ""
                class_name = control.ClassName or ""
                lower = f"{name} {class_name}".lower()
                if any(marker in lower for marker in ("微信", "wechat", "weixin", "mmui")):
                    candidates.append(
                        {
                            "name": name,
                            "class_name": class_name,
                            "automation_id": control.AutomationId,
                            "control_type": control.ControlTypeName,
                        }
                    )
        reason = "observe_only_probe"
        if processes and not candidates:
            reason = "wechat_process_seen_but_ui_not_visible"
        return {
            "processes": processes,
            "ui_available": bool(candidates),
            "candidates": candidates,
            "root_children_count": len(root_children),
            "safe_to_send": False,
            "reason": reason,
        }

    def _processes(self) -> list[dict[str, str]]:
        processes = self._processes_from_powershell()
        if processes:
            return processes
        try:
            output = subprocess.check_output(
                ["tasklist", "/FI", "IMAGENAME eq Weixin.exe", "/FO", "CSV", "/NH"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            return []
        processes: list[dict[str, str]] = []
        for raw_line in output.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("INFO:"):
                continue
            parts = [part.strip('"') for part in line.split('","')]
            if len(parts) >= 2:
                processes.append({"image": parts[0], "pid": parts[1]})
        return processes

    def _processes_from_powershell(self) -> list[dict[str, str]]:
        try:
            output = subprocess.check_output(
                [
                    "powershell",
                    "-NoProfile",
                    "-Command",
                    "Get-Process Weixin -ErrorAction SilentlyContinue | "
                    "Select-Object Id,ProcessName,MainWindowTitle | ConvertTo-Json -Compress",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            return []
        raw = output.strip()
        if not raw:
            return []
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return []
        rows = data if isinstance(data, list) else [data]
        return [
            {
                "image": f"{row.get('ProcessName', 'Weixin')}.exe",
                "pid": str(row.get("Id", "")),
                "main_window_title": str(row.get("MainWindowTitle", "")),
            }
            for row in rows
            if row.get("Id")
        ]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aipet-wechat-sidecar")
    parser.add_argument("--bridge-url", default="http://127.0.0.1:8787")
    parser.add_argument("--pet-id", default="cat-home")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("status", help="Check Bridge and local WeChat window visibility.")

    observe = subparsers.add_parser("observe", help="Run a safe observe-only probe loop.")
    observe.add_argument("--interval", type=float, default=10.0)
    observe.add_argument("--once", action="store_true")

    inspect = subparsers.add_parser("inspect-ui", help="Print visible top-level UIAutomation controls.")
    inspect.add_argument("--limit", type=int, default=80)
    inspect.add_argument("--filter", default="")

    observe_private = subparsers.add_parser("observe-private", help="Read the current visible private chat once.")
    observe_private.add_argument("--contact", default="", help="Expected current contact display name.")

    manual = subparsers.add_parser("manual-message", help="Send a manually captured group message to Bridge.")
    manual.add_argument("--group", required=True)
    manual.add_argument("--sender", required=True)
    manual.add_argument("--message", required=True)
    manual.add_argument("--mentioned", action="store_true")

    private = subparsers.add_parser("run-private-autoreply", help="Low-frequency auto reply for allowlisted private chats.")
    private.add_argument("--interval", type=float, default=5.0)
    private.add_argument("--contact", default="", help="Expected current contact display name.")
    private.add_argument("--dry-run", action="store_true", help="Generate replies but do not send.")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    client = BridgeClient(base_url=args.bridge_url, pet_id=args.pet_id)
    probe = WeChatWindowProbe()

    if args.command == "status":
        _print_json({"bridge": _bridge_health(client), "wechat_probe": probe.probe()})
        return

    if args.command == "manual-message":
        try:
            result = client.preview_reply(
                group_name=args.group,
                sender_name=args.sender,
                message_text=args.message,
                mentioned=args.mentioned,
            )
        except urllib.error.URLError as exc:
            raise SystemExit(f"Bridge request failed: {exc}") from exc
        _print_json(result)
        return

    if args.command == "observe":
        while True:
            _print_json(
                {
                    "ts": datetime.now(tz=UTC).isoformat(),
                    "bridge": _bridge_health(client),
                    "wechat_probe": probe.probe(),
                    "mode": "observe_only",
                }
            )
            if args.once:
                return
            time.sleep(args.interval)

    if args.command == "inspect-ui":
        _print_json(inspect_ui(limit=args.limit, text_filter=args.filter))
        return

    if args.command == "observe-private":
        settings = _safe_settings(client)
        allowlist = settings.get("private_contact_allowlist", [])
        snapshot = _observe_private_snapshot(allowlist=allowlist, expected_contact=args.contact or None)
        _print_json(snapshot)
        return

    if args.command == "run-private-autoreply":
        run_private_autoreply(
            client=client,
            interval=args.interval,
            expected_contact=args.contact or None,
            dry_run=args.dry_run,
        )
        return

    parser.error(f"Unknown command: {args.command}")


def _bridge_health(client: BridgeClient) -> dict[str, Any]:
    try:
        return client.health()
    except urllib.error.URLError as exc:
        return {"status": "error", "error": str(exc)}


def _print_json(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=True, indent=2) + "\n")


def inspect_ui(*, limit: int, text_filter: str = "") -> dict[str, Any]:
    try:
        import uiautomation as auto  # type: ignore[import-not-found]
    except ImportError:
        return {"available": False, "reason": "uiautomation_not_installed", "controls": []}

    root = auto.GetRootControl()
    controls = []
    needle = text_filter.lower().strip()
    for control in root.GetChildren():
        item = {
            "name": control.Name or "",
            "class_name": control.ClassName or "",
            "automation_id": control.AutomationId or "",
            "control_type": control.ControlTypeName or "",
            "process_id": getattr(control, "ProcessId", None),
        }
        haystack = " ".join(str(value).lower() for value in item.values())
        if needle and needle not in haystack:
            continue
        controls.append(item)
        if len(controls) >= limit:
            break
    return {
        "available": bool(controls),
        "root_children_count": len(root.GetChildren()),
        "filter": text_filter,
        "controls": controls,
    }


def _safe_settings(client: BridgeClient) -> dict[str, Any]:
    try:
        return client.wechat_settings()
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc), "private_contact_allowlist": []}


def _observe_private_snapshot(
    *,
    allowlist: list[str],
    expected_contact: str | None,
) -> dict[str, Any]:
    try:
        automator = PrivateChatAutomator()
        snapshot = automator.observe_current_private_chat(
            allowlist=allowlist,
            expected_contact=expected_contact,
        )
    except RuntimeError as exc:
        return {"ok": False, "reason": str(exc), "safe_to_send": False}
    return {
        "ok": snapshot.ok,
        "contact_name": snapshot.contact_name,
        "latest_message": snapshot.latest_message,
        "reason": snapshot.reason,
        "safe_to_send": False,
        "texts_seen": snapshot.texts_seen,
    }


def run_private_autoreply(
    *,
    client: BridgeClient,
    interval: float,
    expected_contact: str | None,
    dry_run: bool,
) -> None:
    automator = PrivateChatAutomator()
    seen_fingerprints: set[str] = set()
    sent_texts: set[str] = set()
    while True:
        settings = client.wechat_settings()
        allowlist = settings.get("private_contact_allowlist", [])
        if settings.get("emergency_stop"):
            _print_json({"event": "private_autoreply_paused", "reason": "emergency_stop"})
            time.sleep(interval)
            continue
        if not allowlist:
            _print_json({"event": "private_autoreply_paused", "reason": "empty_private_contact_allowlist"})
            time.sleep(interval)
            continue

        snapshot = automator.observe_current_private_chat(
            allowlist=allowlist,
            expected_contact=expected_contact,
        )
        if not snapshot.ok or not snapshot.contact_name or not snapshot.latest_message:
            _print_json({"event": "sidecar.private.ui.error", "reason": snapshot.reason})
            time.sleep(interval)
            continue

        if snapshot.latest_message in sent_texts:
            _print_json(
                {
                    "event": "wechat.private.ignored",
                    "reason": "latest_message_is_last_sent_reply",
                    "contact_name": snapshot.contact_name,
                }
            )
            time.sleep(interval)
            continue

        fingerprint = _private_sidecar_fingerprint(
            contact_name=snapshot.contact_name,
            message_text=snapshot.latest_message,
        )
        if fingerprint in seen_fingerprints:
            time.sleep(interval)
            continue
        seen_fingerprints.add(fingerprint)

        reply = client.preview_private_reply(
            contact_name=snapshot.contact_name,
            message_text=snapshot.latest_message,
            message_fingerprint=fingerprint,
        )
        _print_json({"event": "wechat.private.reply.generated", "reply": reply})

        if not reply.get("should_reply"):
            time.sleep(interval)
            continue
        if not reply.get("auto_reply_enabled"):
            _print_json(
                {
                    "event": "wechat.private.ignored",
                    "reason": "private_auto_reply_disabled",
                    "trace_id": reply.get("trace_id"),
                }
            )
            time.sleep(interval)
            continue
        if dry_run:
            _print_json({"event": "dry_run_skip_send", "trace_id": reply.get("trace_id")})
            time.sleep(interval)
            continue

        reply_text = str(reply.get("reply_text") or "").strip()
        ok, reason = automator.send_reply_to_current_private_chat(
            contact_name=snapshot.contact_name,
            reply_text=reply_text,
            allowlist=allowlist,
        )
        if ok:
            sent_texts.add(reply_text)
            client.record_private_sent(
                contact_name=snapshot.contact_name,
                trace_id=str(reply["trace_id"]),
                message_fingerprint=fingerprint,
            )
            _print_json({"event": "wechat.private.reply.sent", "trace_id": reply.get("trace_id")})
        else:
            _print_json(
                {
                    "event": "sidecar.private.ui.error",
                    "reason": reason,
                    "trace_id": reply.get("trace_id"),
                }
            )
        time.sleep(interval)


def _private_sidecar_fingerprint(*, contact_name: str, message_text: str) -> str:
    minute = datetime.now(tz=UTC).isoformat()[:16]
    raw = f"{contact_name}|{' '.join(message_text.split())}|{minute}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


if __name__ == "__main__":
    main()
