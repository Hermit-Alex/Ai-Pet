from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from aipet_bridge.config import Settings
from aipet_bridge.models import PetProfile
from aipet_bridge.service import AipetBridgeService
from aipet_bridge.storage import SQLiteStore


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


class BridgeStorageTest(unittest.TestCase):
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
            self.assertFalse(second["should_reply"])
            self.assertEqual(second["block_reason"], "duplicate_message")


if __name__ == "__main__":
    unittest.main()
