from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote

from aipet_bridge.audit_log import JsonlAuditLog


logger = logging.getLogger("aipet_wxauto_bridge_channel")


SELF_SENDERS = {"\u81ea\u5df1", "SelfMsg", "self"}


@dataclass(frozen=True)
class PrivateChatConfig:
    name: str
    enabled: bool = True
    whitelist: tuple[str, ...] = ()


@dataclass(frozen=True)
class GroupChatConfig:
    name: str
    enabled: bool = True
    reply_mode: str = "at_me_only"
    sender_whitelist: tuple[str, ...] = ()
    sender_blacklist: tuple[str, ...] = ()


@dataclass(frozen=True)
class ChannelConfig:
    wxapi_base_url: str = "http://127.0.0.1:8001"
    wxapi_token: str = ""
    bridge_url: str = "http://127.0.0.1:8787"
    pet_id: str = "cat-home"
    my_nickname: str = ""
    temp_dir: str = "./tmp"
    allowed_message_types: tuple[str, ...] = ("text",)
    require_openclaw_for_send: bool = True
    private_debounce_seconds: float = 3.0
    private_batch_max_wait_seconds: float = 8.0
    private_batch_max_messages: int = 8
    private_rate_limited_max_retries: int = 3
    private_rate_limited_fallback_retry_seconds: int = 15
    private_chats: tuple[PrivateChatConfig, ...] = ()
    group_chats: tuple[GroupChatConfig, ...] = ()

    @classmethod
    def from_yaml(
        cls,
        path: str | Path,
        *,
        bridge_url: str | None = None,
        pet_id: str | None = None,
    ) -> "ChannelConfig":
        try:
            import yaml
        except ImportError as exc:  # pragma: no cover - depends on local optional deps
            raise RuntimeError("PyYAML is required for wxauto channel config parsing.") from exc

        with Path(path).open("r", encoding="utf-8") as handle:
            data = yaml.safe_load(handle) or {}

        wxapi = data.get("wxapi", {}) or {}
        bridge = data.get("aipet_bridge", {}) or {}
        private_chats = tuple(
            PrivateChatConfig(
                name=str(item.get("name", "")).strip(),
                enabled=bool(item.get("enabled", True)),
                whitelist=_clean_tuple(item.get("whitelist")),
            )
            for item in data.get("private_chats", []) or []
            if str(item.get("name", "")).strip()
        )
        group_chats = tuple(
            GroupChatConfig(
                name=str(item.get("name", "")).strip(),
                enabled=bool(item.get("enabled", True)),
                reply_mode=_normalize_reply_mode(item.get("reply_mode", "at_me_only")),
                sender_whitelist=_clean_tuple(item.get("sender_whitelist")),
                sender_blacklist=_clean_tuple(item.get("sender_blacklist")),
            )
            for item in data.get("group_chats", []) or []
            if str(item.get("name", "")).strip()
        )
        return cls(
            wxapi_base_url=str(wxapi.get("base_url") or "http://127.0.0.1:8001").rstrip("/"),
            wxapi_token=str(wxapi.get("token") or ""),
            bridge_url=str(
                bridge_url
                or os.getenv("AIPET_BRIDGE_URL")
                or bridge.get("base_url")
                or "http://127.0.0.1:8787"
            ).rstrip("/"),
            pet_id=str(
                pet_id or os.getenv("AIPET_DEFAULT_PET_ID") or bridge.get("pet_id") or "cat-home"
            ),
            my_nickname=str(data.get("my_nickname") or ""),
            temp_dir=str(data.get("temp_dir") or "./tmp"),
            allowed_message_types=_clean_tuple(data.get("allowed_message_types")) or ("text",),
            require_openclaw_for_send=_as_bool(data.get("require_openclaw_for_send"), default=True),
            private_debounce_seconds=_bounded_float(
                data.get("private_debounce_seconds"),
                default=3.0,
                minimum=0.0,
                maximum=30.0,
            ),
            private_batch_max_wait_seconds=_bounded_float(
                data.get("private_batch_max_wait_seconds"),
                default=8.0,
                minimum=0.0,
                maximum=60.0,
            ),
            private_batch_max_messages=_bounded_int(
                data.get("private_batch_max_messages"),
                default=8,
                minimum=1,
                maximum=30,
            ),
            private_rate_limited_max_retries=_bounded_int(
                data.get("private_rate_limited_max_retries"),
                default=3,
                minimum=0,
                maximum=10,
            ),
            private_rate_limited_fallback_retry_seconds=_bounded_int(
                data.get("private_rate_limited_fallback_retry_seconds"),
                default=15,
                minimum=1,
                maximum=3600,
            ),
            private_chats=private_chats,
            group_chats=group_chats,
        )

    @property
    def target_names(self) -> tuple[str, ...]:
        return tuple(chat.name for chat in self.private_chats if chat.enabled) + tuple(
            chat.name for chat in self.group_chats if chat.enabled
        )


