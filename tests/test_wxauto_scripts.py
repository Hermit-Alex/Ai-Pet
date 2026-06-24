from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path
from uuid import uuid4


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _powershell_exe() -> str | None:
    return shutil.which("powershell") or shutil.which("pwsh")


def _decode_output(value: bytes | str | None) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    for encoding in ("utf-8", "gbk", "mbcs"):
        try:
            return value.decode(encoding)
        except UnicodeDecodeError:
            continue
    return value.decode("utf-8", errors="replace")


class WxautoPowerShellScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        powershell = _powershell_exe()
        if not powershell:
            self.skipTest("PowerShell is not available.")
        self.powershell = powershell
        self.lock_path = PROJECT_ROOT / "logs" / "aipet-wxauto-bridge-channel.lock"
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self.original_lock = (
            self.lock_path.read_bytes() if self.lock_path.exists() else None
        )
        self.log_paths = [
            PROJECT_ROOT / "logs" / "wechat-sidecar.jsonl",
            PROJECT_ROOT / "logs" / "aipet-bridge.jsonl",
            PROJECT_ROOT / "logs" / "audit-events.jsonl",
            PROJECT_ROOT / "logs" / "errors.jsonl",
        ]
        self.original_logs = {
            path: path.read_bytes() if path.exists() else None
            for path in self.log_paths
        }

    def tearDown(self) -> None:
        if self.original_lock is None:
            self.lock_path.unlink(missing_ok=True)
        else:
            self.lock_path.write_bytes(self.original_lock)
        for path, original in self.original_logs.items():
            if original is None:
                path.unlink(missing_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(original)

    def run_ps(self, script: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [
                self.powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(PROJECT_ROOT / "scripts" / script),
                *args,
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            check=False,
        )
        result.stdout = _decode_output(result.stdout)
        result.stderr = _decode_output(result.stderr)
        if check and result.returncode:
            raise subprocess.CalledProcessError(
                result.returncode,
                result.args,
                output=result.stdout,
                stderr=result.stderr,
            )
        return result

    def write_stale_lock(self) -> None:
        self.lock_path.write_text(
            json.dumps({"pid": -1, "started_at": "2026-06-24T00:00:00+00:00"}) + "\n",
            encoding="utf-8",
        )

    def test_stop_script_removes_stale_channel_lock(self) -> None:
        self.write_stale_lock()

        result = self.run_ps("stop-wxauto-openclaw-channel.ps1", "-OnlyClearStaleLock")

        self.assertEqual(result.returncode, 0)
        self.assertIn("Removing stale wxauto Bridge channel lock", result.stdout)
        self.assertFalse(self.lock_path.exists())

    def test_status_strict_fails_on_stale_channel_lock(self) -> None:
        self.write_stale_lock()

        result = self.run_ps("wxauto-openclaw-status.ps1", "-Strict", check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wxauto Bridge channel single-instance lock", result.stdout)
        self.assertIn("stale pid=-1", result.stdout)
        self.assertIn("stop-wxauto-openclaw-channel.ps1 -OnlyClearStaleLock", result.stdout)

    def test_e2e_assertion_reports_model_path_blocked_outcome(self) -> None:
        trace_id = "trace-model-path-" + uuid4().hex[:8]
        records = [
            {
                "ts": "2026-06-24T08:00:00+00:00",
                "level": "info",
                "service": "aipet-wxauto-bridge-channel",
                "event": "wechat.wxauto.detected",
                "trace_id": trace_id,
                "target_name": "dad",
            },
            {
                "ts": "2026-06-24T08:00:01+00:00",
                "level": "info",
                "service": "aipet-bridge",
                "event": "bridge.reply.started",
                "trace_id": trace_id,
                "contact_name": "dad",
            },
            {
                "ts": "2026-06-24T08:00:02+00:00",
                "level": "info",
                "service": "aipet-bridge",
                "event": "wechat.private.reply.generated",
                "trace_id": trace_id,
                "contact_name": "dad",
                "model_source": "local_fallback",
            },
            {
                "ts": "2026-06-24T08:00:03+00:00",
                "level": "info",
                "service": "aipet-wxauto-bridge-channel",
                "event": "wechat.wxauto.model_path_blocked",
                "trace_id": trace_id,
                "target_name": "dad",
                "block_reason": "openclaw_required",
                "model_source": "local_fallback",
            },
        ]
        sidecar_log = PROJECT_ROOT / "logs" / "wechat-sidecar.jsonl"
        bridge_log = PROJECT_ROOT / "logs" / "aipet-bridge.jsonl"
        audit_log = PROJECT_ROOT / "logs" / "audit-events.jsonl"
        sidecar_log.write_text(
            "\n".join(json.dumps(record, ensure_ascii=False) for record in (records[0], records[3])) + "\n",
            encoding="utf-8",
        )
        bridge_log.write_text(json.dumps(records[1], ensure_ascii=False) + "\n", encoding="utf-8")
        audit_log.write_text(json.dumps(records[2], ensure_ascii=False) + "\n", encoding="utf-8")

        result = self.run_ps(
            "assert-aipet-wechat-e2e.ps1",
            "-TraceId",
            trace_id,
            "-RequireOpenClaw",
            "-RequireRealSend",
            "-Strict",
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OpenClaw model path used", result.stdout)
        self.assertIn("real WeChat reply sent", result.stdout)
        self.assertIn("event=wechat.wxauto.model_path_blocked", result.stdout)
        self.assertIn("reason=openclaw_required", result.stdout)

    def test_e2e_assertion_exports_success_proof_for_openclaw_real_send(self) -> None:
        trace_id = "trace-proof-" + uuid4().hex[:8]
        records = [
            {
                "ts": "2026-06-24T08:10:00+00:00",
                "level": "info",
                "service": "aipet-wxauto-bridge-channel",
                "event": "wechat.wxauto.detected",
                "trace_id": trace_id,
                "target_name": "dad",
            },
            {
                "ts": "2026-06-24T08:10:01+00:00",
                "level": "info",
                "service": "aipet-bridge",
                "event": "bridge.reply.started",
                "trace_id": trace_id,
                "contact_name": "dad",
            },
            {
                "ts": "2026-06-24T08:10:02+00:00",
                "level": "info",
                "service": "aipet-bridge",
                "event": "bridge.openclaw.completed",
                "trace_id": trace_id,
                "contact_name": "dad",
            },
            {
                "ts": "2026-06-24T08:10:03+00:00",
                "level": "info",
                "service": "aipet-bridge",
                "event": "wechat.private.reply.generated",
                "trace_id": trace_id,
                "contact_name": "dad",
                "model_source": "openclaw",
            },
            {
                "ts": "2026-06-24T08:10:04+00:00",
                "level": "info",
                "service": "aipet-wxauto-bridge-channel",
                "event": "wechat.wxauto.reply_sent",
                "trace_id": trace_id,
                "target_name": "dad",
            },
        ]
        sidecar_log = PROJECT_ROOT / "logs" / "wechat-sidecar.jsonl"
        bridge_log = PROJECT_ROOT / "logs" / "aipet-bridge.jsonl"
        audit_log = PROJECT_ROOT / "logs" / "audit-events.jsonl"
        sidecar_log.write_text(
            "\n".join(json.dumps(record, ensure_ascii=False) for record in (records[0], records[4])) + "\n",
            encoding="utf-8",
        )
        bridge_log.write_text(
            "\n".join(json.dumps(record, ensure_ascii=False) for record in (records[1], records[2])) + "\n",
            encoding="utf-8",
        )
        audit_log.write_text(json.dumps(records[3], ensure_ascii=False) + "\n", encoding="utf-8")
        proof_path = PROJECT_ROOT / "logs" / f"proof-{uuid4().hex}.json"
        self.addCleanup(lambda: proof_path.unlink(missing_ok=True))

        result = self.run_ps(
            "assert-aipet-wechat-e2e.ps1",
            "-TraceId",
            trace_id,
            "-RequireOpenClaw",
            "-RequireRealSend",
            "-Strict",
            "-ProofPath",
            str(proof_path),
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("proof_path:", result.stdout)
        proof = json.loads(proof_path.read_text(encoding="utf-8-sig"))
        self.assertEqual(proof["trace_id"], trace_id)
        self.assertEqual(proof["model_path"], "openclaw")
        self.assertTrue(proof["requirements"]["require_openclaw"])
        self.assertTrue(proof["requirements"]["require_real_send"])
        self.assertTrue(proof["checks"]["openclaw_model_path_used"])
        self.assertTrue(proof["checks"]["real_wechat_reply_sent"])
        self.assertEqual(proof["latest_outcome"]["event"], "wechat.wxauto.reply_sent")

    def test_user_facing_wechat_commands_use_no_profile(self) -> None:
        files = [
            PROJECT_ROOT / "README.md",
            PROJECT_ROOT / "scripts" / "setup-wxauto-openclaw-channel.ps1",
            PROJECT_ROOT / "scripts" / "setup-ai-pet-wechat-full.ps1",
            PROJECT_ROOT / "scripts" / "set-wxautox-home-mode.ps1",
            PROJECT_ROOT / "scripts" / "start-aipet-wechat-private-full-e2e.ps1",
        ]
        for path in files:
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("powershell -ExecutionPolicy", text)

    def test_full_setup_starts_bridge_without_reload_in_background(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "setup-ai-pet-wechat-full.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("run-bridge.ps1' -NoReload", text)
        self.assertIn("aipet-bridge-console.log", text)
        self.assertIn("Assert-BridgePolicyReady", text)
        self.assertIn("startup stability check", text)

    def test_full_setup_can_forward_explicit_weixin_process_check_skip(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "setup-ai-pet-wechat-full.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("[switch]$SkipWeixinProcessCheck", text)
        self.assertIn('$startWxautoArgs += "-SkipWeixinProcessCheck"', text)

    def test_family_config_all_group_mode_delegates_trigger_decision_to_bridge(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "configure-aipet-wechat-family.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn('$updated["require_mention"] = ($GroupReplyMode -ne "all")', text)
        self.assertIn("-GroupReplyMode $GroupReplyMode", text)

    def test_family_config_scripts_split_fullwidth_punctuation_explicitly(self) -> None:
        for path in (
            PROJECT_ROOT / "scripts" / "configure-aipet-wechat-family.ps1",
            PROJECT_ROOT / "scripts" / "configure-wxauto-openclaw-channel.ps1",
        ):
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertIn("[char]0xFF0C", text)
                self.assertIn("[char]0xFF1B", text)
                self.assertIn('-split "[,;\\r\\n]+"', text)

    def test_live_test_can_default_to_private_or_family_group_target(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "start-aipet-wechat-live-test.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("function Get-DefaultTargetName", text)
        self.assertIn("private_contact_allowlist", text)
        self.assertIn("family_groups", text)
        self.assertIn("private contact or family group", text)

    def test_wxauto_start_fails_closed_without_desktop_wechat_by_default(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "start-aipet-wxauto-bridge-channel.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("[switch]$SkipWeixinProcessCheck", text)
        self.assertIn("Get-Process Weixin, WeChat", text)
        self.assertIn("Windows WeChat desktop is not running", text)
        self.assertIn("Use -SkipWeixinProcessCheck only for API-level debugging", text)

    def test_runtime_contract_uses_channel_websocket_url_builder(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "test-wxauto-runtime-contract.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("build_listen_ws_url", text)
        self.assertIn("auto_start=False", text)

    def test_runtime_contract_initializes_wechat_before_listen_checks(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "test-wxauto-runtime-contract.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("/v1/wechat/initialize", text)
        self.assertIn("WeChat desktop initialized", text)
        self.assertIn("wechat_initialize_message", text)

    def test_readiness_audit_exposes_machine_readable_phases(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "audit-ai-pet-wechat-full-readiness.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("ready_for_repair_verify", text)
        self.assertIn("ready_for_full_e2e", text)
        self.assertIn("full_e2e_verified", text)
        self.assertIn("RequiredPhase", text)
        self.assertIn("config.target_name", text)
        self.assertIn("requested target is configured for wxauto listen", text)
        self.assertIn("proof.full_e2e", text)
        self.assertIn("next_actions", text)

    def test_readiness_audit_outputs_json_without_secret_values(self) -> None:
        result = self.run_ps("audit-ai-pet-wechat-full-readiness.ps1", check=False)

        self.assertIn('"phases"', result.stdout)
        self.assertIn('"checks"', result.stdout)
        payload = json.loads(result.stdout)
        check_ids = {check["id"] for check in payload["checks"]}
        self.assertIn("config.target_name", check_ids)
        self.assertNotIn("WXAUTOX4_LICENSE_KEY", result.stdout)
        self.assertNotRegex(result.stdout, r"sk-[A-Za-z0-9_-]{16,}")

    def test_status_and_doctor_report_desktop_wechat_process(self) -> None:
        for path in (
            PROJECT_ROOT / "scripts" / "wxauto-openclaw-status.ps1",
            PROJECT_ROOT / "scripts" / "doctor-ai-pet-wechat-full.ps1",
        ):
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertIn("Windows WeChat desktop process", text)
                self.assertIn("Get-Process Weixin, WeChat", text)

    def test_status_suggests_switching_to_alternate_activated_wxautox_home(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "wxauto-openclaw-status.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("Get-WxautoxActivationStatus", text)
        self.assertIn('"-HomeMode", $HomeMode', text)
        self.assertIn("alternate_${alternateMode}=activated", text)
        self.assertIn("set-wxautox-home-mode.ps1 -Mode $alternateMode", text)

    def test_activation_script_verifies_activation_after_cli_or_api_activation(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "activate-wxautox4.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("function Test-ActivationOutput", text)
        self.assertIn('Invoke-Wxautox4Cli -Arguments @("-k")', text)
        self.assertIn("activation command finished but verification still reports not activated", text)
        self.assertIn("activation via API finished but verification still reports not activated", text)
        self.assertIn("wxautox4 activation command finished and verified", text)

    def test_status_reports_latest_full_e2e_proof(self) -> None:
        proof_path = PROJECT_ROOT / "logs" / f"aipet-wechat-full-e2e-proof-test-{uuid4().hex}.json"
        self.addCleanup(lambda: proof_path.unlink(missing_ok=True))
        proof_path.write_text(
            json.dumps(
                {
                    "proof_version": "2026-06-full-wechat-e2e",
                    "generated_at": "2026-06-24T08:20:00+00:00",
                    "trace_id": "trace-proof-status",
                    "target": "dad",
                    "requirements": {
                        "require_openclaw": True,
                        "require_real_send": True,
                        "allow_dry_run": False,
                    },
                    "checks": {
                        "detected": True,
                        "bridge_reply_started": True,
                        "reply_generated_or_requested": True,
                        "openclaw_model_path_used": True,
                        "real_wechat_reply_sent": True,
                        "dry_run": False,
                    },
                    "model_path": "openclaw",
                    "latest_outcome": {"event": "wechat.wxauto.reply_sent", "reason": ""},
                },
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )

        result = self.run_ps("wxauto-openclaw-status.ps1", check=False)

        self.assertIn("[OK] latest full E2E proof", result.stdout)
        self.assertIn("trace_id=trace-proof-status", result.stdout)
        self.assertIn("model_path=openclaw", result.stdout)

    def test_stop_script_has_netstat_port_pid_fallback(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "stop-wxauto-openclaw-channel.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("function Get-ListeningProcessIds", text)
        self.assertIn("Get-NetTCPConnection", text)
        self.assertIn("netstat -ano -p tcp", text)
        self.assertIn("Stopping process $processId on port $port", text)

    def test_live_wait_continues_when_trace_is_found_but_incomplete(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "wait-aipet-wechat-e2e.ps1").read_text(
            encoding="utf-8"
        )

        self.assertIn("Trace found; waiting for Bridge/OpenClaw/wxauto completion", text)
        self.assertIn("$lastAssertionText = $text", text)
        self.assertIn("never satisfied the requested assertion before timeout", text)
        self.assertNotIn("TRACE FOUND BUT ASSERTION FAILED", text)

    def test_cmd_wrappers_propagate_child_exit_codes(self) -> None:
        files = [
            PROJECT_ROOT / "scripts" / "repair-and-verify-ai-pet-wechat-full.cmd",
            PROJECT_ROOT / "scripts" / "repair-and-verify-ai-pet-wechat-full-desktop.cmd",
            PROJECT_ROOT / "scripts" / "start-ai-pet-wechat-full.cmd",
            PROJECT_ROOT / "scripts" / "restart-ai-pet-wechat-full.cmd",
            PROJECT_ROOT / "scripts" / "stop-ai-pet-wechat-full.cmd",
            PROJECT_ROOT / "scripts" / "run-bridge.cmd",
        ]
        for path in files:
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertIn('set "AIPET_EXIT=%ERRORLEVEL%"', text)
                self.assertIn("endlocal & exit /b %AIPET_EXIT%", text)

    def test_desktop_repair_cmd_runs_execute_and_pauses(self) -> None:
        text = (
            PROJECT_ROOT / "scripts" / "repair-and-verify-ai-pet-wechat-full-desktop.cmd"
        ).read_text(encoding="utf-8")

        self.assertIn("repair-and-verify-ai-pet-wechat-full.ps1", text)
        self.assertIn("-Execute", text)
        self.assertIn('if "%~1"==""', text)
        self.assertIn("pause >nul", text)
        self.assertIn("AI Pet full WeChat desktop run exited with code", text)

    def test_run_bridge_cmd_uses_powershell_entrypoint(self) -> None:
        text = (PROJECT_ROOT / "scripts" / "run-bridge.cmd").read_text(encoding="utf-8")

        self.assertIn("run-bridge.ps1", text)
        self.assertIn("-NoProfile", text)


if __name__ == "__main__":
    unittest.main()
