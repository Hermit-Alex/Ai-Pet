from __future__ import annotations

import json
import threading
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


LOG_FILES = {
    "bridge": "aipet-bridge.jsonl",
    "sidecar": "wechat-sidecar.jsonl",
    "audit": "audit-events.jsonl",
    "errors": "errors.jsonl",
}


class JsonlAuditLog:
    def __init__(
        self,
        logs_dir: Path | str,
        *,
        log_sensitive: bool = False,
        max_bytes: int = 10 * 1024 * 1024,
        backup_count: int = 10,
    ) -> None:
        self.logs_dir = Path(logs_dir)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        self.log_sensitive = log_sensitive
        self.max_bytes = max_bytes
        self.backup_count = backup_count
        self._lock = threading.Lock()

    def new_trace_id(self) -> str:
        return str(uuid.uuid4())

    def log(
        self,
        *,
        stream: str = "audit",
        level: str = "info",
        service: str,
        event: str,
        trace_id: str | None = None,
        **fields: Any,
    ) -> str:
        trace_id = trace_id or self.new_trace_id()
        record = {
            "ts": datetime.now(tz=UTC).replace(microsecond=0).isoformat(),
            "level": level,
            "service": service,
            "event": event,
            "trace_id": trace_id,
            **self._sanitize(fields),
        }
        target = self.logs_dir / LOG_FILES.get(stream, LOG_FILES["audit"])
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            self._rotate_if_needed(target, len(line.encode("utf-8")) + 1)
            with target.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        if level.lower() in {"error", "exception", "critical"} and stream != "errors":
            self.log(
                stream="errors",
                level=level,
                service=service,
                event=event,
                trace_id=trace_id,
                **fields,
            )
        return trace_id

    def query(
        self,
        *,
        trace_id: str | None = None,
        service: str | None = None,
        level: str | None = None,
        event: str | None = None,
        limit: int = 200,
    ) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for path in self._iter_log_files():
            if not path.exists():
                continue
            with path.open("r", encoding="utf-8") as handle:
                for raw_line in handle:
                    try:
                        record = json.loads(raw_line)
                    except json.JSONDecodeError:
                        continue
                    if trace_id and record.get("trace_id") != trace_id:
                        continue
                    if service and record.get("service") != service:
                        continue
                    if level and str(record.get("level", "")).lower() != level.lower():
                        continue
                    if event and record.get("event") != event:
                        continue
                    records.append(record)
        records.sort(key=lambda item: item.get("ts", ""), reverse=True)
        return records[:limit]

    def _iter_log_files(self) -> Iterable[Path]:
        for filename in LOG_FILES.values():
            yield self.logs_dir / filename

    def _sanitize(self, value: Any) -> Any:
        if isinstance(value, dict):
            clean: dict[str, Any] = {}
            for key, item in value.items():
                lowered = key.lower()
                if lowered in {"authorization", "api_key", "token", "password", "secret"}:
                    clean[key] = "[redacted]"
                elif lowered in {"message_text", "reply_text", "full_response", "prompt"} and not self.log_sensitive:
                    clean[f"{key}_summary"] = summarize_text(str(item))
                else:
                    clean[key] = self._sanitize(item)
            return clean
        if isinstance(value, list):
            return [self._sanitize(item) for item in value]
        return value

    def _rotate_if_needed(self, path: Path, incoming_bytes: int) -> None:
        if not path.exists() or path.stat().st_size + incoming_bytes <= self.max_bytes:
            return
        oldest = path.with_name(f"{path.name}.{self.backup_count}")
        if oldest.exists():
            oldest.unlink()
        for index in range(self.backup_count - 1, 0, -1):
            source = path.with_name(f"{path.name}.{index}")
            if source.exists():
                source.rename(path.with_name(f"{path.name}.{index + 1}"))
        path.rename(path.with_name(f"{path.name}.1"))


def summarize_text(text: str, limit: int = 80) -> str:
    normalized = " ".join(text.split())
    if len(normalized) <= limit:
        return normalized
    return normalized[:limit] + "..."
