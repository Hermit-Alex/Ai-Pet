from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from typing import Any


def utc_now_iso() -> str:
    return datetime.now(tz=UTC).replace(microsecond=0).isoformat()


@dataclass(frozen=True)
class PetProfile:
    id: str
    name: str
    species: str = "cat"
    breed: str | None = None
    birthday: str | None = None
    sex: str | None = None
    neutered: bool | None = None
    personality: str | None = None
    medical_notes: str | None = None
    created_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class PetEvent:
    id: str
    pet_id: str
    event_type: str
    event_time: str
    source: str
    summary: str
    payload_json: str | None = None
    next_due_at: str | None = None
    created_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class MemoryNote:
    id: str
    pet_id: str
    text: str
    tags: str | None = None
    importance: int = 1
    source: str | None = None
    created_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
