from __future__ import annotations

import json
import unittest
from pathlib import Path
from unittest.mock import patch

from aipet_bridge.config import Settings
from aipet_bridge.openclaw import OPENCLAW_MAX_TOKENS, OpenClawClient


class FakeUrlopenResponse:
    def __enter__(self) -> "FakeUrlopenResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(
            {"choices": [{"message": {"content": "好的，本猫收到。"}}]},
            ensure_ascii=False,
        ).encode("utf-8")


class OpenClawClientTest(unittest.TestCase):
    def test_chat_uses_larger_completion_budget_for_reasoning_models(self) -> None:
        settings = Settings(
            api_key=None,
            data_dir=Path("tmp"),
            database_path=Path("tmp/aipet.sqlite3"),
            logs_dir=Path("tmp/logs"),
            default_pet_id="cat-home",
            default_pet_name="CoCo",
            home_assistant_url=None,
            home_assistant_token=None,
            mqtt_url=None,
            openclaw_base_url="http://127.0.0.1:18789/v1",
            openclaw_model="openclaw/default",
        )
        client = OpenClawClient(settings)

        with patch("urllib.request.urlopen", return_value=FakeUrlopenResponse()) as urlopen:
            reply = client.chat(system_prompt="system", user_prompt="user")

        request = urlopen.call_args.args[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual(reply, "好的，本猫收到。")
        self.assertEqual(payload["max_tokens"], OPENCLAW_MAX_TOKENS)
        self.assertEqual(payload["max_tokens"], 512)


if __name__ == "__main__":
    unittest.main()
