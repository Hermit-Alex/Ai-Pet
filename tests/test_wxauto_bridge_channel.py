from __future__ import annotations

import contextlib
import shutil
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from aipet_bridge.audit_log import JsonlAuditLog
from aipet_wxauto_bridge_channel.channel import (
    AipetWxautoBridgeChannel,
    ChannelConfig,
    GroupChatConfig,
    PrivateChatConfig,
    WxautoClient,
    WxautoMessage,
    build_listen_ws_url,
    is_mentioned,
    message_fingerprint,
    stable_trace_id,
)


class FakeBridge:
    def __init__(self, decision: dict | list[dict]) -> None:
        if isinstance(decision, list):
            self.decisions = [dict(item) for item in decision]
            self.decision = dict(self.decisions[-1]) if self.decisions else {}
        else:
            self.decisions = []
            self.decision = dict(decision)
        if self.decision.get("should_reply") and "model_source" not in self.decision:
            self.decision["model_source"] = "openclaw"
        self.private_calls: list[dict] = []
        self.group_calls: list[dict] = []
        self.private_sent_calls: list[dict] = []
        self.group_sent_calls: list[dict] = []

    def private_reply(self, **kwargs):
        self.private_calls.append(kwargs)
        if self.decisions:
            decision = self.decisions.pop(0)
        else:
            decision = dict(self.decision)
        if decision.get("should_reply") and "model_source" not in decision:
            decision["model_source"] = "openclaw"
        return decision

    def group_reply(self, **kwargs):
        self.group_calls.append(kwargs)
        return self.decision

    def private_sent(self, **kwargs):
        self.private_sent_calls.append(kwargs)
        return {"recorded": True}

    def group_sent(self, **kwargs):
        self.group_sent_calls.append(kwargs)
        return {"recorded": True}


class FakeWxauto:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    def health(self) -> bool:
        return True

    def send_text(self, **kwargs):
        self.sent.append(kwargs)
        return {"ok": True}


class FakeResponse:
    def __init__(self, payload: dict, status_code: int = 200) -> None:
        self.payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self) -> dict:
        return self.payload


def make_channel(
    test_case: unittest.TestCase,
    *,
    decision: dict,
    dry_run: bool = False,
    config: ChannelConfig | None = None,
) -> tuple[AipetWxautoBridgeChannel, FakeBridge, FakeWxauto]:
    config = config or ChannelConfig(
        my_nickname="catbot",
        private_debounce_seconds=0.01,
        private_batch_max_wait_seconds=0.05,
        private_chats=(PrivateChatConfig(name="dad"),),
        group_chats=(GroupChatConfig(name="family", reply_mode="at_me_only"),),
    )
    bridge = FakeBridge(decision)
    wxauto = FakeWxauto()
    temp_dir = tempfile.mkdtemp()
    test_case.addCleanup(shutil.rmtree, temp_dir, ignore_errors=True)
    audit_log = JsonlAuditLog(Path(temp_dir))
    channel = AipetWxautoBridgeChannel(
        config=config,
        bridge=bridge,
        wxauto=wxauto,
        audit_log=audit_log,
        dry_run=dry_run,
    )
    return channel, bridge, wxauto


