from __future__ import annotations

import hashlib
from datetime import UTC, datetime, time, timedelta
from typing import Any

from .audit_log import summarize_text


DEFAULT_WECHAT_SETTINGS: dict[str, Any] = {
    "pet_wechat_name": "",
    "family_groups": [],
    "private_contact_allowlist": [],
    "wake_words": ["猫咪", "喵喵", "猫猫"],
    "require_mention": True,
    "manual_review": True,
    "auto_reply_enabled": False,
    "private_auto_reply_enabled": False,
    "emergency_stop": False,
    "quiet_hours_start": "23:00",
    "quiet_hours_end": "08:00",
    "rate_limit_minutes": 5,
    "private_rate_limit_minutes": 5,
    "daily_limit": 30,
    "private_daily_limit": 30,
    "max_reply_chars": 120,
}


def normalize_wechat_settings(settings: dict[str, Any] | None) -> dict[str, Any]:
    merged = {**DEFAULT_WECHAT_SETTINGS, **(settings or {})}
    merged["family_groups"] = _clean_list(merged.get("family_groups"))
    merged["private_contact_allowlist"] = _clean_list(merged.get("private_contact_allowlist"))
    merged["wake_words"] = _clean_list(merged.get("wake_words"))
    merged["require_mention"] = bool(merged.get("require_mention"))
    merged["manual_review"] = bool(merged.get("manual_review", True))
    merged["auto_reply_enabled"] = bool(merged.get("auto_reply_enabled"))
    merged["private_auto_reply_enabled"] = bool(merged.get("private_auto_reply_enabled"))
    merged["emergency_stop"] = bool(merged.get("emergency_stop"))
    merged["rate_limit_minutes"] = max(1, int(merged.get("rate_limit_minutes") or 5))
    merged["private_rate_limit_minutes"] = max(1, int(merged.get("private_rate_limit_minutes") or 5))
    merged["daily_limit"] = max(1, int(merged.get("daily_limit") or 30))
    merged["private_daily_limit"] = max(1, int(merged.get("private_daily_limit") or 30))
    merged["max_reply_chars"] = min(500, max(20, int(merged.get("max_reply_chars") or 120)))
    return merged


