from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VERIFY_SCRIPT = PROJECT_ROOT / "scripts" / "verify-ai-pet-wechat-full.ps1"
REPAIR_VERIFY_SCRIPT = PROJECT_ROOT / "scripts" / "repair-and-verify-ai-pet-wechat-full.ps1"
REPAIR_VERIFY_CMD = PROJECT_ROOT / "scripts" / "repair-and-verify-ai-pet-wechat-full.cmd"
PRIVATE_FULL_E2E_SCRIPT = PROJECT_ROOT / "scripts" / "start-aipet-wechat-private-full-e2e.ps1"
DIAGNOSTICS_SCRIPT = PROJECT_ROOT / "scripts" / "export-aipet-wechat-diagnostics.ps1"


def _powershell_exe() -> str | None:
    return shutil.which("powershell") or shutil.which("pwsh")


class VerifyWechatFullScriptTest(unittest.TestCase):
    def run_plan(self, *args: str) -> dict:
        powershell = _powershell_exe()
        if not powershell:
            self.skipTest("PowerShell is not available.")

        result = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(VERIFY_SCRIPT),
                "-PlanOnly",
                *args,
            ],
            cwd=PROJECT_ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        json_start = result.stdout.find("{")
        self.assertGreaterEqual(json_start, 0, result.stdout)
        return json.loads(result.stdout[json_start:])

    def run_repair_plan(self, *args: str) -> dict:
        powershell = _powershell_exe()
        if not powershell:
            self.skipTest("PowerShell is not available.")

        result = subprocess.run(
            [
                powershell,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(REPAIR_VERIFY_SCRIPT),
                *args,
            ],
            cwd=PROJECT_ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        json_start = result.stdout.find("{")
        self.assertGreaterEqual(json_start, 0, result.stdout)
        return json.loads(result.stdout[json_start:])

    def test_live_full_e2e_plan_uses_strict_openclaw_real_send_path(self) -> None:
        plan = self.run_plan("-TargetName", "dad", "-RestartStack")

        self.assertEqual(plan["mode"], "live_full_e2e")
        self.assertFalse(plan["dry_run"])
        self.assertTrue(plan["proof_export"])
        self.assertEqual(plan["command_count"], 3)
        audit_args = plan["commands"][0]["arguments"]
        self.assertTrue(any(arg.endswith("audit-ai-pet-wechat-full-readiness.ps1") for arg in audit_args))
        self.assertIn("-RequiredPhase", audit_args)
        self.assertIn("repair_verify", audit_args)

        first_args = plan["commands"][1]["arguments"]
        self.assertTrue(any(arg.endswith("start-aipet-wechat-live-test.ps1") for arg in first_args))
        self.assertIn("-FullE2E", first_args)
        self.assertIn("-Strict", first_args)
        self.assertIn("-RestartStack", first_args)
        self.assertIn("dad", first_args)

        doctor_args = plan["commands"][2]["arguments"]
        self.assertTrue(any(arg.endswith("doctor-ai-pet-wechat-full.ps1") for arg in doctor_args))
        self.assertIn("-FullE2E", doctor_args)
        self.assertIn("-Strict", doctor_args)

    def test_temporary_private_auto_plan_restores_through_existing_e2e_script(self) -> None:
        plan = self.run_plan(
            "-TargetName",
            "dad",
            "-TemporaryPrivateAuto",
            "-PrivateRateLimitMinutes",
            "2",
            "-RestartStack",
        )

        self.assertEqual(plan["mode"], "temporary_private_auto")
        self.assertTrue(plan["proof_export"])
        self.assertEqual(plan["command_count"], 3)
        audit_args = plan["commands"][0]["arguments"]
        self.assertTrue(any(arg.endswith("audit-ai-pet-wechat-full-readiness.ps1") for arg in audit_args))

        first_args = plan["commands"][1]["arguments"]
        self.assertTrue(any(arg.endswith("start-aipet-wechat-private-full-e2e.ps1") for arg in first_args))
        self.assertIn("-PrivateRateLimitMinutes", first_args)
        self.assertIn("2", first_args)
        self.assertIn("-Strict", first_args)
        self.assertIn("-RestartStack", first_args)

    def test_dry_run_plan_does_not_wait_for_real_wechat_message(self) -> None:
        plan = self.run_plan("-DryRun")

        self.assertEqual(plan["mode"], "live_full_e2e")
        self.assertTrue(plan["dry_run"])
        self.assertFalse(plan["proof_export"])
        self.assertEqual(plan["command_count"], 1)
        args = plan["commands"][0]["arguments"]
        self.assertTrue(any(arg.endswith("wxauto-openclaw-status.ps1") for arg in args))
        self.assertNotIn("-FullE2E", args)
        self.assertNotIn("-Strict", args)

    def test_repair_verify_plan_clears_lock_activates_and_restarts_temporary_private_e2e(self) -> None:
        plan = self.run_repair_plan("-TargetName", "dad")

        self.assertFalse(plan["execute"])
        self.assertEqual(plan["mode"], "temporary-private-auto")
        self.assertTrue(plan["failure_diagnostics"])
        self.assertEqual(plan["command_count"], 3)

        clear_lock_args = plan["commands"][0]["arguments"]
        self.assertTrue(any(arg.endswith("stop-wxauto-openclaw-channel.ps1") for arg in clear_lock_args))
        self.assertIn("-OnlyClearStaleLock", clear_lock_args)

        activate_args = plan["commands"][1]["arguments"]
        self.assertTrue(any(arg.endswith("activate-wxautox4.ps1") for arg in activate_args))

        verify_args = plan["commands"][2]["arguments"]
        self.assertTrue(any(arg.endswith("verify-ai-pet-wechat-full.ps1") for arg in verify_args))
        self.assertIn("-TemporaryPrivateAuto", verify_args)
        self.assertIn("-RestartStack", verify_args)
        self.assertIn("dad", verify_args)

    def test_repair_verify_plan_can_skip_activation(self) -> None:
        plan = self.run_repair_plan("-Mode", "live", "-SkipActivation")

        self.assertTrue(plan["skip_activation"])
        self.assertEqual(plan["mode"], "live")
        self.assertEqual(plan["command_count"], 2)
        all_args = [arg for command in plan["commands"] for arg in command["arguments"]]
        self.assertFalse(any(arg.endswith("activate-wxautox4.ps1") for arg in all_args))
        self.assertNotIn("-TemporaryPrivateAuto", plan["commands"][-1]["arguments"])

    def test_repair_verify_plan_can_skip_failure_diagnostics(self) -> None:
        plan = self.run_repair_plan("-SkipFailureDiagnostics")

        self.assertFalse(plan["failure_diagnostics"])

    def test_repair_verify_cmd_wraps_powershell_entrypoint(self) -> None:
        text = REPAIR_VERIFY_CMD.read_text(encoding="utf-8")

        self.assertIn("repair-and-verify-ai-pet-wechat-full.ps1", text)
        self.assertIn("-NoProfile", text)
        self.assertIn("%*", text)
        self.assertIn("exit /b %AIPET_EXIT%", text)

    def test_repair_verify_failure_diagnostics_mentions_bridge_console_log(self) -> None:
        text = REPAIR_VERIFY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("aipet-bridge-console.log", text)
        self.assertIn("audit-ai-pet-wechat-full-readiness.ps1", text)
        self.assertIn("export-aipet-wechat-diagnostics.ps1", text)

    def test_full_verify_runs_repair_readiness_audit_before_live_wait(self) -> None:
        text = VERIFY_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("function New-ReadinessAuditArgs", text)
        self.assertIn("audit-ai-pet-wechat-full-readiness.ps1", text)
        self.assertIn('"repair_verify"', text)
        self.assertIn("AI Pet WeChat repair-readiness audit failed", text)

    def test_temporary_private_e2e_fails_when_restore_or_runtime_restart_fails(self) -> None:
        text = PRIVATE_FULL_E2E_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("$finalExitCode = 1", text)
        self.assertIn("$output = & powershell @Arguments 2>&1", text)
        self.assertIn("foreach ($line in $output)", text)
        self.assertIn("$runtimeRestored = Restore-WxautoRuntimeAfterSettingsRestore", text)
        self.assertIn("if (-not $runtimeRestored)", text)

    def test_diagnostics_export_is_sanitized_and_skips_openclaw_self_test_by_default(self) -> None:
        text = DIAGNOSTICS_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("function Protect-DiagnosticText", text)
        self.assertIn("sk-<redacted>", text)
        self.assertIn("AIPET_WXAUTOX4_LICENSE_KEY", text)
        self.assertIn("redacted-long-token", text)
        self.assertIn("[switch]$IncludeOpenClawSelfTest", text)
        self.assertIn("skipped by default", text)
        self.assertIn("test-openclaw-bridge-path.ps1", text)
        self.assertIn("aipet-bridge-console.log", text)
        self.assertIn("aipet-wxauto-bridge-channel.log", text)


if __name__ == "__main__":
    unittest.main()