class WxautoBridgeChannelTest(unittest.TestCase):
    def test_wxauto_message_accepts_reference_api_aliases(self) -> None:
        message = WxautoMessage.from_dict(
            {
                "who": "dad",
                "sender": "dad",
                "sender_remark": "爸爸",
                "content": "photo",
                "msg_type": "image",
                "hash": "h-alias",
                "path": "C:/tmp/cat.jpg",
                "time": "2026-06-24 10:30:00",
            }
        )

        self.assertEqual(message.msg_type, "image")
        self.assertEqual(message.msg_hash, "h-alias")
        self.assertEqual(message.sender_remark, "爸爸")
        self.assertEqual(message.message_identity, "h-alias")
        self.assertEqual(message.file_path, "C:/tmp/cat.jpg")
        self.assertEqual(message.observed_at, "2026-06-24 10:30:00")

    def test_wxauto_message_time_separates_repeated_text_without_message_id(self) -> None:
        first = WxautoMessage.from_dict(
            {
                "who": "dad",
                "sender": "dad",
                "content": "catbot?",
                "type": "text",
                "time": "2026-06-24 10:30:00",
            }
        )
        second = WxautoMessage.from_dict(
            {
                "who": "dad",
                "sender": "dad",
                "content": "catbot?",
                "type": "text",
                "time": "2026-06-24 10:31:00",
            }
        )

        self.assertNotEqual(stable_trace_id(first), stable_trace_id(second))
        self.assertNotEqual(message_fingerprint(first), message_fingerprint(second))

    def test_wxauto_client_fails_when_api_reports_unsuccessful_send(self) -> None:
        client = WxautoClient(base_url="http://127.0.0.1:8001", token="token")

        with patch("requests.post", return_value=FakeResponse({"success": False, "message": "send failed"})):
            with self.assertRaisesRegex(RuntimeError, "send failed"):
                client.send_text(who="dad", text="hello")

    def test_wxauto_client_recovers_cancelled_switch_failure_once(self) -> None:
        client = WxautoClient(base_url="http://127.0.0.1:8001", token="token")
        switch_failure = (
            "\u5207\u6362\u804a\u5929\u5bf9\u8c61\u5931\u8d25"
            "\uff0c\u4e3a\u907f\u514d\u53d1\u9001\u9519\u8bef"
            "\uff0c\u53d6\u6d88\u53d1\u9001"
        )

        with patch(
            "requests.post",
            side_effect=[
                FakeResponse({"success": False, "message": switch_failure}),
                FakeResponse({"success": True}),
                FakeResponse({"success": True}),
                FakeResponse({"success": True, "message": "sent"}),
            ],
        ) as post:
            result = client.send_text(who="dad", text="hello")

        self.assertEqual(result["message"], "sent")
        urls = [call.args[0] for call in post.call_args_list]
        self.assertEqual(
            urls,
            [
                "http://127.0.0.1:8001/v1/wechat/send",
                "http://127.0.0.1:8001/v1/wechat/initialize",
                "http://127.0.0.1:8001/v1/wechat/chatwith",
                "http://127.0.0.1:8001/v1/wechat/send",
            ],
        )
        self.assertEqual(post.call_args_list[0].kwargs["json"]["who"], "dad")
        self.assertTrue(post.call_args_list[0].kwargs["json"]["exact"])
        self.assertEqual(post.call_args_list[2].kwargs["json"], {"who": "dad", "exact": True})

    def test_wxauto_client_does_not_retry_ambiguous_timeout(self) -> None:
        import requests

        client = WxautoClient(base_url="http://127.0.0.1:8001", token="token")

        with patch(
            "requests.post",
            side_effect=requests.exceptions.ReadTimeout("timed out"),
        ) as post:
            with self.assertRaises(requests.exceptions.ReadTimeout):
                client.send_text(who="dad", text="hello")

        self.assertEqual(post.call_count, 1)

    def test_wxauto_client_fails_when_wechat_initialize_fails(self) -> None:
        client = WxautoClient(base_url="http://127.0.0.1:8001", token="token")

        with patch(
            "requests.post",
            return_value=FakeResponse({"success": False, "message": "window not ready"}),
        ):
            with self.assertRaisesRegex(RuntimeError, "window not ready"):
                client.initialize_wechat()

    def test_channel_initializes_wechat_before_listening(self) -> None:
        class InitializingWxauto(FakeWxauto):
            def __init__(self) -> None:
                super().__init__()
                self.initialized = False

            def initialize_wechat(self):
                self.initialized = True
                return {"success": True}

        config = ChannelConfig(
            my_nickname="catbot",
            private_chats=(PrivateChatConfig(name="dad"), PrivateChatConfig(name="mom")),
        )
        wxauto = InitializingWxauto()
        temp_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, temp_dir, ignore_errors=True)
        channel = AipetWxautoBridgeChannel(
            config=config,
            bridge=FakeBridge({"should_reply": False}),
            wxauto=wxauto,
            audit_log=JsonlAuditLog(Path(temp_dir)),
        )
        listened: list[str] = []

        async def fake_listen(who: str) -> None:
            listened.append(who)

        channel._listen_one = fake_listen  # type: ignore[method-assign]

        import asyncio

        asyncio.run(channel.run())

        self.assertTrue(wxauto.initialized)
        self.assertEqual(listened, ["dad", "mom"])

    def test_websocket_warning_is_logged_for_runtime_diagnosis(self) -> None:
        channel, _, _ = make_channel(
            self,
            decision={
                "should_reply": False,
                "block_reason": "not-used",
            },
        )

        import asyncio

        asyncio.run(
            channel._handle_ws_payload(
                '{"type":"warning","data":{"who":"dad","status":"listen_failed","message":"window hidden"}}'
            )
        )

        records = channel.audit_log.query(event="wechat.wxauto.ws_warning", limit=10)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["target_name"], "dad")
        self.assertEqual(records[0]["status"], "listen_failed")

    def test_websocket_message_payload_can_be_queued_before_processing(self) -> None:
        channel, bridge, _ = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        import asyncio

        async def run() -> asyncio.Queue[dict]:
            queue: asyncio.Queue[dict] = asyncio.Queue()
            await channel._handle_ws_payload(
                '{"type":"message","data":{"who":"dad","sender":"dad","content":"catbot?","type":"text","id":"m-ws"}}',
                message_queue=queue,
            )
            return queue

        queue = asyncio.run(run())

        self.assertEqual(queue.qsize(), 1)
        self.assertEqual(bridge.private_calls, [])

    def test_websocket_message_worker_processes_queued_messages(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        import asyncio

        async def run() -> None:
            queue: asyncio.Queue[dict] = asyncio.Queue()
            worker = asyncio.create_task(channel._message_worker("dad", queue))
            await queue.put(
                {"who": "dad", "sender": "dad", "content": "catbot?", "type": "text", "id": "m-worker"}
            )
            await asyncio.wait_for(queue.join(), timeout=2)
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker

        asyncio.run(run())

        self.assertEqual(len(bridge.private_calls), 1)
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "meow received"}])

    def test_websocket_message_worker_batches_bursty_private_messages(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "batch received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        import asyncio

        async def run() -> None:
            queue: asyncio.Queue[dict] = asyncio.Queue()
            worker = asyncio.create_task(channel._message_worker("dad", queue))
            await queue.put(
                {"who": "dad", "sender": "dad", "content": "first", "type": "text", "id": "m-b1"}
            )
            await queue.put(
                {"who": "dad", "sender": "dad", "content": "second", "type": "text", "id": "m-b2"}
            )
            await asyncio.wait_for(queue.join(), timeout=2)
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker

        asyncio.run(run())

        self.assertEqual(len(bridge.private_calls), 1)
        self.assertIn("first", bridge.private_calls[0]["message_text"])
        self.assertIn("second", bridge.private_calls[0]["message_text"])
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "batch received"}])

    def test_rate_limited_private_message_waits_and_retries(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision=[
                {
                    "trace_id": "trace-rate-limited",
                    "should_reply": False,
                    "block_reason": "rate_limited",
                    "retry_after_seconds": 1,
                },
                {
                    "trace_id": "trace-after-cooldown",
                    "should_reply": True,
                    "reply_text": "cooldown batch received",
                    "requires_manual_review": False,
                    "auto_reply_enabled": True,
                    "model_source": "openclaw",
                },
            ],
            config=ChannelConfig(
                my_nickname="catbot",
                private_debounce_seconds=0.0,
                private_rate_limited_max_retries=2,
                private_rate_limited_fallback_retry_seconds=1,
                private_chats=(PrivateChatConfig(name="dad"),),
            ),
        )

        import asyncio

        async def run() -> None:
            queue: asyncio.Queue[dict] = asyncio.Queue()
            worker = asyncio.create_task(channel._message_worker("dad", queue))
            await queue.put(
                {
                    "who": "dad",
                    "sender": "dad",
                    "content": "catbot?",
                    "type": "text",
                    "id": "m-rate",
                }
            )
            await asyncio.wait_for(queue.join(), timeout=3)
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker

        asyncio.run(run())

        self.assertEqual(len(bridge.private_calls), 2)
        self.assertNotEqual(
            bridge.private_calls[0]["message_fingerprint"],
            bridge.private_calls[1]["message_fingerprint"],
        )
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "cooldown batch received"}])
        logs = channel.audit_log.query(event="wechat.wxauto.private.cooldown_queued", limit=10)
        self.assertEqual(len(logs), 1)

    def test_config_parser_splits_comma_separated_list_items(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.yaml"
            config_path.write_text(
                "\n".join(
                    [
                        "my_nickname: catbot",
                        "require_openclaw_for_send: true",
                        "private_chats:",
                        "  - name: dad",
                        "    whitelist: ['dad,mom']",
                        "group_chats:",
                        "  - name: family",
                        "    sender_whitelist: ['dad，mom']",
                        "    sender_blacklist: 'spam;bot'",
                    ]
                ),
                encoding="utf-8",
            )

            config = ChannelConfig.from_yaml(config_path)

        self.assertEqual(config.private_chats[0].whitelist, ("dad", "mom"))
        self.assertEqual(config.group_chats[0].sender_whitelist, ("dad", "mom"))
        self.assertEqual(config.group_chats[0].sender_blacklist, ("spam", "bot"))
        self.assertTrue(config.require_openclaw_for_send)

    def test_config_parser_splits_fullwidth_comma_list_items(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.yaml"
            fullwidth_comma = chr(0xFF0C)
            fullwidth_semicolon = chr(0xFF1B)
            config_path.write_text(
                "\n".join(
                    [
                        "my_nickname: catbot",
                        "private_chats:",
                        "  - name: dad",
                        f"    whitelist: ['dad{fullwidth_comma}mom{fullwidth_semicolon}sister']",
                    ]
                ),
                encoding="utf-8",
            )

            config = ChannelConfig.from_yaml(config_path)

        self.assertEqual(config.private_chats[0].whitelist, ("dad", "mom", "sister"))

    def test_config_parser_normalizes_group_reply_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.yaml"
            config_path.write_text(
                "\n".join(
                    [
                        "my_nickname: catbot",
                        "group_chats:",
                        "  - name: family",
                        "    reply_mode: ALL",
                    ]
                ),
                encoding="utf-8",
            )

            config = ChannelConfig.from_yaml(config_path)

        self.assertEqual(config.group_chats[0].reply_mode, "all")

    def test_group_mention_detection_accepts_wechat_spacing_and_fullwidth_at(self) -> None:
        self.assertTrue(is_mentioned("@catbot hello", "catbot"))
        self.assertTrue(is_mentioned(f"{chr(0xFF20)} catbot{chr(0x2005)}hello", "catbot"))
        self.assertFalse(is_mentioned("@catbot2 hello", "catbot"))

    def test_listen_websocket_url_matches_reference_contract_without_token(self) -> None:
        who = f"{chr(0x7238)}{chr(0x7238)}/{chr(0x5988)}{chr(0x5988)}"
        url = build_listen_ws_url("http://127.0.0.1:8001/", who, auto_start=False)

        self.assertEqual(
            url,
            "ws://127.0.0.1:8001/v1/listen/ws?who=%E7%88%B8%E7%88%B8%2F%E5%A6%88%E5%A6%88&auto_start=false",
        )
        self.assertNotIn("token=", url)
        self.assertNotIn("Authorization", url)

    def test_private_message_sends_when_bridge_allows_auto_reply(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            }
        )

        result = channel.handle_message(
            {"who": "dad", "sender": "dad", "content": "catbot?", "type": "text", "id": "m1"}
        )

        self.assertEqual(result.action, "sent")
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "meow received"}])
        self.assertEqual(len(bridge.private_calls), 1)
        self.assertEqual(len(bridge.private_sent_calls), 1)
        self.assertEqual(bridge.private_calls[0]["trace_id"], result.trace_id)
        self.assertEqual(bridge.private_sent_calls[0]["trace_id"], result.trace_id)

    def test_private_message_allows_sender_remark_matching_contact(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {
                "who": "dad",
                "sender": "wechat-display-name",
                "sender_remark": "dad",
                "content": "catbot?",
                "type": "text",
                "hash": "h-remark",
            }
        )

        self.assertEqual(result.action, "sent")
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "meow received"}])
        self.assertEqual(len(bridge.private_calls), 1)
        self.assertEqual(bridge.private_calls[0]["trace_id"], result.trace_id)

    def test_private_message_dry_run_does_not_send(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            dry_run=True,
            decision={
                "should_reply": True,
                "reply_text": "meow received",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {"who": "dad", "sender": "dad", "content": "catbot?", "type": "text", "id": "m-dry"}
        )

        self.assertEqual(result.action, "dry_run")
        self.assertEqual(result.reply_text, "meow received")
        self.assertEqual(wxauto.sent, [])
        self.assertEqual(len(bridge.private_calls), 1)
        self.assertEqual(bridge.private_sent_calls, [])

    def test_live_send_requires_openclaw_model_path_by_default(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "local fallback should not leave the machine",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
                "model_source": "local_fallback",
            },
        )

        result = channel.handle_message(
            {"who": "dad", "sender": "dad", "content": "catbot?", "type": "text", "id": "m-local-fallback"}
        )
        logs = channel.audit_log.query(event="wechat.wxauto.model_path_blocked", limit=10)

        self.assertEqual(result.action, "blocked")
        self.assertEqual(result.reason, "openclaw_required")
        self.assertEqual(wxauto.sent, [])
        self.assertEqual(bridge.private_sent_calls, [])
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0]["model_source"], "local_fallback")

    def test_safe_fallback_can_send_when_bridge_explicitly_allows_it(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "本猫收到，先记下。",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
                "model_source": "local_fallback",
                "safe_fallback_send_allowed": True,
            },
        )

        result = channel.handle_message(
            {"who": "dad", "sender": "dad", "content": "10 点回家", "type": "text", "id": "m-safe-fallback"}
        )
        logs = channel.audit_log.query(event="wechat.wxauto.safe_fallback_send_allowed", limit=10)

        self.assertEqual(result.action, "sent")
        self.assertEqual(wxauto.sent, [{"who": "dad", "text": "本猫收到，先记下。"}])
        self.assertEqual(len(bridge.private_sent_calls), 1)
        self.assertEqual(len(logs), 1)
        self.assertEqual(logs[0]["model_source"], "local_fallback")

    def test_non_text_message_is_ignored_before_bridge_call(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "should not send",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {
                "who": "dad",
                "sender": "dad",
                "content": "cat.jpg",
                "type": "image",
                "id": "img1",
                "file_path": "C:/tmp/cat.jpg",
            }
        )

        self.assertEqual(result.action, "ignored")
        self.assertEqual(result.reason, "unsupported_message_type")
        self.assertEqual(bridge.private_calls, [])
        self.assertEqual(wxauto.sent, [])

    def test_group_message_does_not_send_when_manual_review_is_required(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow",
                "requires_manual_review": True,
                "auto_reply_enabled": True,
            }
        )

        result = channel.handle_message(
            {
                "who": "family",
                "sender": "mom",
                "content": "@catbot hello",
                "type": "text",
                "id": "g1",
            }
        )

        self.assertEqual(result.action, "manual_review")
        self.assertEqual(wxauto.sent, [])
        self.assertEqual(len(bridge.group_calls), 1)
        self.assertEqual(bridge.group_calls[0]["mentioned"], True)
        self.assertEqual(bridge.group_calls[0]["trace_id"], result.trace_id)

    def test_group_message_sends_and_records_group_sent_when_auto_allowed(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "meow family",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {
                "who": "family",
                "sender": "mom",
                "content": "\uff20 catbot\u2005hello",
                "type": "text",
                "id": "g-send",
            }
        )

        self.assertEqual(result.action, "sent")
        self.assertEqual(wxauto.sent, [{"who": "family", "text": "meow family"}])
        self.assertEqual(len(bridge.group_calls), 1)
        self.assertTrue(bridge.group_calls[0]["mentioned"])
        self.assertEqual(len(bridge.group_sent_calls), 1)
        self.assertEqual(bridge.group_sent_calls[0]["trace_id"], result.trace_id)

    def test_group_at_me_only_ignores_unmentioned_message_before_bridge_call(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "should_reply": True,
                "reply_text": "should not send",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {"who": "family", "sender": "mom", "content": "hello", "type": "text", "id": "g-no-at"}
        )

        self.assertEqual(result.action, "ignored")
        self.assertEqual(result.reason, "group_not_mentioned")
        self.assertEqual(bridge.group_calls, [])
        self.assertEqual(wxauto.sent, [])

    def test_group_all_mode_forwards_unmentioned_message_to_bridge(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            config=ChannelConfig(
                my_nickname="catbot",
                group_chats=(GroupChatConfig(name="family", reply_mode="ALL"),),
            ),
            decision={
                "should_reply": True,
                "reply_text": "all mode reply",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        result = channel.handle_message(
            {"who": "family", "sender": "mom", "content": "hello family", "type": "text", "id": "g-all"}
        )

        self.assertEqual(result.action, "sent")
        self.assertEqual(wxauto.sent, [{"who": "family", "text": "all mode reply"}])
        self.assertEqual(len(bridge.group_calls), 1)
        self.assertFalse(bridge.group_calls[0]["mentioned"])

    def test_group_sender_whitelist_and_blacklist_are_enforced_before_bridge_call(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            config=ChannelConfig(
                my_nickname="catbot",
                group_chats=(
                    GroupChatConfig(
                        name="family",
                        reply_mode="at_me_only",
                        sender_whitelist=("mom",),
                        sender_blacklist=("spam",),
                    ),
                ),
            ),
            decision={
                "should_reply": True,
                "reply_text": "should not send",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            },
        )

        not_whitelisted = channel.handle_message(
            {"who": "family", "sender": "dad", "content": "@catbot hello", "type": "text", "id": "g-dad"}
        )
        blacklisted = channel.handle_message(
            {
                "who": "family",
                "sender": "display-name",
                "sender_remark": "spam",
                "content": "@catbot hello",
                "type": "text",
                "id": "g-spam",
            }
        )

        self.assertEqual(not_whitelisted.action, "ignored")
        self.assertEqual(not_whitelisted.reason, "group_sender_not_allowed")
        self.assertEqual(blacklisted.action, "ignored")
        self.assertEqual(blacklisted.reason, "group_sender_blacklisted")
        self.assertEqual(bridge.group_calls, [])
        self.assertEqual(wxauto.sent, [])

    def test_self_message_is_ignored_before_bridge_call(self) -> None:
        channel, bridge, wxauto = make_channel(
            self,
            decision={
                "trace_id": "trace-3",
                "should_reply": True,
                "reply_text": "should not send",
                "requires_manual_review": False,
                "auto_reply_enabled": True,
            }
        )

        result = channel.handle_message(
            {"who": "dad", "sender": "catbot", "content": "already sent", "type": "text", "id": "m2"}
        )

        self.assertEqual(result.action, "ignored")
        self.assertEqual(result.reason, "self_message")
        self.assertEqual(bridge.private_calls, [])
        self.assertEqual(wxauto.sent, [])


if __name__ == "__main__":
    unittest.main()
