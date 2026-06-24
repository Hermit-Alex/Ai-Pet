from __future__ import annotations

import tempfile
import unittest
from contextlib import closing
from datetime import UTC, datetime, timedelta
from pathlib import Path

from aipet_bridge.app import create_app
from aipet_bridge.config import Settings
from aipet_bridge.models import PetProfile
from aipet_bridge.openclaw import OpenClawClientError
from aipet_bridge.service import AipetBridgeService
from aipet_bridge.storage import SQLiteStore
from aipet_bridge.wechat import normalize_wechat_settings, utc_iso_today_start


def make_service(temp_dir: str) -> AipetBridgeService:
    root = Path(temp_dir)
    settings = Settings(
        api_key=None,
        data_dir=root,
        database_path=root / "aipet.sqlite3",
        logs_dir=root / "logs",
        default_pet_id="cat-home",
        default_pet_name="猫咪",
        home_assistant_url=None,
        home_assistant_token=None,
        mqtt_url=None,
    )
    store = SQLiteStore(settings.database_path)
    service = AipetBridgeService(settings=settings, store=store)
    service.initialize()
    return service


class FakeOpenClaw:
    def __init__(self, *, enabled: bool = True, reply: str = "喵 OK", error: str = "") -> None:
        self.enabled = enabled
        self.reply = reply
        self.error = error
        self.calls: list[dict[str, str]] = []

    def chat(self, *, system_prompt: str, user_prompt: str) -> str:
        self.calls.append({"system_prompt": system_prompt, "user_prompt": user_prompt})
        if self.error:
            raise OpenClawClientError(self.error)
        return self.reply


class SequenceFakeOpenClaw:
    def __init__(self, replies: list[str]) -> None:
        self.enabled = True
        self.replies = list(replies)
        self.calls: list[dict[str, str]] = []

    def chat(self, *, system_prompt: str, user_prompt: str) -> str:
        self.calls.append({"system_prompt": system_prompt, "user_prompt": user_prompt})
        if len(self.replies) > 1:
            return self.replies.pop(0)
        return self.replies[0]


