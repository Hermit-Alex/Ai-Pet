param(
  [string]$PetId = "cat-home",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $VenvPython)) {
  throw "Python venv not found. Run scripts\setup-dev.ps1 first."
}

$env:PYTHONPATH = Join-Path $ProjectRoot "src"
$env:AIPET_COCO_APPLY_PET_ID = $PetId
$env:AIPET_COCO_APPLY_DRY_RUN = if ($DryRun) { "1" } else { "" }

$code = @'
import json
import os

from aipet_bridge.config import load_settings
from aipet_bridge.models import PetProfile
from aipet_bridge.persona_presets import COCO_PERSONA_PROFILE, COCO_SYSTEM_PROMPT
from aipet_bridge.service import AipetBridgeService
from aipet_bridge.storage import SQLiteStore

pet_id = os.environ.get("AIPET_COCO_APPLY_PET_ID", "cat-home")
dry_run = os.environ.get("AIPET_COCO_APPLY_DRY_RUN") == "1"

settings = load_settings()
store = SQLiteStore(settings.database_path)
service = AipetBridgeService(settings=settings, store=store)
service.initialize()

profile = dict(COCO_PERSONA_PROFILE)
profile["pet_id"] = pet_id

payload = {
    "pet_id": pet_id,
    "database_path": str(settings.database_path),
    "pet_name": profile["pet_name"],
    "nickname": profile["nickname"],
    "type_name": profile["type_name"],
    "prompt_chars": len(COCO_SYSTEM_PROMPT),
    "dry_run": dry_run,
}

if not dry_run:
    store.upsert_pet_profile(
        PetProfile(
            id=pet_id,
            name=profile["pet_name"],
            species=profile["species"],
            breed=profile["appearance"],
            sex=profile["sex_status"],
            neutered=True,
            personality=profile["type_name"],
        )
    )
    store.upsert_persona(
        pet_id=pet_id,
        profile=profile,
        system_prompt=COCO_SYSTEM_PROMPT,
    )

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
'@

$code | & $VenvPython -