@dataclass(frozen=True)
class WxautoMessage:
    who: str
    sender: str
    content: str
    msg_type: str = "text"
    msg_id: str = ""
    msg_hash: str = ""
    message_time: str = ""
    chat_type: str = ""
    sender_remark: str = ""
    file_path: str | None = None
    retry_count: int = 0

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "WxautoMessage":
        return cls(
            who=str(data.get("who") or "").strip(),
            sender=str(data.get("sender") or "").strip(),
            content=str(data.get("content") or ""),
            msg_type=str(data.get("type") or data.get("msg_type") or "text"),
            msg_id=str(data.get("id") or data.get("msg_id") or ""),
            msg_hash=str(data.get("hash") or data.get("msg_hash") or ""),
            message_time=str(
                data.get("time")
                or data.get("message_time")
                or data.get("created_at")
                or data.get("timestamp")
                or ""
            ),
            chat_type=str(data.get("chat_type") or ""),
            sender_remark=str(data.get("sender_remark") or data.get("remark") or "").strip(),
            file_path=str(data.get("file_path") or data.get("path") or "") or None,
            retry_count=_safe_retry_count(data.get("_aipet_retry_count")),
        )

    @property
    def sender_aliases(self) -> tuple[str, ...]:
        aliases = [self.sender, self.sender_remark]
        return tuple(alias for alias in aliases if alias)

    @property
    def display_sender(self) -> str:
        return self.sender_remark or self.sender

    @property
    def message_identity(self) -> str:
        return self.msg_id or self.msg_hash

    @property
    def observed_at(self) -> str:
        return self.message_time.strip()


@dataclass
class HandleResult:
    action: str
    reason: str | None = None
    trace_id: str | None = None
    reply_text: str | None = None
    sent: bool = False
    decision: dict[str, Any] = field(default_factory=dict)


class MessageFilter:
    def __init__(self, config: ChannelConfig) -> None:
        self.config = config
        self._private = {chat.name: chat for chat in config.private_chats if chat.enabled}
        self._groups = {chat.name: chat for chat in config.group_chats if chat.enabled}

    def is_private(self, who: str) -> bool:
        return who in self._private

    def is_group(self, who: str) -> bool:
        return who in self._groups

    def should_consider_private(self, message: WxautoMessage) -> tuple[bool, str]:
        chat = self._private.get(message.who)
        if chat is None:
            return False, "private_not_configured"
        sender_aliases = set(message.sender_aliases)
        if chat.whitelist and not sender_aliases.intersection(chat.whitelist):
            return False, "private_sender_not_allowed"
        if not chat.whitelist and message.who not in sender_aliases:
            return False, "private_sender_mismatch"
        return True, "private_allowed"

    def should_consider_group(self, message: WxautoMessage) -> tuple[bool, str]:
        chat = self._groups.get(message.who)
        if chat is None:
            return False, "group_not_configured"
        sender_aliases = set(message.sender_aliases)
        if sender_aliases.intersection(chat.sender_blacklist):
            return False, "group_sender_blacklisted"
        if chat.sender_whitelist and not sender_aliases.intersection(chat.sender_whitelist):
            return False, "group_sender_not_allowed"
        reply_mode = _normalize_reply_mode(chat.reply_mode)
        if reply_mode == "at_me_only" and not is_mentioned(message.content, self.config.my_nickname):
            return False, "group_not_mentioned"
        return True, "group_allowed"


