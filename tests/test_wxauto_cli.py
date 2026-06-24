from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from aipet_wxauto_bridge_channel.cli import ChannelLock, _default_lock_path


class WxautoCliLockTest(unittest.TestCase):
    def test_default_lock_path_tracks_log_file(self) -> None:
        log_path = Path("logs") / "aipet-wxauto-bridge-channel.log"

        self.assertEqual(
            _default_lock_path(log_path),
            Path("logs") / "aipet-wxauto-bridge-channel.lock",
        )

    def test_channel_lock_prevents_second_live_channel(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            lock_path = Path(temp_dir) / "channel.lock"
            first = ChannelLock(lock_path)
            first.acquire()
            self.addCleanup(first.release)

            second = ChannelLock(lock_path)
            with self.assertRaisesRegex(RuntimeError, "already appears to be running"):
                second.acquire()

    def test_channel_lock_replaces_stale_pid_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            lock_path = Path(temp_dir) / "channel.lock"
            lock_path.write_text(
                json.dumps({"pid": -1, "started_at": "2026-06-24T00:00:00+00:00"}) + "\n",
                encoding="utf-8",
            )

            lock = ChannelLock(lock_path)
            lock.acquire()
            self.addCleanup(lock.release)

            data = json.loads(lock_path.read_text(encoding="utf-8"))
            self.assertEqual(data["pid"], os.getpid())


if __name__ == "__main__":
    unittest.main()