class BridgeStorageTest(unittest.TestCase):
    def test_health_reports_wechat_policy_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            settings = Settings(
                api_key=None,
                data_dir=root,
                database_path=root / "aipet.sqlite3",
                logs_dir=root / "logs",
                default_pet_id="cat-home",
                default_pet_name="猫咪",
                home_assistant_url=None,
                home_assistant_token=None,
                mqtt_url=None,
            )
            app = create_app(settings=settings)
            health_route = next(route for route in app.routes if getattr(route, "path", "") == "/health")

            payload = health_route.endpoint()

            self.assertEqual(payload["wechat_policy_version"], "2026-06-private-manual-review")
            self.assertTrue(payload["wechat_private_manual_review_enforced"])

    def test_openclaw_self_test_route_accepts_empty_request(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            settings = Settings(
                api_key=None,
                data_dir=root,
                database_path=root / "aipet.sqlite3",
                logs_dir=root / "logs",
                default_pet_id="cat-home",
                default_pet_name="catbot",
                home_assistant_url=None,
                home_assistant_token=None,
                mqtt_url=None,
            )
            app = create_app(settings=settings)
            route = next(
                route
                for route in app.routes
                if getattr(route, "path", "") == "/pets/{pet_id}/openclaw/self-test"
            )

            payload = route.endpoint(pet_id="cat-home", request=None)

            self.assertFalse(payload["configured"])
            self.assertEqual(payload["block_reason"], "openclaw_not_configured")

    def test_openclaw_self_test_reports_openclaw_model_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            settings = Settings(
                api_key=None,
                data_dir=root,
                database_path=root / "aipet.sqlite3",
                logs_dir=root / "logs",
                default_pet_id="cat-home",
                default_pet_name="catbot",
                home_assistant_url=None,
                home_assistant_token=None,
                mqtt_url=None,
                openclaw_base_url="http://127.0.0.1:18789/v1",
            )
            fake_openclaw = FakeOpenClaw(reply="喵 OK")
            service = AipetBridgeService(
                settings=settings,
                store=SQLiteStore(settings.database_path),
                openclaw=fake_openclaw,
            )
            service.initialize()

            result = service.test_openclaw_path(pet_id="cat-home", trace_id="trace-openclaw-ok")
            logs = service.query_logs(
                trace_id="trace-openclaw-ok",
                event="bridge.openclaw.self_test.completed",
            )

            self.assertTrue(result["ok"])
            self.assertTrue(result["configured"])
            self.assertEqual(result["model_source"], "openclaw")
            self.assertEqual(len(fake_openclaw.calls), 1)
            self.assertEqual(len(logs), 1)

    def test_openclaw_self_test_fails_closed_when_gateway_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            settings = Settings(
                api_key=None,
                data_dir=root,
                database_path=root / "aipet.sqlite3",
                logs_dir=root / "logs",
                default_pet_id="cat-home",
                default_pet_name="catbot",
                home_assistant_url=None,
                home_assistant_token=None,
                mqtt_url=None,
                openclaw_base_url="http://127.0.0.1:18789/v1",
            )
            service = AipetBridgeService(
                settings=settings,
                store=SQLiteStore(settings.database_path),
                openclaw=FakeOpenClaw(error="gateway down"),
            )
            service.initialize()

            result = service.test_openclaw_path(pet_id="cat-home", trace_id="trace-openclaw-fail")
            logs = service.query_logs(
                trace_id="trace-openclaw-fail",
                event="bridge.openclaw.self_test.failed",
            )

            self.assertFalse(result["ok"])
            self.assertTrue(result["configured"])
            self.assertEqual(result["model_source"], "local_fallback")
            self.assertEqual(result["block_reason"], "openclaw_failed")
            self.assertEqual(len(logs), 1)

    def test_wechat_settings_split_comma_separated_list_items(self) -> None:
        fullwidth_semicolon = chr(0xFF1B)
        settings = normalize_wechat_settings(
            {
                "private_contact_allowlist": ["爸爸,妈妈", "姐姐"],
                "family_groups": [f"家庭群，遛猫群{fullwidth_semicolon}阳台群"],
                "wake_words": "猫咪,喵喵",
            }
        )

        self.assertEqual(settings["private_contact_allowlist"], ["爸爸", "妈妈", "姐姐"])
        self.assertEqual(settings["family_groups"], ["家庭群", "遛猫群", "阳台群"])
        self.assertEqual(settings["wake_words"], ["猫咪", "喵喵"])

    def test_state_uses_recent_pet_events_and_memories_are_searchable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.store.upsert_pet_profile(PetProfile(id="cat-home", name="猫咪", species="cat"))
            service.add_event(
                pet_id="cat-home",
                event_type="feeding",
                source="test",
                summary="测试喂食事件。",
                payload={"portion_grams": 12},
            )
            service.add_memory(
                pet_id="cat-home",
                text="猫咪喜欢在窗台晒太阳。",
                tags=["偏好"],
                importance=3,
                source="test",
            )

            state = service.get_pet_current_state("cat-home")
            memories = service.search_memories("cat-home", query="窗台")

            self.assertEqual(state["status"], "eating")
            self.assertEqual(state["latest_summary"], "测试喂食事件。")
            self.assertEqual(len(memories), 1)
            self.assertEqual(memories[0]["importance"], 3)

    def test_persona_questionnaire_generates_profile_and_prompt(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            answers = {f"q{index:02d}": 5 for index in range(1, 41)}

            result = service.generate_persona(
                pet_id="cat-home",
                answers=answers,
                open_answers={"favorite_place": "窗边", "catchphrase": "喵收到"},
            )

            profile = result["profile"]
            self.assertEqual(profile["pet_name"], "猫咪")
            self.assertEqual(len(profile["type_code"]), 5)
            self.assertIn("真实长期使用的宠物微信号", profile["system_prompt"])
            self.assertIn("喵收到", profile["speaking_style"])

    def test_default_cat_home_persona_uses_coco_preset(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)

            result = service.get_persona("cat-home")

            self.assertEqual(result["profile"]["pet_name"], "CoCo")
            self.assertEqual(result["profile"]["nickname"], "猫仔")
            self.assertIn("谨慎独处戏精型有主见护短猫", result["profile"]["type_name"])
            self.assertIn("你是CoCo", result["system_prompt"])
            self.assertIn("不做医疗诊断", result["system_prompt"])

    def test_wechat_reply_is_blocked_outside_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "family_groups": ["家庭群"],
                    "wake_words": ["猫咪"],
                    "require_mention": True,
                    "manual_review": True,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                },
            )

            result = service.preview_wechat_reply(
                pet_id="cat-home",
                group_name="陌生群",
                sender_name="老婆",
                message_text="@猫咪 你在干嘛",
                mentioned=True,
            )

            self.assertFalse(result["should_reply"])
            self.assertEqual(result["block_reason"], "group_not_allowed")

    def test_wechat_reply_defaults_to_manual_review_and_deduplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "family_groups": ["家庭群"],
                    "wake_words": ["猫咪"],
                    "require_mention": True,
                    "manual_review": True,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "rate_limit_minutes": 1,
                    "daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            first = service.preview_wechat_reply(
                pet_id="cat-home",
                group_name="家庭群",
                sender_name="老婆",
                message_text="@猫咪 你在干嘛",
                mentioned=True,
                message_fingerprint_value="fixed-message",
            )
            second = service.preview_wechat_reply(
                pet_id="cat-home",
                group_name="家庭群",
                sender_name="老婆",
                message_text="@猫咪 你在干嘛",
                mentioned=True,
                message_fingerprint_value="fixed-message",
            )

            self.assertTrue(first["should_reply"])
            self.assertTrue(first["requires_manual_review"])
            self.assertEqual(first["model_source"], "local_fallback")
            self.assertFalse(second["should_reply"])
            self.assertEqual(second["block_reason"], "duplicate_message")

    def test_private_reply_requires_contact_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["老婆", "我"],
                    "private_auto_reply_enabled": True,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                },
            )

            result = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="陌生人",
                message_text="猫咪你在干嘛",
            )

            self.assertFalse(result["should_reply"])
            self.assertEqual(result["block_reason"], "contact_not_allowed")

    def test_private_reply_can_generate_auto_reply_and_deduplicate(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["老婆", "我"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_minutes": 1,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            first = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="老婆",
                message_text="猫咪你在干嘛",
                message_fingerprint_value="private-fixed-message",
            )
            second = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="老婆",
                message_text="猫咪你在干嘛",
                message_fingerprint_value="private-fixed-message",
            )

            self.assertTrue(first["should_reply"])
            self.assertTrue(first["auto_reply_enabled"])
            self.assertFalse(first["requires_manual_review"])
            self.assertEqual(first["model_source"], "local_fallback")
            self.assertFalse(first["safe_fallback_send_allowed"])
            self.assertFalse(second["should_reply"])
            self.assertEqual(second["block_reason"], "duplicate_message")

    def test_configured_openclaw_failure_keeps_private_fallback_local(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            settings = Settings(
                api_key=None,
                data_dir=root,
                database_path=root / "aipet.sqlite3",
                logs_dir=root / "logs",
                default_pet_id="cat-home",
                default_pet_name="CoCo",
                home_assistant_url=None,
                home_assistant_token=None,
                mqtt_url=None,
                openclaw_base_url="http://127.0.0.1:18789/v1",
            )
            service = AipetBridgeService(
                settings=settings,
                store=SQLiteStore(settings.database_path),
                openclaw=FakeOpenClaw(error="gateway hiccup"),
            )
            service.initialize()
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_seconds": 15,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            result = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="I will be home at 10",
                message_fingerprint_value="safe-fallback-private",
            )

            self.assertTrue(result["should_reply"])
            self.assertEqual(result["model_source"], "local_fallback")
            self.assertFalse(result["safe_fallback_send_allowed"])

    def test_private_reply_respects_manual_review(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad"],
                    "private_auto_reply_enabled": True,
                    "manual_review": True,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_minutes": 1,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            result = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="manual review should hold private replies",
                message_fingerprint_value="private-manual-review",
                trace_id="trace-private-manual",
            )
            logs = service.query_logs(
                trace_id="trace-private-manual",
                event="wechat.private.reply.generated",
            )

            self.assertTrue(result["should_reply"])
            self.assertTrue(result["requires_manual_review"])
            self.assertTrue(result["auto_reply_enabled"])
            self.assertEqual(len(logs), 1)
            self.assertEqual(logs[0]["result"], "private_manual_review")

    def test_private_rate_limit_log_uses_request_trace_id(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_minutes": 5,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            first = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="first rate test",
                message_fingerprint_value="rate-first",
            )
            second = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="second rate test",
                message_fingerprint_value="rate-second",
                trace_id="trace-rate-limit",
            )
            logs = service.query_logs(trace_id="trace-rate-limit", event="bridge.rate_limited")

            self.assertTrue(first["should_reply"])
            self.assertFalse(second["should_reply"])
            self.assertEqual(second["block_reason"], "rate_limited")
            self.assertGreaterEqual(second["retry_after_seconds"], 1)
            self.assertLessEqual(second["retry_after_seconds"], 300)
            self.assertEqual(len(logs), 1)
            self.assertEqual(logs[0]["trace_id"], "trace-rate-limit")
            self.assertGreaterEqual(logs[0]["retry_after_seconds"], 1)

    def test_private_rate_limit_uses_seconds_window_when_configured(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_minutes": 5,
                    "private_rate_limit_seconds": 5,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            first = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="first seconds test",
                message_fingerprint_value="seconds-first",
            )

            older_than_window = (
                datetime.now(tz=UTC) - timedelta(seconds=6)
            ).replace(microsecond=0).isoformat()
            with closing(service.store.connect()) as conn:
                conn.execute("UPDATE wechat_reply_record SET created_at = ?", (older_than_window,))
                conn.commit()

            second = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="second seconds test",
                message_fingerprint_value="seconds-second",
            )

            self.assertTrue(first["should_reply"])
            self.assertTrue(second["should_reply"])

    def test_reply_count_deduplicates_generated_and_sent_trace(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            store = SQLiteStore(Path(temp_dir) / "aipet.sqlite3")
            store.init_schema()
            store.record_wechat_reply(
                pet_id="cat-home",
                group_name="private:dad",
                trace_id="trace-same-reply",
                status="private_generated",
            )
            store.record_wechat_reply(
                pet_id="cat-home",
                group_name="private:dad",
                trace_id="trace-same-reply",
                status="private_sent",
            )

            count = store.count_wechat_replies_since(
                pet_id="cat-home",
                group_name=None,
                since_iso=utc_iso_today_start(),
                statuses=("private_generated", "private_sent", "private_manual_review"),
            )

            self.assertEqual(count, 1)

    def test_private_daily_limit_is_per_contact(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad", "mom"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_seconds": 5,
                    "private_daily_limit": 1,
                    "max_reply_chars": 120,
                },
            )

            dad_first = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="first dad daily test",
                message_fingerprint_value="dad-daily-first",
            )

            older_than_rate_window = (
                datetime.now(tz=UTC) - timedelta(seconds=6)
            ).replace(microsecond=0).isoformat()
            with closing(service.store.connect()) as conn:
                conn.execute(
                    "UPDATE wechat_reply_record SET created_at = ? WHERE group_name = ?",
                    (older_than_rate_window, "private:dad"),
                )
                conn.commit()

            dad_second = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="second dad daily test",
                message_fingerprint_value="dad-daily-second",
            )
            mom_first = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="mom",
                message_text="first mom daily test",
                message_fingerprint_value="mom-daily-first",
            )

            self.assertTrue(dad_first["should_reply"])
            self.assertFalse(dad_second["should_reply"])
            self.assertEqual(dad_second["block_reason"], "private_daily_limit_reached")
            self.assertTrue(mom_first["should_reply"])

    def test_reply_text_is_summarized_in_audit_logs_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            service = make_service(temp_dir)
            service.save_wechat_settings(
                pet_id="cat-home",
                settings={
                    "private_contact_allowlist": ["dad"],
                    "private_auto_reply_enabled": True,
                    "manual_review": False,
                    "quiet_hours_start": "00:00",
                    "quiet_hours_end": "00:00",
                    "private_rate_limit_minutes": 5,
                    "private_daily_limit": 30,
                    "max_reply_chars": 120,
                },
            )

            result = service.preview_private_reply(
                pet_id="cat-home",
                contact_name="dad",
                message_text="summarize reply log",
                message_fingerprint_value="summary-log",
                trace_id="trace-summary-log",
            )
            logs = service.query_logs(
                trace_id="trace-summary-log",
                event="wechat.private.reply.generated",
            )

            self.assertTrue(result["should_reply"])
            self.assertEqual(len(logs), 1)
            self.assertNotIn("reply_text", logs[0])
            self.assertIn("reply_text_summary", logs[0])


if __name__ == "__main__":
    unittest.main()