class BridgeClient:
    def __init__(self, *, base_url: str, pet_id: str, timeout_seconds: int = 60) -> None:
        self.base_url = base_url.rstrip("/")
        self.pet_id = pet_id
        self.timeout_seconds = timeout_seconds

    def private_reply(
        self,
        *,
        contact_name: str,
        message_text: str,
        message_fingerprint: str,
        observed_at: str,
        trace_id: str,
        recent_context: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        return self._post(
            f"/pets/{quote(self.pet_id, safe='')}/wechat/private-reply",
            {
                "contact_name": contact_name,
                "message_text": message_text,
                "observed_at": observed_at,
                "message_fingerprint": message_fingerprint,
                "trace_id": trace_id,
                "recent_context": recent_context or [],
            },
        )

    def group_reply(
        self,
        *,
        group_name: str,
        sender_name: str,
        message_text: str,
        mentioned: bool,
        message_fingerprint: str,
        observed_at: str,
        trace_id: str,
    ) -> dict[str, Any]:
        return self._post(
            f"/pets/{quote(self.pet_id, safe='')}/wechat/reply",
            {
                "group_name": group_name,
                "sender_name": sender_name,
                "message_text": message_text,
                "mentioned": mentioned,
                "observed_at": observed_at,
                "message_fingerprint": message_fingerprint,
                "trace_id": trace_id,
                "recent_context": [],
            },
        )

    def private_sent(
        self,
        *,
        contact_name: str,
        trace_id: str,
        message_fingerprint: str,
    ) -> dict[str, Any]:
        return self._post(
            f"/pets/{quote(self.pet_id, safe='')}/wechat/private-sent",
            {
                "contact_name": contact_name,
                "trace_id": trace_id,
                "message_fingerprint": message_fingerprint,
            },
        )

    def group_sent(
        self,
        *,
        group_name: str,
        trace_id: str,
        message_fingerprint: str,
    ) -> dict[str, Any]:
        return self._post(
            f"/pets/{quote(self.pet_id, safe='')}/wechat/sent",
            {
                "group_name": group_name,
                "trace_id": trace_id,
                "message_fingerprint": message_fingerprint,
            },
        )

    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        import requests

        response = requests.post(
            f"{self.base_url}{path}",
            json=payload,
            timeout=self.timeout_seconds,
        )
        response.raise_for_status()
        return response.json()


class WxautoClient:
    def __init__(self, *, base_url: str, token: str, timeout_seconds: int = 30) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        import requests

        response = requests.post(
            f"{self.base_url}{path}",
            headers=self.headers,
            json=payload,
            timeout=self.timeout_seconds,
        )
        response.raise_for_status()
        data = response.json()
        if isinstance(data, dict) and data.get("success") is False:
            message = str(data.get("message") or "wxauto API reported failure")
            raise RuntimeError(message)
        return data

    def health(self) -> bool:
        import requests

        try:
            response = requests.get(f"{self.base_url}/", timeout=5)
        except requests.RequestException:
            return False
        return response.status_code == 200

    def initialize_wechat(self) -> dict[str, Any]:
        return self._post("/v1/wechat/initialize", {})

    def chat_with(self, *, who: str) -> dict[str, Any]:
        return self._post("/v1/wechat/chatwith", {"who": who, "exact": True})

    def send_text(self, *, who: str, text: str) -> dict[str, Any]:
        try:
            return self._send_text_once(who=who, text=text)
        except Exception as exc:
            if not _is_recoverable_send_switch_error(exc):
                raise
            original_error = str(exc)

        try:
            self.initialize_wechat()
            self.chat_with(who=who)
            return self._send_text_once(who=who, text=text)
        except Exception as retry_exc:
            raise RuntimeError(
                f"{original_error}; retry after initialize/chatwith failed: {retry_exc}"
            ) from retry_exc

    def _send_text_once(self, *, who: str, text: str) -> dict[str, Any]:
        return self._post("/v1/wechat/send", {"who": who, "msg": text, "exact": True})


class AipetWxautoBridgeChannel:
    def __init__(
        self,
        *,
        config: ChannelConfig,
        bridge: BridgeClient | Any | None = None,
        wxauto: WxautoClient | Any | None = None,
        audit_log: JsonlAuditLog | None = None,
        dry_run: bool = False,
    ) -> None:
        self.config = config
        self.filter = MessageFilter(config)
        self.bridge = bridge or BridgeClient(base_url=config.bridge_url, pet_id=config.pet_id)
        self.wxauto = wxauto or WxautoClient(
            base_url=config.wxapi_base_url,
            token=config.wxapi_token,
        )
        self.audit_log = audit_log or JsonlAuditLog(Path(os.getenv("AIPET_LOGS_DIR", "logs")))
        self.dry_run = dry_run

    def handle_message(self, data: dict[str, Any]) -> HandleResult:
        message = WxautoMessage.from_dict(data)
        trace_id = stable_trace_id(message)

        if self._is_self_message(message):
            self._log_sidecar(
                "wechat.wxauto.ignored",
                trace_id,
                message,
                message_fingerprint_value=message_fingerprint(message),
                block_reason="self_message",
            )
            return HandleResult(action="ignored", reason="self_message", trace_id=trace_id)

        if not self._is_allowed_message_type(message):
            self._log_sidecar(
                "wechat.wxauto.ignored",
                trace_id,
                message,
                message_fingerprint_value=message_fingerprint(message),
                block_reason="unsupported_message_type",
            )
            return HandleResult(
                action="ignored",
                reason="unsupported_message_type",
                trace_id=trace_id,
            )

        if self.filter.is_group(message.who):
            return self._handle_group_message(message, trace_id)
        if self.filter.is_private(message.who):
            return self._handle_private_message(message, trace_id)

        self._log_sidecar(
            "wechat.wxauto.ignored",
            trace_id,
            message,
            message_fingerprint_value=message_fingerprint(message),
            block_reason="target_not_configured",
        )
        return HandleResult(action="ignored", reason="target_not_configured", trace_id=trace_id)

    async def run(self) -> None:
        if not self.wxauto.health():
            raise RuntimeError(f"wxauto API is not reachable: {self.config.wxapi_base_url}")
        self.wxauto.initialize_wechat()
        targets = self.config.target_names
        if not targets:
            raise RuntimeError("No wxauto private or group targets are configured.")

        logger.info("Starting AI Pet wxauto Bridge channel for %d target(s).", len(targets))
        await asyncio.gather(*(self._listen_one(target) for target in targets))

    def _handle_private_message(self, message: WxautoMessage, trace_id: str) -> HandleResult:
        allowed, reason = self.filter.should_consider_private(message)
        if not allowed:
            self._log_sidecar(
                "wechat.wxauto.ignored",
                trace_id,
                message,
                message_fingerprint_value=message_fingerprint(message),
                block_reason=reason,
            )
            return HandleResult(action="ignored", reason=reason, trace_id=trace_id)

        message_text = render_message_text(message)
        observed_at = message.observed_at or utc_now()
        fingerprint = message_fingerprint(message, observed_at=observed_at)
        self._log_sidecar(
            "wechat.wxauto.detected",
            trace_id,
            message,
            message_fingerprint_value=fingerprint,
        )
        decision = self.bridge.private_reply(
            contact_name=message.who,
            message_text=message_text,
            message_fingerprint=fingerprint,
            observed_at=observed_at,
            trace_id=trace_id,
        )
        return self._send_if_allowed(
            message=message,
            trace_id=str(decision.get("trace_id") or trace_id),
            fingerprint=fingerprint,
            decision=decision,
            is_private=True,
        )

    def _handle_private_message_batch_data(self, batch: list[dict[str, Any]]) -> HandleResult:
        eligible: list[WxautoMessage] = []
        last_result: HandleResult | None = None
        for data in batch:
            message = WxautoMessage.from_dict(data)
            allowed, _ = self._is_private_batch_candidate(message)
            if allowed:
                eligible.append(message)
            else:
                last_result = self.handle_message(data)

        if not eligible:
            return last_result or HandleResult(action="ignored", reason="empty_batch")
        return self._handle_private_message_batch(eligible)

    def _handle_private_message_batch(self, messages: list[WxautoMessage]) -> HandleResult:
        if not messages:
            return HandleResult(action="ignored", reason="empty_batch")

        contact_name = messages[-1].who
        retry_generation = max(_message_retry_count(message) for message in messages)
        trace_id = stable_batch_trace_id(messages, retry_generation=retry_generation)
        observed_at = messages[-1].observed_at or utc_now()
        fingerprint = message_batch_fingerprint(
            messages,
            observed_at=observed_at,
            retry_generation=retry_generation,
        )
        message_text = render_private_batch_text(messages)
        recent_context = [
            {
                "sender_name": message.display_sender,
                "text": render_message_text(message),
                "observed_at": message.observed_at,
            }
            for message in messages[-6:]
        ]
        representative = messages[-1]

        if len(messages) > 1 or retry_generation > 0:
            self._log_sidecar(
                "wechat.wxauto.private.batch_collected",
                trace_id,
                representative,
                message_fingerprint_value=fingerprint,
                batch_size=len(messages),
                retry_generation=retry_generation,
            )
        self._log_sidecar(
            "wechat.wxauto.detected",
            trace_id,
            representative,
            message_fingerprint_value=fingerprint,
            batch_size=len(messages),
            retry_generation=retry_generation,
        )
        decision = self.bridge.private_reply(
            contact_name=contact_name,
            message_text=message_text,
            message_fingerprint=fingerprint,
            observed_at=observed_at,
            trace_id=trace_id,
            recent_context=recent_context,
        )
        return self._send_if_allowed(
            message=representative,
            trace_id=str(decision.get("trace_id") or trace_id),
            fingerprint=fingerprint,
            decision=decision,
            is_private=True,
        )

    def _handle_group_message(self, message: WxautoMessage, trace_id: str) -> HandleResult:
        allowed, reason = self.filter.should_consider_group(message)
        if not allowed:
            self._log_sidecar(
                "wechat.wxauto.ignored",
                trace_id,
                message,
                message_fingerprint_value=message_fingerprint(message),
                block_reason=reason,
            )
            return HandleResult(action="ignored", reason=reason, trace_id=trace_id)

        message_text = render_message_text(message)
        observed_at = message.observed_at or utc_now()
        fingerprint = message_fingerprint(message, observed_at=observed_at)
        mentioned = is_mentioned(message.content, self.config.my_nickname)
        self._log_sidecar(
            "wechat.wxauto.detected",
            trace_id,
            message,
            message_fingerprint_value=fingerprint,
        )
        decision = self.bridge.group_reply(
            group_name=message.who,
            sender_name=message.display_sender,
            message_text=message_text,
            mentioned=mentioned,
            message_fingerprint=fingerprint,
            observed_at=observed_at,
            trace_id=trace_id,
        )
        return self._send_if_allowed(
            message=message,
            trace_id=str(decision.get("trace_id") or trace_id),
            fingerprint=fingerprint,
            decision=decision,
            is_private=False,
        )

    def _send_if_allowed(
        self,
        *,
        message: WxautoMessage,
        trace_id: str,
        fingerprint: str,
        decision: dict[str, Any],
        is_private: bool,
    ) -> HandleResult:
        if not decision.get("should_reply"):
            reason = str(decision.get("block_reason") or decision.get("reason") or "bridge_blocked")
            self._log_sidecar(
                "wechat.wxauto.bridge_blocked",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
                block_reason=reason,
            )
            return HandleResult(action="blocked", reason=reason, trace_id=trace_id, decision=decision)

        if decision.get("requires_manual_review"):
            self._log_sidecar(
                "wechat.wxauto.manual_review",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
            )
            return HandleResult(action="manual_review", trace_id=trace_id, decision=decision)

        if not decision.get("auto_reply_enabled"):
            self._log_sidecar(
                "wechat.wxauto.auto_disabled",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
            )
            return HandleResult(action="auto_disabled", trace_id=trace_id, decision=decision)

        reply_text = str(decision.get("reply_text") or "").strip()
        if not reply_text:
            self._log_sidecar(
                "wechat.wxauto.ignored",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
                block_reason="empty_reply",
            )
            return HandleResult(action="ignored", reason="empty_reply", trace_id=trace_id, decision=decision)

        if self.dry_run:
            self._log_sidecar(
                "wechat.wxauto.dry_run",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
            )
            return HandleResult(
                action="dry_run",
                trace_id=trace_id,
                reply_text=reply_text,
                sent=False,
                decision=decision,
            )

        model_source = str(decision.get("model_source") or "unknown")
        safe_fallback_send_allowed = bool(decision.get("safe_fallback_send_allowed"))
        if (
            self.config.require_openclaw_for_send
            and model_source != "openclaw"
            and not safe_fallback_send_allowed
        ):
            self._log_sidecar(
                "wechat.wxauto.model_path_blocked",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
                block_reason="openclaw_required",
                model_source=model_source,
                safe_fallback_send_allowed=safe_fallback_send_allowed,
            )
            return HandleResult(
                action="blocked",
                reason="openclaw_required",
                trace_id=trace_id,
                reply_text=reply_text,
                decision=decision,
            )
        if self.config.require_openclaw_for_send and model_source != "openclaw":
            self._log_sidecar(
                "wechat.wxauto.safe_fallback_send_allowed",
                trace_id,
                message,
                message_fingerprint_value=fingerprint,
                model_source=model_source,
                safe_fallback_send_allowed=safe_fallback_send_allowed,
            )

        try:
            self.wxauto.send_text(who=message.who, text=reply_text)
            if is_private:
                self.bridge.private_sent(
                    contact_name=message.who,
                    trace_id=trace_id,
                    message_fingerprint=fingerprint,
                )
            else:
                self.bridge.group_sent(
                    group_name=message.who,
                    trace_id=trace_id,
                    message_fingerprint=fingerprint,
                )
        except Exception as exc:
            self.audit_log.log(
                stream="errors",
                level="error",
                service="aipet-wxauto-bridge-channel",
                event="wechat.wxauto.send_failed",
                trace_id=trace_id,
                target_name=message.who,
                error=str(exc),
            )
            logger.exception("Failed to send wxauto reply to %s.", message.who)
            return HandleResult(
                action="send_failed",
                reason=str(exc),
                trace_id=trace_id,
                reply_text=reply_text,
                decision=decision,
            )

        self._log_sidecar(
            "wechat.wxauto.reply_sent",
            trace_id,
            message,
            message_fingerprint_value=fingerprint,
        )
        return HandleResult(
            action="sent",
            trace_id=trace_id,
            reply_text=reply_text,
            sent=True,
            decision=decision,
        )

    async def _listen_one(self, who: str) -> None:
        import websockets

        ws_url = build_listen_ws_url(self.config.wxapi_base_url, who, auto_start=True)
        retry_delay = 2
        message_queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=100)
        worker = asyncio.create_task(self._message_worker(who, message_queue))
        try:
            while True:
                try:
                    logger.info("Connecting wxauto WebSocket for %s.", who)
                    async with websockets.connect(
                        ws_url,
                        open_timeout=15,
                        ping_interval=20,
                        ping_timeout=60,
                        close_timeout=5,
                    ) as websocket:
                        retry_delay = 2
                        async for raw in websocket:
                            await self._handle_ws_payload(raw, message_queue=message_queue)
                except Exception as exc:
                    logger.warning(
                        "wxauto WebSocket for %s failed: %s. Retrying in %ss.",
                        who,
                        exc,
                        retry_delay,
                    )
                    await asyncio.sleep(retry_delay)
                    retry_delay = min(retry_delay * 2, 60)
        finally:
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker

    async def _message_worker(
        self,
        who: str,
        message_queue: asyncio.Queue[dict[str, Any]],
    ) -> None:
        loop = asyncio.get_running_loop()
        pending_private_batch: list[dict[str, Any]] | None = None
        pending_retry_delay = 0.0
        while True:
            if pending_private_batch is None:
                batch = [await message_queue.get()]
            else:
                if pending_retry_delay > 0:
                    await asyncio.sleep(pending_retry_delay)
                batch = pending_private_batch
                pending_private_batch = None
                pending_retry_delay = 0.0

            try:
                if self._is_private_batch_candidate_data(batch[0], expected_who=who):
                    batch = await self._collect_private_debounce_batch(who, message_queue, batch)
                    result = await loop.run_in_executor(
                        None,
                        self._handle_private_message_batch_data,
                        batch,
                    )
                    if self._should_retry_private_batch(result, batch):
                        pending_private_batch = _increment_batch_retry_count(batch)
                        pending_retry_delay = self._rate_limited_retry_delay(result)
                        self.audit_log.log(
                            stream="sidecar",
                            service="aipet-wxauto-bridge-channel",
                            event="wechat.wxauto.private.cooldown_queued",
                            trace_id=result.trace_id,
                            target_name=who,
                            block_reason="rate_limited",
                            retry_after_seconds=pending_retry_delay,
                            retry_generation=_batch_retry_count(pending_private_batch),
                            batch_size=len(pending_private_batch),
                        )
                        continue
                else:
                    await loop.run_in_executor(None, self.handle_message, batch[0])
            except Exception as exc:
                self.audit_log.log(
                    stream="sidecar",
                    level="error",
                    service="aipet-wxauto-bridge-channel",
                    event="wechat.wxauto.handler_error",
                    trace_id=_trace_id_from_ws_data(batch[0], fallback_prefix="handler-error"),
                    target_name=who,
                    error=str(exc)[:500],
                )
            finally:
                if pending_private_batch is None:
                    for _ in batch:
                        message_queue.task_done()

    async def _collect_private_debounce_batch(
        self,
        who: str,
        message_queue: asyncio.Queue[dict[str, Any]],
        batch: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        debounce_seconds = self.config.private_debounce_seconds
        max_wait_seconds = self.config.private_batch_max_wait_seconds
        max_messages = self.config.private_batch_max_messages
        if debounce_seconds <= 0 or len(batch) >= max_messages:
            return batch

        loop = asyncio.get_running_loop()
        hard_deadline = loop.time() + max_wait_seconds if max_wait_seconds > 0 else loop.time()
        deadline = min(loop.time() + debounce_seconds, hard_deadline)
        while len(batch) < max_messages:
            timeout = deadline - loop.time()
            if timeout <= 0:
                break
            try:
                item = await asyncio.wait_for(message_queue.get(), timeout=timeout)
            except TimeoutError:
                break
            batch.append(item)
            if not self._is_private_batch_candidate_data(item, expected_who=who):
                continue
            deadline = min(loop.time() + debounce_seconds, hard_deadline)
        return batch

    async def _handle_ws_payload(
        self,
        raw: str,
        *,
        message_queue: asyncio.Queue[dict[str, Any]] | None = None,
    ) -> None:
        try:
            envelope = json.loads(raw)
        except json.JSONDecodeError:
            return
        event_type = envelope.get("type")
        if event_type != "message":
            if event_type in {"status", "warning", "error"}:
                self._log_ws_event(str(event_type), envelope.get("data"))
            return
        data = envelope.get("data")
        if not isinstance(data, dict):
            return
        if message_queue is not None:
            try:
                message_queue.put_nowait(data)
            except asyncio.QueueFull:
                self.audit_log.log(
                    stream="sidecar",
                    level="warning",
                    service="aipet-wxauto-bridge-channel",
                    event="wechat.wxauto.queue_full",
                    trace_id=_trace_id_from_ws_data(data, fallback_prefix="queue-full"),
                    target_name=str(data.get("who") or ""),
                )
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self.handle_message, data)

    def _is_private_batch_candidate_data(
        self,
        data: dict[str, Any],
        *,
        expected_who: str | None = None,
    ) -> bool:
        try:
            message = WxautoMessage.from_dict(data)
        except Exception:
            return False
        allowed, _ = self._is_private_batch_candidate(message, expected_who=expected_who)
        return allowed

    def _is_private_batch_candidate(
        self,
        message: WxautoMessage,
        *,
        expected_who: str | None = None,
    ) -> tuple[bool, str]:
        if expected_who and message.who != expected_who:
            return False, "target_mismatch"
        if self._is_self_message(message):
            return False, "self_message"
        if not self._is_allowed_message_type(message):
            return False, "unsupported_message_type"
        if not self.filter.is_private(message.who):
            return False, "not_private_chat"
        return self.filter.should_consider_private(message)

    def _should_retry_private_batch(
        self,
        result: HandleResult,
        batch: list[dict[str, Any]],
    ) -> bool:
        if result.action != "blocked" or result.reason != "rate_limited":
            return False
        if not batch:
            return False
        retry_count = _batch_retry_count(batch)
        return retry_count < self.config.private_rate_limited_max_retries

    def _rate_limited_retry_delay(self, result: HandleResult) -> float:
        raw_delay = result.decision.get("retry_after_seconds")
        try:
            delay = float(raw_delay)
        except (TypeError, ValueError):
            delay = float(self.config.private_rate_limited_fallback_retry_seconds)
        return max(1.0, min(3600.0, delay))

    def _is_self_message(self, message: WxautoMessage) -> bool:
        sender_aliases = set(message.sender_aliases)
        if sender_aliases.intersection(SELF_SENDERS):
            return True
        return bool(self.config.my_nickname and self.config.my_nickname in sender_aliases)

    def _is_allowed_message_type(self, message: WxautoMessage) -> bool:
        return message.msg_type in set(self.config.allowed_message_types)

    def _log_sidecar(
        self,
        event: str,
        trace_id: str,
        message: WxautoMessage,
        message_fingerprint_value: str,
        **fields: Any,
    ) -> None:
        self.audit_log.log(
            stream="sidecar",
            service="aipet-wxauto-bridge-channel",
            event=event,
            trace_id=trace_id,
            target_name=message.who,
            sender_name=message.sender,
            sender_remark=message.sender_remark,
            message_type=message.msg_type,
            message_fingerprint=message_fingerprint_value,
            **fields,
        )

    def _log_ws_event(self, event_type: str, data: Any) -> None:
        payload = data if isinstance(data, dict) else {"message": str(data or "")}
        target_name = str(payload.get("who") or payload.get("target_name") or "")
        trace_raw = "|".join(
            [
                "wxauto-ws",
                event_type,
                target_name,
                str(payload.get("status") or ""),
                str(payload.get("message") or "")[:120],
            ]
        )
        trace_id = hashlib.sha256(trace_raw.encode("utf-8")).hexdigest()[:32]
        fields: dict[str, Any] = {
            "target_name": target_name,
            "status": str(payload.get("status") or ""),
        }
        if payload.get("message"):
            fields["message_text"] = str(payload.get("message"))
        if payload.get("client_id"):
            fields["client_id"] = str(payload.get("client_id"))
        self.audit_log.log(
            stream="sidecar",
            level="warning" if event_type in {"warning", "error"} else "info",
            service="aipet-wxauto-bridge-channel",
            event=f"wechat.wxauto.ws_{event_type}",
            trace_id=trace_id,
            **fields,
        )


