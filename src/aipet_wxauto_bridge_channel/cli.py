from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import logging
import os
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterator

from .channel import AipetWxautoBridgeChannel, ChannelConfig


def main() -> None:
    parser = argparse.ArgumentParser(description="Run AI Pet wxauto Bridge channel.")
    parser.add_argument("--config", default="", help="Path to wxauto-channel config.yaml.")
    parser.add_argument("--bridge-url", default="", help="AI Pet Bridge base URL.")
    parser.add_argument("--pet-id", default="", help="AI Pet pet_id.")
    parser.add_argument("--dry-run", action="store_true", help="Generate decisions without sending WeChat replies.")
    parser.add_argument(
        "--once-json",
        default="",
        help="Handle one wxauto message JSON file, or '-' for stdin, then exit. Always dry-runs.",
    )
    parser.add_argument(
        "--once-output",
        default="",
        help="Optional UTF-8 JSON file for --once-json result.",
    )
    parser.add_argument("--log-level", default="INFO", help="Python logging level.")
    parser.add_argument("--log-file", default="", help="Optional channel log file path.")
    parser.add_argument("--lock-file", default="", help="Optional single-instance lock file path.")
    parser.add_argument("--no-lock", action="store_true", help="Disable the channel single-instance lock.")
    args = parser.parse_args()

    log_handlers: list[logging.Handler] = [logging.StreamHandler()]
    if args.log_file:
        log_path = Path(args.log_file)
    else:
        log_path = Path(os.getenv("AIPET_LOGS_DIR", "logs")) / "aipet-wxauto-bridge-channel.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handlers.append(logging.FileHandler(log_path, encoding="utf-8"))

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=log_handlers,
    )

    config_path = Path(args.config or _default_config_path())
    config = ChannelConfig.from_yaml(
        config_path,
        bridge_url=args.bridge_url or None,
        pet_id=args.pet_id or None,
    )
    channel = AipetWxautoBridgeChannel(config=config, dry_run=args.dry_run or bool(args.once_json))
    if args.once_json:
        message = _read_once_message(args.once_json)
        result = channel.handle_message(message)
        payload = {
            "action": result.action,
            "reason": result.reason,
            "trace_id": result.trace_id,
            "sent": result.sent,
            "reply_text": result.reply_text,
            "decision": result.decision,
        }
        payload_text = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        if args.once_output:
            Path(args.once_output).write_text(payload_text + "\n", encoding="utf-8")
        print(payload_text)
        return

    lock_path = Path(args.lock_file) if args.lock_file else _default_lock_path(log_path)
    with _channel_lock(lock_path, disabled=args.no_lock):
        asyncio.run(channel.run())


class ChannelLock:
    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.acquired = False

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._write_new_lock()
        except FileExistsError:
            existing = self._read_existing_lock()
            pid = _safe_int(existing.get("pid"))
            if pid and not _pid_exists(pid):
                self.path.unlink(missing_ok=True)
                self._write_new_lock()
                return
            detail = f"pid={pid}" if pid else "unknown owner"
            raise RuntimeError(
                "AI Pet wxauto Bridge channel already appears to be running "
                f"({detail}, lock={self.path}). Stop the existing channel first."
            )

    def release(self) -> None:
        if self.acquired:
            self.path.unlink(missing_ok=True)
            self.acquired = False

    def _write_new_lock(self) -> None:
        fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "pid": os.getpid(),
                    "started_at": datetime.now(tz=UTC).replace(microsecond=0).isoformat(),
                },
                handle,
                separators=(",", ":"),
            )
            handle.write("\n")
        self.acquired = True

    def _read_existing_lock(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except Exception:
            return {}
        return data if isinstance(data, dict) else {}


@contextlib.contextmanager
def _channel_lock(path: Path, *, disabled: bool = False) -> Iterator[None]:
    if disabled:
        yield
        return
    lock = ChannelLock(path)
    lock.acquire()
    try:
        yield
    finally:
        lock.release()


def _default_lock_path(log_path: Path) -> Path:
    return log_path.with_suffix(".lock")


def _safe_int(value: object) -> int:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return 0


def _pid_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    if pid == os.getpid():
        return True
    if os.name == "nt":
        return _windows_pid_exists(pid)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _windows_pid_exists(pid: int) -> bool:
    try:
        import ctypes
    except Exception:
        return True

    process_query_limited_information = 0x1000
    still_active = 259
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_ulong()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return True
        return exit_code.value == still_active
    finally:
        kernel32.CloseHandle(handle)


def _default_config_path() -> Path:
    root = os.getenv("AIPET_WXAUTO_CHANNEL_ROOT") or ".cache/openclaw-wechat-channel"
    return Path(root) / "wxauto-channel" / "config.yaml"


def _read_once_message(path: str) -> dict:
    if path == "-":
        raw = sys.stdin.read()
    else:
        raw = Path(path).read_text(encoding="utf-8-sig")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("once-json must be a JSON object.")
    return data


if __name__ == "__main__":
    main()
