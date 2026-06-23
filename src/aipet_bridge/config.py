from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    api_key: str | None
    data_dir: Path
    database_path: Path
    logs_dir: Path
    default_pet_id: str
    default_pet_name: str
    home_assistant_url: str | None
    home_assistant_token: str | None
    mqtt_url: str | None
    openclaw_base_url: str | None = None
    openclaw_api_key: str | None = None
    openclaw_model: str = "ai-pet-wechat"
    log_sensitive: bool = False


def _optional_env(name: str) -> str | None:
    value = os.getenv(name)
    if value is None or value.strip() == "":
        return None
    return value


def _load_local_env_files() -> None:
    for env_file in (Path(".env"), Path(".env.local")):
        if not env_file.exists():
            continue
        for raw_line in env_file.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            os.environ.setdefault(key, value)


def load_settings() -> Settings:
    _load_local_env_files()
    data_dir = Path(os.getenv("AIPET_DATA_DIR", ".data")).expanduser()
    database_path = Path(os.getenv("AIPET_DATABASE_PATH", data_dir / "aipet.sqlite3")).expanduser()
    logs_dir = Path(os.getenv("AIPET_LOGS_DIR", "logs")).expanduser()
    return Settings(
        api_key=_optional_env("AIPET_API_KEY"),
        data_dir=data_dir,
        database_path=database_path,
        logs_dir=logs_dir,
        default_pet_id=os.getenv("AIPET_DEFAULT_PET_ID", "cat-home"),
        default_pet_name=os.getenv("AIPET_DEFAULT_PET_NAME", "猫咪"),
        home_assistant_url=_optional_env("AIPET_HOME_ASSISTANT_URL"),
        home_assistant_token=_optional_env("AIPET_HOME_ASSISTANT_TOKEN"),
        mqtt_url=_optional_env("AIPET_MQTT_URL"),
        openclaw_base_url=_optional_env("AIPET_OPENCLAW_BASE_URL"),
        openclaw_api_key=_optional_env("AIPET_OPENCLAW_API_KEY"),
        openclaw_model=os.getenv("AIPET_OPENCLAW_MODEL", "ai-pet-wechat"),
        log_sensitive=os.getenv("AIPET_LOG_SENSITIVE", "").lower() in {"1", "true", "yes", "on"},
    )