def message_fingerprint(
    *,
    pet_id: str,
    group_name: str,
    sender_name: str,
    message_text: str,
    observed_at: str | None,
) -> str:
    raw = "|".join(
        [
            pet_id.strip(),
            group_name.strip(),
            sender_name.strip(),
            " ".join(message_text.split()),
            (observed_at or "")[:16],
        ]
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def private_message_fingerprint(
    *,
    pet_id: str,
    contact_name: str,
    message_text: str,
    observed_at: str | None,
) -> str:
    return message_fingerprint(
        pet_id=pet_id,
        group_name=f"private:{contact_name}",
        sender_name=contact_name,
        message_text=message_text,
        observed_at=observed_at,
    )


def should_reply_to_message(
    *,
    settings: dict[str, Any],
    group_name: str,
    sender_name: str,
    message_text: str,
    mentioned: bool,
    now: datetime | None = None,
) -> tuple[bool, str]:
    settings = normalize_wechat_settings(settings)
    now = now or datetime.now(tz=UTC).astimezone()

    if settings["emergency_stop"]:
        return False, "emergency_stop"
    if group_name not in settings["family_groups"]:
        return False, "group_not_allowed"
    pet_wechat_name = str(settings.get("pet_wechat_name") or "").strip()
    if pet_wechat_name and sender_name.strip() == pet_wechat_name:
        return False, "self_message"
    if in_quiet_hours(
        now=now,
        start=str(settings["quiet_hours_start"]),
        end=str(settings["quiet_hours_end"]),
    ):
        return False, "quiet_hours"
    if settings["require_mention"] and not mentioned:
        return False, "not_mentioned"
    if not mentioned and not _contains_wake_word(message_text, settings["wake_words"]):
        return False, "no_wake_word"
    return True, "triggered"


def should_reply_to_private_message(
    *,
    settings: dict[str, Any],
    contact_name: str,
    message_text: str,
    now: datetime | None = None,
) -> tuple[bool, str]:
    settings = normalize_wechat_settings(settings)
    now = now or datetime.now(tz=UTC).astimezone()
    contact_name = contact_name.strip()
    message_text = message_text.strip()

    if settings["emergency_stop"]:
        return False, "emergency_stop"
    if not message_text:
        return False, "empty_message"
    if contact_name not in settings["private_contact_allowlist"]:
        return False, "contact_not_allowed"
    pet_wechat_name = str(settings.get("pet_wechat_name") or "").strip()
    if pet_wechat_name and contact_name == pet_wechat_name:
        return False, "self_message"
    if in_quiet_hours(
        now=now,
        start=str(settings["quiet_hours_start"]),
        end=str(settings["quiet_hours_end"]),
    ):
        return False, "quiet_hours"
    return True, "private_allowed"


def in_quiet_hours(*, now: datetime, start: str, end: str) -> bool:
    start_time = _parse_hhmm(start, default=time(23, 0))
    end_time = _parse_hhmm(end, default=time(8, 0))
    current = now.time().replace(second=0, microsecond=0)
    if start_time <= end_time:
        return start_time <= current < end_time
    return current >= start_time or current < end_time


def utc_iso_minutes_ago(minutes: int) -> str:
    return (datetime.now(tz=UTC) - timedelta(minutes=minutes)).replace(microsecond=0).isoformat()


def utc_iso_today_start() -> str:
    now = datetime.now(tz=UTC)
    return datetime(now.year, now.month, now.day, tzinfo=UTC).isoformat()


def build_user_prompt(
    *,
    pet_state: dict[str, Any],
    memories: list[dict[str, Any]],
    group_name: str,
    sender_name: str,
    message_text: str,
    recent_context: list[dict[str, Any]],
    max_reply_chars: int,
) -> str:
    memory_text = "\n".join(f"- {item['text']}" for item in memories[:5]) or "- 暂无重要记忆"
    context_text = "\n".join(
        f"- {item.get('sender_name', item.get('sender', '家人'))}: {summarize_text(str(item.get('text', '')))}"
        for item in recent_context[-6:]
    ) or "- 暂无上下文"
    latest_summary = pet_state.get("latest_summary") or "暂无实时状态"
    return "\n".join(
        [
            f"微信场景：{group_name}",
            f"发言对象：{sender_name}",
            f"对方消息：{message_text}",
            f"宠物当前状态：{latest_summary}",
            "相关记忆：",
            memory_text,
            "最近上下文：",
            context_text,
            f"请生成一条不超过 {max_reply_chars} 字的微信回复。不要解释规则，只输出回复正文。",
        ]
    )


def fallback_reply(*, pet_name: str, sender_name: str, message_text: str, max_chars: int) -> str:
    text = message_text.strip()
    if any(word in text for word in ("病", "吐", "拉稀", "流血", "不吃", "抽搐", "药")):
        reply = "这个听起来要认真一点，我只能撒娇，健康问题还是先问兽医比较稳。"
    elif any(word in text for word in ("在干嘛", "干嘛", "在哪")):
        reply = f"我在巡视家里，顺便监督{sender_name}今天有没有好好表现。"
    elif any(word in text for word in ("想你", "爱你", "喜欢")):
        reply = "收到，允许你们今天多夸我两句。"
    else:
        reply = f"{pet_name}收到，但我决定先优雅地观察三秒。"
    return reply[:max_chars]


def _clean_list(value: Any) -> list[str]:
    if isinstance(value, str):
        raw_items = value.replace("\n", ",").split(",")
    elif isinstance(value, list):
        raw_items = value
    else:
        raw_items = []
    return [str(item).strip() for item in raw_items if str(item).strip()]


def _contains_wake_word(message_text: str, wake_words: list[str]) -> bool:
    return any(word and word in message_text for word in wake_words)


def _parse_hhmm(raw: str, *, default: time) -> time:
    try:
        hour, minute = raw.split(":", 1)
        return time(int(hour), int(minute))
    except (ValueError, AttributeError):
        return default
