from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

from .config import Settings


class OpenClawClientError(RuntimeError):
    pass


class OpenClawClient:
    def __init__(self, settings: Settings, *, timeout_seconds: float = 20.0) -> None:
        self.settings = settings
        self.timeout_seconds = timeout_seconds

    @property
    def enabled(self) -> bool:
        return bool(self.settings.openclaw_base_url)

    def chat(self, *, system_prompt: str, user_prompt: str) -> str:
        if not self.enabled:
            raise OpenClawClientError("OpenClaw is not configured.")

        base_url = str(self.settings.openclaw_base_url).rstrip("/")
        url = f"{base_url}/chat/completions"
        payload = {
            "model": self.settings.openclaw_model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.7,
            "max_tokens": 220,
        }
        headers = {"Content-Type": "application/json"}
        if self.settings.openclaw_api_key:
            headers["Authorization"] = f"Bearer {self.settings.openclaw_api_key}"

        request = urllib.request.Request(
            url=url,
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read().decode("utf-8")
        except (urllib.error.URLError, TimeoutError) as exc:
            raise OpenClawClientError(str(exc)) from exc

        try:
            data: dict[str, Any] = json.loads(body)
            return str(data["choices"][0]["message"]["content"]).strip()
        except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
            raise OpenClawClientError("OpenClaw returned an unexpected response.") from exc