def render_message_text(message: WxautoMessage) -> str:
    if message.msg_type == "text":
        return message.content.strip()
    parts = [f"[{message.msg_type}]"]
    if message.content.strip():
        parts.append(message.content.strip())
    if message.file_path:
        parts.append(f"file={Path(message.file_path).name}")
    return " ".join(parts).strip()


def render_private_batch_text(messages: list[WxautoMessage]) -> str:
    parts = [render_message_text(message) for message in messages]
    parts = [part for part in parts if part]
    if len(parts) <= 1:
        return parts[0] if parts else ""
    lines = ["连续消息（请合并理解后回复）："]
    lines.extend(f"{index}. {text}" for index, text in enumerate(parts, start=1))
    return "\n".join(lines)


def is_mentioned(content: str, nickname: str) -> bool:
    nickname = nickname.strip()
    if not nickname:
        return False
    normalized = content.replace("\uff20", "@")
    spacing = r"[\s\u200b\u200c\u200d\ufeff]*"
    boundary = r"(?=$|[\s\u200b\u200c\u200d\ufeff:\uFF1A,\uFF0C.!\uFF01?\uFF1F])"
    pattern = rf"@{spacing}{re.escape(nickname)}{boundary}"
    return re.search(pattern, normalized) is not None


def build_listen_ws_url(base_url: str, who: str, *, auto_start: bool = True) -> str:
    ws_base = base_url.rstrip("/")
    if ws_base.startswith("https://"):
        ws_base = "wss://" + ws_base[len("https://") :]
    elif ws_base.startswith("http://"):
        ws_base = "ws://" + ws_base[len("http://") :]
    auto_start_value = "true" if auto_start else "false"
    return f"{ws_base}/v1/listen/ws?who={quote(who, safe='')}&auto_start={auto_start_value}"


