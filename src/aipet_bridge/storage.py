from __future__ import annotations

import json
import sqlite3
import uuid
from collections.abc import Iterable
from contextlib import closing
from pathlib import Path
from typing import Any

from .models import MemoryNote, PetEvent, PetProfile, utc_now_iso


class SQLiteStore:
    def __init__(self, database_path: Path | str) -> None:
        self.database_path = Path(database_path)
        self.database_path.parent.mkdir(parents=True, exist_ok=True)

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.database_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def init_schema(self) -> None:
        with closing(self.connect()) as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS pet_profile (
                  id TEXT PRIMARY KEY,
                  name TEXT NOT NULL,
                  species TEXT NOT NULL,
                  breed TEXT,
                  birthday TEXT,
                  sex TEXT,
                  neutered INTEGER,
                  personality TEXT,
                  medical_notes TEXT,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS pet_event (
                  id TEXT PRIMARY KEY,
                  pet_id TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  event_time TEXT NOT NULL,
                  source TEXT NOT NULL,
                  summary TEXT NOT NULL,
                  payload_json TEXT,
                  next_due_at TEXT,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (pet_id) REFERENCES pet_profile(id)
                );

                CREATE INDEX IF NOT EXISTS idx_pet_event_pet_time
                  ON pet_event(pet_id, event_time DESC);

                CREATE TABLE IF NOT EXISTS memory_note (
                  id TEXT PRIMARY KEY,
                  pet_id TEXT NOT NULL,
                  text TEXT NOT NULL,
                  tags TEXT,
                  importance INTEGER NOT NULL DEFAULT 1,
                  source TEXT,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (pet_id) REFERENCES pet_profile(id)
                );

                CREATE INDEX IF NOT EXISTS idx_memory_note_pet_created
                  ON memory_note(pet_id, created_at DESC);

                CREATE TABLE IF NOT EXISTS pet_persona (
                  pet_id TEXT PRIMARY KEY,
                  profile_json TEXT NOT NULL,
                  system_prompt TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  FOREIGN KEY (pet_id) REFERENCES pet_profile(id)
                );

                CREATE TABLE IF NOT EXISTS wechat_settings (
                  pet_id TEXT PRIMARY KEY,
                  settings_json TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  FOREIGN KEY (pet_id) REFERENCES pet_profile(id)
                );

                CREATE TABLE IF NOT EXISTS wechat_seen_message (
                  fingerprint TEXT PRIMARY KEY,
                  pet_id TEXT NOT NULL,
                  group_name TEXT NOT NULL,
                  sender_name TEXT NOT NULL,
                  summary TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS wechat_reply_record (
                  id TEXT PRIMARY KEY,
                  pet_id TEXT NOT NULL,
                  group_name TEXT NOT NULL,
                  trace_id TEXT NOT NULL,
                  status TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_wechat_reply_group_time
                  ON wechat_reply_record(pet_id, group_name, created_at DESC);
                """
            )
            conn.commit()

    def upsert_pet_profile(self, profile: PetProfile) -> PetProfile:
        created_at = profile.created_at or utc_now_iso()
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO pet_profile (
                  id, name, species, breed, birthday, sex, neutered,
                  personality, medical_notes, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  species = excluded.species,
                  breed = excluded.breed,
                  birthday = excluded.birthday,
                  sex = excluded.sex,
                  neutered = excluded.neutered,
                  personality = excluded.personality,
                  medical_notes = excluded.medical_notes
                """,
                (
                    profile.id,
                    profile.name,
                    profile.species,
                    profile.breed,
                    profile.birthday,
                    profile.sex,
                    None if profile.neutered is None else int(profile.neutered),
                    profile.personality,
                    profile.medical_notes,
                    created_at,
                ),
            )
            conn.commit()
        return PetProfile(**{**profile.to_dict(), "created_at": created_at})

    def get_pet_profile(self, pet_id: str) -> PetProfile | None:
        with closing(self.connect()) as conn:
            row = conn.execute("SELECT * FROM pet_profile WHERE id = ?", (pet_id,)).fetchone()
        if row is None:
            return None
        return _profile_from_row(row)

    def add_event(
        self,
        *,
        pet_id: str,
        event_type: str,
        source: str,
        summary: str,
        event_time: str | None = None,
        payload: dict[str, Any] | None = None,
        next_due_at: str | None = None,
    ) -> PetEvent:
        event = PetEvent(
            id=str(uuid.uuid4()),
            pet_id=pet_id,
            event_type=event_type,
            event_time=event_time or utc_now_iso(),
            source=source,
            summary=summary,
            payload_json=json.dumps(payload, ensure_ascii=False) if payload else None,
            next_due_at=next_due_at,
            created_at=utc_now_iso(),
        )
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO pet_event (
                  id, pet_id, event_type, event_time, source,
                  summary, payload_json, next_due_at, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event.id,
                    event.pet_id,
                    event.event_type,
                    event.event_time,
                    event.source,
                    event.summary,
                    event.payload_json,
                    event.next_due_at,
                    event.created_at,
                ),
            )
            conn.commit()
        return event

    def list_recent_events(self, pet_id: str, limit: int = 20) -> list[PetEvent]:
        with closing(self.connect()) as conn:
            rows = conn.execute(
                """
                SELECT * FROM pet_event
                WHERE pet_id = ?
                ORDER BY event_time DESC
                LIMIT ?
                """,
                (pet_id, limit),
            ).fetchall()
        return [_event_from_row(row) for row in rows]

    def add_memory(
        self,
        *,
        pet_id: str,
        text: str,
        tags: Iterable[str] | None = None,
        importance: int = 1,
        source: str | None = None,
    ) -> MemoryNote:
        note = MemoryNote(
            id=str(uuid.uuid4()),
            pet_id=pet_id,
            text=text,
            tags=",".join(tags) if tags else None,
            importance=importance,
            source=source,
            created_at=utc_now_iso(),
        )
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO memory_note (
                  id, pet_id, text, tags, importance, source, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    note.id,
                    note.pet_id,
                    note.text,
                    note.tags,
                    note.importance,
                    note.source,
                    note.created_at,
                ),
            )
            conn.commit()
        return note

    def search_memories(self, pet_id: str, query: str | None = None, limit: int = 10) -> list[MemoryNote]:
        if query:
            pattern = f"%{query}%"
            sql = """
                SELECT * FROM memory_note
                WHERE pet_id = ? AND (text LIKE ? OR tags LIKE ?)
                ORDER BY importance DESC, created_at DESC
                LIMIT ?
            """
            params: tuple[Any, ...] = (pet_id, pattern, pattern, limit)
        else:
            sql = """
                SELECT * FROM memory_note
                WHERE pet_id = ?
                ORDER BY importance DESC, created_at DESC
                LIMIT ?
            """
            params = (pet_id, limit)

        with closing(self.connect()) as conn:
            rows = conn.execute(sql, params).fetchall()
        return [_memory_from_row(row) for row in rows]

    def upsert_persona(
        self,
        *,
        pet_id: str,
        profile: dict[str, Any],
        system_prompt: str,
    ) -> dict[str, Any]:
        updated_at = utc_now_iso()
        profile_json = json.dumps(profile, ensure_ascii=False)
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO pet_persona (pet_id, profile_json, system_prompt, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(pet_id) DO UPDATE SET
                  profile_json = excluded.profile_json,
                  system_prompt = excluded.system_prompt,
                  updated_at = excluded.updated_at
                """,
                (pet_id, profile_json, system_prompt, updated_at),
            )
            conn.commit()
        return {"profile": profile, "system_prompt": system_prompt, "updated_at": updated_at}

    def get_persona(self, pet_id: str) -> dict[str, Any] | None:
        with closing(self.connect()) as conn:
            row = conn.execute(
                "SELECT profile_json, system_prompt, updated_at FROM pet_persona WHERE pet_id = ?",
                (pet_id,),
            ).fetchone()
        if row is None:
            return None
        profile = json.loads(row["profile_json"])
        profile["system_prompt"] = row["system_prompt"]
        return {"profile": profile, "system_prompt": row["system_prompt"], "updated_at": row["updated_at"]}

    def upsert_wechat_settings(self, *, pet_id: str, settings: dict[str, Any]) -> dict[str, Any]:
        updated_at = utc_now_iso()
        settings_json = json.dumps(settings, ensure_ascii=False)
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO wechat_settings (pet_id, settings_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(pet_id) DO UPDATE SET
                  settings_json = excluded.settings_json,
                  updated_at = excluded.updated_at
                """,
                (pet_id, settings_json, updated_at),
            )
            conn.commit()
        return {"settings": settings, "updated_at": updated_at}

    def get_wechat_settings(self, pet_id: str) -> dict[str, Any] | None:
        with closing(self.connect()) as conn:
            row = conn.execute(
                "SELECT settings_json, updated_at FROM wechat_settings WHERE pet_id = ?",
                (pet_id,),
            ).fetchone()
        if row is None:
            return None
        return {"settings": json.loads(row["settings_json"]), "updated_at": row["updated_at"]}

    def try_mark_wechat_message_seen(
        self,
        *,
        pet_id: str,
        group_name: str,
        sender_name: str,
        fingerprint: str,
        summary: str,
    ) -> bool:
        try:
            with closing(self.connect()) as conn:
                conn.execute(
                    """
                    INSERT INTO wechat_seen_message (
                      fingerprint, pet_id, group_name, sender_name, summary, created_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (fingerprint, pet_id, group_name, sender_name, summary, utc_now_iso()),
                )
                conn.commit()
            return True
        except sqlite3.IntegrityError:
            return False

    def record_wechat_reply(
        self,
        *,
        pet_id: str,
        group_name: str,
        trace_id: str,
        status: str,
    ) -> dict[str, Any]:
        record = {
            "id": str(uuid.uuid4()),
            "pet_id": pet_id,
            "group_name": group_name,
            "trace_id": trace_id,
            "status": status,
            "created_at": utc_now_iso(),
        }
        with closing(self.connect()) as conn:
            conn.execute(
                """
                INSERT INTO wechat_reply_record (
                  id, pet_id, group_name, trace_id, status, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    record["id"],
                    record["pet_id"],
                    record["group_name"],
                    record["trace_id"],
                    record["status"],
                    record["created_at"],
                ),
            )
            conn.commit()
        return record

    def count_wechat_replies_since(
        self,
        *,
        pet_id: str,
        group_name: str | None,
        since_iso: str,
        statuses: Iterable[str] = ("generated", "manual_review", "sent"),
    ) -> int:
        status_list = list(statuses)
        placeholders = ",".join("?" for _ in status_list)
        params: list[Any] = [pet_id, since_iso, *status_list]
        group_clause = ""
        if group_name is not None:
            group_clause = "AND group_name = ?"
            params.insert(1, group_name)
        sql = f"""
            SELECT COUNT(*) AS count FROM wechat_reply_record
            WHERE pet_id = ?
              {group_clause}
              AND created_at >= ?
              AND status IN ({placeholders})
        """
        with closing(self.connect()) as conn:
            row = conn.execute(sql, tuple(params)).fetchone()
        return int(row["count"])


def _profile_from_row(row: sqlite3.Row) -> PetProfile:
    return PetProfile(
        id=row["id"],
        name=row["name"],
        species=row["species"],
        breed=row["breed"],
        birthday=row["birthday"],
        sex=row["sex"],
        neutered=None if row["neutered"] is None else bool(row["neutered"]),
        personality=row["personality"],
        medical_notes=row["medical_notes"],
        created_at=row["created_at"],
    )


def _event_from_row(row: sqlite3.Row) -> PetEvent:
    return PetEvent(
        id=row["id"],
        pet_id=row["pet_id"],
        event_type=row["event_type"],
        event_time=row["event_time"],
        source=row["source"],
        summary=row["summary"],
        payload_json=row["payload_json"],
        next_due_at=row["next_due_at"],
        created_at=row["created_at"],
    )


def _memory_from_row(row: sqlite3.Row) -> MemoryNote:
    return MemoryNote(
        id=row["id"],
        pet_id=row["pet_id"],
        text=row["text"],
        tags=row["tags"],
        importance=row["importance"],
        source=row["source"],
        created_at=row["created_at"],
    )
