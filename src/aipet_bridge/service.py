from __future__ import annotations

import json
from typing import Any

from .audit_log import JsonlAuditLog, summarize_text
from .config import Settings
from .models import PetProfile
from .openclaw import OpenClawClient, OpenClawClientError
from .persona import build_persona_profile, build_system_prompt
from .storage import SQLiteStore
from .wechat import (
    build_user_prompt,
    fallback_reply,
    message_fingerprint,
    normalize_wechat_settings,
    private_message_fingerprint,
    should_reply_to_private_message,
    should_reply_to_message,
    utc_iso_minutes_ago,
    utc_iso_today_start,
)


class AipetBridgeService:
    def __init__(
        self,
        settings: Settings,
        store: SQLiteStore,
        audit_log: JsonlAuditLog | None = None,
        openclaw: OpenClawClient | None = None,
    ) -> None:
        self.settings = settings
        self.store = store
        self.audit_log = audit_log or JsonlAuditLog(
            settings.logs_dir,
            log_sensitive=settings.log_sensitive,
        )
        self.openclaw = openclaw or OpenClawClient(settings)

    def initialize(self) -> None:
        self.store.init_schema()
        if self.store.get_pet_profile(self.settings.default_pet_id) is None:
            self.store.upsert_pet_profile(
                PetProfile(
                    id=self.settings.default_pet_id,
                    name=self.settings.default_pet_name,
                    species="cat",
                    personality="真实家庭猫咪账号，默认低频、温和、受控互动。",
                )
            )
        if self.store.get_wechat_settings(self.settings.default_pet_id) is None:
            self.store.upsert_wechat_settings(
                pet_id=self.settings.default_pet_id,
                settings=normalize_wechat_settings(
                    {
                        "pet_wechat_name": self.settings.default_pet_name,
                        "wake_words": [self.settings.default_pet_name, "猫咪", "喵喵"],
                    }
                ),
            )

    def upsert_pet_profile(self, profile: PetProfile) -> dict[str, Any]:
        saved = self.store.upsert_pet_profile(profile)
        self.audit_log.log(
            stream="bridge",
            service="aipet-bridge",
            event="profile.upserted",
            pet_id=profile.id,
        )
        return saved.to_dict()

    def get_pet_current_state(self, pet_id: str) -> dict[str, Any]:
        profile = self.store.get_pet_profile(pet_id)
        if profile is None:
            raise KeyError(f"Unknown pet_id: {pet_id}")

        recent_events = self.store.list_recent_events(pet_id, limit=10)
        status = "unknown"
        last_seen_at: str | None = None
        latest_summary: str | None = None

        for event in recent_events:
            if event.event_type in {"feeding", "eating"}:
                status = "eating"
            elif event.event_type in {"drinking"}:
                status = "drinking"
            elif event.event_type in {"litter_box"}:
                status = "litter_box"
            elif event.event_type in {"meowing"}:
                status = "meowing"
            elif event.event_type in {"possible_distress"}:
                status = "possible_distress"
            elif event.event_type in {"camera_seen", "active", "sleeping"}:
                status = event.event_type

            if latest_summary is None:
                latest_summary = event.summary

            if last_seen_at is None and event.event_type in {
                "camera_seen",
                "active",
                "sleeping",
                "eating",
                "feeding",
                "drinking",
                "litter_box",
                "meowing",
            }:
                last_seen_at = event.event_time

        return {
            "pet": profile.to_dict(),
            "status": status,
            "last_seen_at": last_seen_at,
            "latest_summary": latest_summary,
            "recent_events": [event.to_dict() for event in recent_events],
        }

    def add_event(
        self,
        *,
        pet_id: str,
        event_type: str,
        source: str,
        summary: str,
        payload: dict[str, Any] | None = None,
        next_due_at: str | None = None,
    ) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        event = self.store.add_event(
            pet_id=pet_id,
            event_type=event_type,
            source=source,
            summary=summary,
            payload=payload,
            next_due_at=next_due_at,
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="pet.event.added",
            pet_id=pet_id,
            event_type=event_type,
            summary=summary,
        )
        return event.to_dict()

    def add_memory(
        self,
        *,
        pet_id: str,
        text: str,
        tags: list[str] | None = None,
        importance: int = 1,
        source: str | None = None,
    ) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        note = self.store.add_memory(
            pet_id=pet_id,
            text=text,
            tags=tags,
            importance=importance,
            source=source,
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="memory.write",
            pet_id=pet_id,
            importance=importance,
            tags=tags or [],
            text=text,
        )
        return note.to_dict()

    def search_memories(
        self,
        pet_id: str,
        query: str | None = None,
        limit: int = 10,
    ) -> list[dict[str, Any]]:
        self._ensure_pet_exists(pet_id)
        memories = [note.to_dict() for note in self.store.search_memories(pet_id, query, limit)]
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="memory.read",
            pet_id=pet_id,
            query_summary=summarize_text(query or ""),
            count=len(memories),
        )
        return memories

    def generate_persona(
        self,
        *,
        pet_id: str,
        answers: dict[str, int],
        open_answers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        profile = self._ensure_pet_exists(pet_id)
        persona = build_persona_profile(
            pet_id=pet_id,
            pet_name=profile.name,
            species=profile.species,
            answers=answers,
            open_answers=open_answers,
        )
        saved = self.store.upsert_persona(
            pet_id=pet_id,
            profile=persona,
            system_prompt=persona["system_prompt"],
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="persona.generated",
            pet_id=pet_id,
            type_code=persona["type_code"],
        )
        return saved

    def get_persona(self, pet_id: str) -> dict[str, Any]:
        profile = self._ensure_pet_exists(pet_id)
        persona = self.store.get_persona(pet_id)
        if persona is not None:
            return persona
        default_profile = build_persona_profile(
            pet_id=pet_id,
            pet_name=profile.name,
            species=profile.species,
            answers={},
            open_answers={},
        )
        return {
            "profile": default_profile,
            "system_prompt": default_profile["system_prompt"],
            "updated_at": default_profile["created_at"],
        }

    def get_wechat_settings(self, pet_id: str) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        stored = self.store.get_wechat_settings(pet_id)
        settings = normalize_wechat_settings(stored["settings"] if stored else None)
        return {"settings": settings, "updated_at": stored["updated_at"] if stored else None}

    def save_wechat_settings(self, *, pet_id: str, settings: dict[str, Any]) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        normalized = normalize_wechat_settings(settings)
        saved = self.store.upsert_wechat_settings(pet_id=pet_id, settings=normalized)
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="wechat.settings.updated",
            pet_id=pet_id,
            family_groups=normalized["family_groups"],
            private_contact_allowlist=normalized["private_contact_allowlist"],
            manual_review=normalized["manual_review"],
            auto_reply_enabled=normalized["auto_reply_enabled"],
            private_auto_reply_enabled=normalized["private_auto_reply_enabled"],
            emergency_stop=normalized["emergency_stop"],
        )
        return saved

    def preview_wechat_reply(
        self,
        *,
        pet_id: str,
        group_name: str,
        sender_name: str,
        message_text: str,
        recent_context: list[dict[str, Any]] | None = None,
        mentioned: bool = False,
        observed_at: str | None = None,
        message_fingerprint_value: str | None = None,
        trace_id: str | None = None,
    ) -> dict[str, Any]:
        trace_id = trace_id or self.audit_log.new_trace_id()
        profile = self._ensure_pet_exists(pet_id)
        settings = self.get_wechat_settings(pet_id)["settings"]
        recent_context = recent_context or []
        fingerprint = message_fingerprint_value or message_fingerprint(
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            message_text=message_text,
            observed_at=observed_at,
        )

        self.audit_log.log(
            stream="sidecar",
            service="wechat-sidecar",
            event="wechat.message.detected",
            trace_id=trace_id,
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            message_fingerprint=fingerprint,
            message_text=message_text,
        )

        if not self.store.try_mark_wechat_message_seen(
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            fingerprint=fingerprint,
            summary=summarize_text(message_text),
        ):
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=group_name,
                sender_name=sender_name,
                fingerprint=fingerprint,
                reason="duplicate_message",
            )

        allowed, reason = should_reply_to_message(
            settings=settings,
            group_name=group_name,
            sender_name=sender_name,
            message_text=message_text,
            mentioned=mentioned,
        )
        if not allowed:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=group_name,
                sender_name=sender_name,
                fingerprint=fingerprint,
                reason=reason,
            )

        rate_reason = self._rate_limit_reason(
            pet_id=pet_id,
            group_name=group_name,
            settings=settings,
        )
        if rate_reason:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=group_name,
                sender_name=sender_name,
                fingerprint=fingerprint,
                reason=rate_reason,
            )

        safety_reason = self._safety_block_reason(message_text)
        if safety_reason:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=group_name,
                sender_name=sender_name,
                fingerprint=fingerprint,
                reason=safety_reason,
                event="bridge.safety.blocked",
            )

        persona = self.get_persona(pet_id)
        pet_state = self.get_pet_current_state(pet_id)
        memories = self.search_memories(pet_id, query=message_text[:20], limit=5)
        system_prompt = persona["system_prompt"] or build_system_prompt(persona["profile"])
        user_prompt = build_user_prompt(
            pet_state=pet_state,
            memories=memories,
            group_name=group_name,
            sender_name=sender_name,
            message_text=message_text,
            recent_context=recent_context,
            max_reply_chars=settings["max_reply_chars"],
        )

        self.audit_log.log(
            stream="bridge",
            service="aipet-bridge",
            event="bridge.reply.started",
            trace_id=trace_id,
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            message_fingerprint=fingerprint,
        )
        reply_text, model_source = self._generate_reply(
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            pet_name=profile.name,
            sender_name=sender_name,
            message_text=message_text,
            max_chars=settings["max_reply_chars"],
            trace_id=trace_id,
            pet_id=pet_id,
        )
        status = "manual_review" if settings["manual_review"] else "generated"
        self.store.record_wechat_reply(
            pet_id=pet_id,
            group_name=group_name,
            trace_id=trace_id,
            status=status,
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="wechat.reply.requested",
            trace_id=trace_id,
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            message_fingerprint=fingerprint,
            result=status,
            model_source=model_source,
            reply_text=reply_text,
        )
        return {
            "trace_id": trace_id,
            "should_reply": True,
            "reply_text": reply_text,
            "requires_manual_review": bool(settings["manual_review"]),
            "auto_reply_enabled": bool(settings["auto_reply_enabled"]),
            "block_reason": None,
            "reason": reason,
            "message_fingerprint": fingerprint,
            "model_source": model_source,
        }

    def preview_private_reply(
        self,
        *,
        pet_id: str,
        contact_name: str,
        message_text: str,
        recent_context: list[dict[str, Any]] | None = None,
        observed_at: str | None = None,
        message_fingerprint_value: str | None = None,
        trace_id: str | None = None,
    ) -> dict[str, Any]:
        trace_id = trace_id or self.audit_log.new_trace_id()
        profile = self._ensure_pet_exists(pet_id)
        settings = self.get_wechat_settings(pet_id)["settings"]
        recent_context = recent_context or []
        channel_name = f"private:{contact_name}"
        fingerprint = message_fingerprint_value or private_message_fingerprint(
            pet_id=pet_id,
            contact_name=contact_name,
            message_text=message_text,
            observed_at=observed_at,
        )

        self.audit_log.log(
            stream="sidecar",
            service="wechat-sidecar",
            event="wechat.private.detected",
            trace_id=trace_id,
            pet_id=pet_id,
            contact_name=contact_name,
            message_fingerprint=fingerprint,
            message_text=message_text,
        )

        if not self.store.try_mark_wechat_message_seen(
            pet_id=pet_id,
            group_name=channel_name,
            sender_name=contact_name,
            fingerprint=fingerprint,
            summary=summarize_text(message_text),
        ):
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=channel_name,
                sender_name=contact_name,
                fingerprint=fingerprint,
                reason="duplicate_message",
                event="wechat.private.ignored",
            )

        allowed, reason = should_reply_to_private_message(
            settings=settings,
            contact_name=contact_name,
            message_text=message_text,
        )
        if not allowed:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=channel_name,
                sender_name=contact_name,
                fingerprint=fingerprint,
                reason=reason,
                event="wechat.private.ignored",
            )

        rate_reason = self._private_rate_limit_reason(
            pet_id=pet_id,
            contact_name=contact_name,
            settings=settings,
        )
        if rate_reason:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=channel_name,
                sender_name=contact_name,
                fingerprint=fingerprint,
                reason=rate_reason,
                event="wechat.private.ignored",
            )

        safety_reason = self._safety_block_reason(message_text)
        if safety_reason:
            return self._blocked_reply(
                trace_id=trace_id,
                pet_id=pet_id,
                group_name=channel_name,
                sender_name=contact_name,
                fingerprint=fingerprint,
                reason=safety_reason,
                event="bridge.safety.blocked",
            )

        persona = self.get_persona(pet_id)
        pet_state = self.get_pet_current_state(pet_id)
        memories = self.search_memories(pet_id, query=message_text[:20], limit=5)
        system_prompt = persona["system_prompt"] or build_system_prompt(persona["profile"])
        user_prompt = build_user_prompt(
            pet_state=pet_state,
            memories=memories,
            group_name=f"微信私聊：{contact_name}",
            sender_name=contact_name,
            message_text=message_text,
            recent_context=recent_context,
            max_reply_chars=settings["max_reply_chars"],
        )

        self.audit_log.log(
            stream="bridge",
            service="aipet-bridge",
            event="bridge.reply.started",
            trace_id=trace_id,
            pet_id=pet_id,
            contact_name=contact_name,
            message_fingerprint=fingerprint,
        )
        reply_text, model_source = self._generate_reply(
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            pet_name=profile.name,
            sender_name=contact_name,
            message_text=message_text,
            max_chars=settings["max_reply_chars"],
            trace_id=trace_id,
            pet_id=pet_id,
        )
        self.store.record_wechat_reply(
            pet_id=pet_id,
            group_name=channel_name,
            trace_id=trace_id,
            status="private_generated",
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event="wechat.private.reply.generated",
            trace_id=trace_id,
            pet_id=pet_id,
            contact_name=contact_name,
            message_fingerprint=fingerprint,
            result="generated",
            model_source=model_source,
            reply_text=reply_text,
        )
        return {
            "trace_id": trace_id,
            "should_reply": True,
            "reply_text": reply_text,
            "requires_manual_review": False,
            "auto_reply_enabled": bool(settings["private_auto_reply_enabled"]),
            "block_reason": None,
            "reason": reason,
            "message_fingerprint": fingerprint,
            "model_source": model_source,
            "contact_name": contact_name,
        }

    def query_logs(
        self,
        *,
        trace_id: str | None = None,
        service: str | None = None,
        level: str | None = None,
        event: str | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        return self.audit_log.query(
            trace_id=trace_id,
            service=service,
            level=level,
            event=event,
            limit=limit,
        )

    def record_manual_decision(
        self,
        *,
        pet_id: str,
        trace_id: str,
        group_name: str,
        decision: str,
        note: str | None = None,
    ) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        event = "wechat.manual.approved" if decision == "approved" else "wechat.manual.rejected"
        self.store.record_wechat_reply(
            pet_id=pet_id,
            group_name=group_name,
            trace_id=trace_id,
            status=event,
        )
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event=event,
            trace_id=trace_id,
            pet_id=pet_id,
            group_name=group_name,
            result=decision,
            note=note,
        )
        return {"trace_id": trace_id, "decision": decision, "recorded": True}

    def record_private_sent(
        self,
        *,
        pet_id: str,
        contact_name: str,
        trace_id: str,
        message_fingerprint: str,
    ) -> dict[str, Any]:
        self._ensure_pet_exists(pet_id)
        channel_name = f"private:{contact_name}"
        self.store.record_wechat_reply(
            pet_id=pet_id,
            group_name=channel_name,
            trace_id=trace_id,
            status="private_sent",
        )
        self.audit_log.log(
            stream="audit",
            service="wechat-sidecar",
            event="wechat.private.reply.sent",
            trace_id=trace_id,
            pet_id=pet_id,
            contact_name=contact_name,
            message_fingerprint=message_fingerprint,
            result="sent",
        )
        return {"trace_id": trace_id, "contact_name": contact_name, "recorded": True}

    def seed_demo_data(self) -> None:
        pet_id = self.settings.default_pet_id
        self.add_event(
            pet_id=pet_id,
            event_type="feeding",
            source="demo",
            summary="刚刚模拟了一次喂食事件。",
            payload={"portion_grams": 18},
        )
        self.add_memory(
            pet_id=pet_id,
            text="家人经常假装给猫咪打电话吐槽，这是 AI 宠项目的起点。",
            tags=["家庭梗", "项目起源"],
            importance=5,
            source="demo",
        )

    def _generate_reply(
        self,
        *,
        system_prompt: str,
        user_prompt: str,
        pet_name: str,
        sender_name: str,
        message_text: str,
        max_chars: int,
        trace_id: str,
        pet_id: str,
    ) -> tuple[str, str]:
        try:
            reply = self.openclaw.chat(system_prompt=system_prompt, user_prompt=user_prompt)
            reply = " ".join(reply.split())[:max_chars]
            self.audit_log.log(
                stream="bridge",
                service="aipet-bridge",
                event="bridge.openclaw.completed",
                trace_id=trace_id,
                pet_id=pet_id,
                result="ok",
            )
            return reply, "openclaw"
        except OpenClawClientError as exc:
            self.audit_log.log(
                stream="errors",
                level="error",
                service="aipet-bridge",
                event="bridge.openclaw.failed",
                trace_id=trace_id,
                pet_id=pet_id,
                error=str(exc),
            )
            return (
                fallback_reply(
                    pet_name=pet_name,
                    sender_name=sender_name,
                    message_text=message_text,
                    max_chars=max_chars,
                ),
                "local_fallback",
            )

    def _blocked_reply(
        self,
        *,
        trace_id: str,
        pet_id: str,
        group_name: str,
        sender_name: str,
        fingerprint: str,
        reason: str,
        event: str = "wechat.message.ignored",
    ) -> dict[str, Any]:
        self.audit_log.log(
            stream="audit",
            service="aipet-bridge",
            event=event,
            trace_id=trace_id,
            pet_id=pet_id,
            group_name=group_name,
            sender_name=sender_name,
            message_fingerprint=fingerprint,
            result="blocked",
            block_reason=reason,
        )
        return {
            "trace_id": trace_id,
            "should_reply": False,
            "reply_text": None,
            "requires_manual_review": True,
            "auto_reply_enabled": False,
            "block_reason": reason,
            "reason": reason,
            "message_fingerprint": fingerprint,
            "model_source": None,
        }

    def _rate_limit_reason(self, *, pet_id: str, group_name: str, settings: dict[str, Any]) -> str | None:
        recent_count = self.store.count_wechat_replies_since(
            pet_id=pet_id,
            group_name=group_name,
            since_iso=utc_iso_minutes_ago(int(settings["rate_limit_minutes"])),
        )
        if recent_count > 0:
            self.audit_log.log(
                stream="audit",
                service="aipet-bridge",
                event="bridge.rate_limited",
                pet_id=pet_id,
                group_name=group_name,
                result="blocked",
                recent_count=recent_count,
            )
            return "rate_limited"
        today_count = self.store.count_wechat_replies_since(
            pet_id=pet_id,
            group_name=None,
            since_iso=utc_iso_today_start(),
        )
        if today_count >= int(settings["daily_limit"]):
            return "daily_limit_reached"
        return None

    def _private_rate_limit_reason(
        self,
        *,
        pet_id: str,
        contact_name: str,
        settings: dict[str, Any],
    ) -> str | None:
        channel_name = f"private:{contact_name}"
        statuses = ("private_generated", "private_sent", "private_manual_review")
        recent_count = self.store.count_wechat_replies_since(
            pet_id=pet_id,
            group_name=channel_name,
            since_iso=utc_iso_minutes_ago(int(settings["private_rate_limit_minutes"])),
            statuses=statuses,
        )
        if recent_count > 0:
            self.audit_log.log(
                stream="audit",
                service="aipet-bridge",
                event="bridge.rate_limited",
                pet_id=pet_id,
                contact_name=contact_name,
                result="blocked",
                recent_count=recent_count,
            )
            return "rate_limited"
        today_count = self.store.count_wechat_replies_since(
            pet_id=pet_id,
            group_name=None,
            since_iso=utc_iso_today_start(),
            statuses=statuses,
        )
        if today_count >= int(settings["private_daily_limit"]):
            return "private_daily_limit_reached"
        return None

    def _safety_block_reason(self, message_text: str) -> str | None:
        lowered = message_text.lower()
        high_risk_keywords = {
            "开门": "unsafe_device_control",
            "门锁": "unsafe_device_control",
            "转账": "financial_request",
            "付款": "financial_request",
            "银行卡": "financial_request",
            "密码": "privacy_request",
            "验证码": "privacy_request",
            "摄像头画面": "privacy_request",
            "地址": "privacy_request",
            "吃什么药": "medical_request",
            "用药": "medical_request",
            "剂量": "medical_request",
        }
        for keyword, reason in high_risk_keywords.items():
            if keyword in lowered or keyword in message_text:
                return reason
        return None

    def _ensure_pet_exists(self, pet_id: str) -> PetProfile:
        profile = self.store.get_pet_profile(pet_id)
        if profile is None:
            raise KeyError(f"Unknown pet_id: {pet_id}")
        return profile


def decode_event_payload(payload_json: str | None) -> dict[str, Any] | None:
    if payload_json is None:
        return None
    return json.loads(payload_json)