def stable_trace_id(message: WxautoMessage) -> str:
    raw = "|".join(
        [
            message.who,
            message.sender,
            message.message_identity,
            message.observed_at,
            message.content[:120],
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def stable_batch_trace_id(
    messages: list[WxautoMessage],
    *,
    retry_generation: int = 0,
) -> str:
    raw = "|".join(
        [
            "wxauto-batch",
            str(retry_generation),
            *[stable_trace_id(message) for message in messages],
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def _trace_id_from_ws_data(data: dict[str, Any], *, fallback_prefix: str) -> str:
    try:
        return stable_trace_id(WxautoMessage.from_dict(data))
    except Exception:
        raw = json.dumps(data, ensure_ascii=False, sort_keys=True, default=str)
        return hashlib.sha256(f"{fallback_prefix}|{raw}".encode("utf-8")).hexdigest()[:32]


def message_fingerprint(message: WxautoMessage, observed_at: str | None = None) -> str:
    time_bucket = ""
    if not message.msg_id and observed_at:
        time_bucket = observed_at[:16]
    raw = "|".join(
        [
            "wxauto",
            message.who,
            message.sender,
            message.msg_type,
            message.message_identity,
            message.observed_at,
            time_bucket,
            " ".join(message.content.split()),
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def message_batch_fingerprint(
    messages: list[WxautoMessage],
    *,
    observed_at: str | None = None,
    retry_generation: int = 0,
) -> str:
    raw = "|".join(
        [
            "wxauto-batch",
            str(retry_generation),
            *[
                message_fingerprint(message, observed_at=message.observed_at or observed_at)
                for message in messages
            ],
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def _safe_retry_count(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


def _message_retry_count(message: WxautoMessage) -> int:
    return max(0, int(message.retry_count or 0))


def _batch_retry_count(batch: list[dict[str, Any]]) -> int:
    return max((_safe_retry_count(item.get("_aipet_retry_count")) for item in batch), default=0)


def _increment_batch_retry_count(batch: list[dict[str, Any]]) -> list[dict[str, Any]]:
    next_retry_count = _batch_retry_count(batch) + 1
    updated: list[dict[str, Any]] = []
    for item in batch:
        clone = dict(item)
        clone["_aipet_retry_count"] = next_retry_count
        updated.append(clone)
    return updated


_RECOVERABLE_SEND_SWITCH_MARKERS = (
    "\u5207\u6362\u804a\u5929\u5bf9\u8c61\u5931\u8d25",
    "\u53d6\u6d88\u53d1\u9001",
    "\u65e0\u6548\u7684\u7a97\u53e3\u53e5\u67c4",
    "MoveWindow",
)


def _is_recoverable_send_switch_error(exc: Exception) -> bool:
    message = str(exc)
    return bool(message) and any(
        marker in message for marker in _RECOVERABLE_SEND_SWITCH_MARKERS
    )


def utc_now() -> str:
    return datetime.now(tz=UTC).replace(microsecond=0).isoformat()


def _clean_tuple(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        raw_items = [value]
    elif isinstance(value, list | tuple):
        raw_items = list(value)
    else:
        raw_items = []

    cleaned: list[str] = []
    for item in raw_items:
        normalized = (
            str(item)
            .replace("\r", "\n")
            .replace("\uff0c", ",")
            .replace("，", ",")
            .replace("\\uff1b", ";")
            .replace("；", ";")
            .replace(";", ",")
            .replace("\n", ",")
        )
        cleaned.extend(part.strip() for part in normalized.split(",") if part.strip())
    return tuple(cleaned)


def _as_bool(value: Any, *, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _bounded_float(value: Any, *, default: float, minimum: float, maximum: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = default
    return min(maximum, max(minimum, number))


def _bounded_int(value: Any, *, default: int, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    return min(maximum, max(minimum, number))


def _normalize_reply_mode(value: Any) -> str:
    normalized = str(value or "").strip().lower().replace("-", "_")
    if normalized == "all":
        return "all"
    return "at_me_only"
