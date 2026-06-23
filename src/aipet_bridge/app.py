from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .config import Settings, load_settings
from .models import PetProfile
from .persona import questionnaire_schema
from .service import AipetBridgeService
from .storage import SQLiteStore
from .wechat import normalize_wechat_settings


class PetProfileUpsert(BaseModel):
    name: str = Field(min_length=1, examples=["猫咪"])
    species: str = Field(default="cat", min_length=1)
    breed: str | None = None
    birthday: str | None = None
    sex: str | None = None
    neutered: bool | None = None
    personality: str | None = None
    medical_notes: str | None = None


class EventCreate(BaseModel):
    event_type: str = Field(min_length=1, examples=["feeding"])
    source: str = Field(min_length=1, examples=["manual"])
    summary: str = Field(min_length=1, examples=["刚刚喂了一次猫。"])
    payload: dict[str, Any] | None = None
    next_due_at: str | None = None


class MemoryCreate(BaseModel):
    text: str = Field(min_length=1, examples=["猫咪喜欢在窗边晒太阳。"])
    tags: list[str] | None = None
    importance: int = Field(default=1, ge=1, le=5)
    source: str | None = None


class PersonaQuestionnaireSubmit(BaseModel):
    answers: dict[str, int]
    open_answers: dict[str, str] | None = None


class WechatSettingsUpdate(BaseModel):
    pet_wechat_name: str | None = None
    family_groups: list[str] | None = None
    private_contact_allowlist: list[str] | None = None
    wake_words: list[str] | None = None
    require_mention: bool | None = None
    manual_review: bool | None = None
    auto_reply_enabled: bool | None = None
    private_auto_reply_enabled: bool | None = None
    emergency_stop: bool | None = None
    quiet_hours_start: str | None = None
    quiet_hours_end: str | None = None
    rate_limit_minutes: int | None = Field(default=None, ge=1, le=1440)
    private_rate_limit_minutes: int | None = Field(default=None, ge=1, le=1440)
    daily_limit: int | None = Field(default=None, ge=1, le=300)
    private_daily_limit: int | None = Field(default=None, ge=1, le=300)
    max_reply_chars: int | None = Field(default=None, ge=20, le=500)


class WechatReplyRequest(BaseModel):
    group_name: str = Field(min_length=1)
    sender_name: str = Field(min_length=1)
    message_text: str = Field(min_length=1)
    recent_context: list[dict[str, Any]] | None = None
    mentioned: bool = False
    observed_at: str | None = None
    message_fingerprint: str | None = None
    trace_id: str | None = None


class WechatPrivateReplyRequest(BaseModel):
    contact_name: str = Field(min_length=1)
    message_text: str = Field(min_length=1)
    recent_context: list[dict[str, Any]] | None = None
    observed_at: str | None = None
    message_fingerprint: str | None = None
    trace_id: str | None = None


class ManualDecisionRequest(BaseModel):
    trace_id: str = Field(min_length=1)
    group_name: str = Field(min_length=1)
    decision: str = Field(pattern="^(approved|rejected)$")
    note: str | None = None


class PrivateSentRequest(BaseModel):
    contact_name: str = Field(min_length=1)
    trace_id: str = Field(min_length=1)
    message_fingerprint: str = Field(min_length=1)


class ToolPetStateRequest(BaseModel):
    pet_id: str | None = None


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    store = SQLiteStore(settings.database_path)
    service = AipetBridgeService(settings=settings, store=store)
    service.initialize()

    app = FastAPI(
        title="AI Pet Bridge",
        version="0.2.0",
        description="Local bridge service for AI pet state, persona, WeChat controls, logs, and agent tools.",
    )
    app.state.settings = settings
    app.state.service = service

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "default_pet_id": settings.default_pet_id,
            "openclaw_configured": bool(settings.openclaw_base_url),
        }

    @app.get("/ui", include_in_schema=False)
    def ui() -> FileResponse:
        return FileResponse(Path(__file__).with_name("static") / "index.html")

    @app.get("/pets/{pet_id}/profile")
    def get_pet_profile(pet_id: str) -> dict[str, Any]:
        profile = store.get_pet_profile(pet_id)
        if profile is None:
            raise HTTPException(status_code=404, detail=f"Unknown pet_id: {pet_id}")
        return profile.to_dict()

    @app.put("/pets/{pet_id}/profile")
    def upsert_pet_profile(pet_id: str, request: PetProfileUpsert) -> dict[str, Any]:
        existing = store.get_pet_profile(pet_id)
        profile = PetProfile(
            id=pet_id,
            name=request.name,
            species=request.species,
            breed=request.breed,
            birthday=request.birthday,
            sex=request.sex,
            neutered=request.neutered,
            personality=request.personality,
            medical_notes=request.medical_notes,
            created_at=existing.created_at if existing else "",
        )
        return service.upsert_pet_profile(profile)

    @app.get("/pets/{pet_id}/state")
    def get_pet_state(pet_id: str) -> dict[str, Any]:
        try:
            return service.get_pet_current_state(pet_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/events")
    def add_event(pet_id: str, event: EventCreate) -> dict[str, Any]:
        try:
            return service.add_event(
                pet_id=pet_id,
                event_type=event.event_type,
                source=event.source,
                summary=event.summary,
                payload=event.payload,
                next_due_at=event.next_due_at,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/pets/{pet_id}/memories")
    def search_memories(
        pet_id: str,
        query: str | None = Query(default=None),
        limit: int = Query(default=10, ge=1, le=50),
    ) -> list[dict[str, Any]]:
        try:
            return service.search_memories(pet_id, query=query, limit=limit)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/memories")
    def add_memory(pet_id: str, memory: MemoryCreate) -> dict[str, Any]:
        try:
            return service.add_memory(
                pet_id=pet_id,
                text=memory.text,
                tags=memory.tags,
                importance=memory.importance,
                source=memory.source,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/pets/{pet_id}/persona/questionnaire-schema")
    def get_questionnaire_schema(pet_id: str) -> dict[str, Any]:
        try:
            service.get_pet_current_state(pet_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return questionnaire_schema()

    @app.post("/pets/{pet_id}/persona/questionnaire")
    def submit_persona_questionnaire(
        pet_id: str,
        request: PersonaQuestionnaireSubmit,
    ) -> dict[str, Any]:
        try:
            return service.generate_persona(
                pet_id=pet_id,
                answers=request.answers,
                open_answers=request.open_answers,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/pets/{pet_id}/persona")
    def get_persona(pet_id: str) -> dict[str, Any]:
        try:
            return service.get_persona(pet_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/pets/{pet_id}/wechat/settings")
    def get_wechat_settings(pet_id: str) -> dict[str, Any]:
        try:
            return service.get_wechat_settings(pet_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.put("/pets/{pet_id}/wechat/settings")
    def update_wechat_settings(pet_id: str, request: WechatSettingsUpdate) -> dict[str, Any]:
        try:
            current = service.get_wechat_settings(pet_id)["settings"]
            updates = {key: value for key, value in _model_dump(request).items() if value is not None}
            return service.save_wechat_settings(
                pet_id=pet_id,
                settings=normalize_wechat_settings({**current, **updates}),
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/wechat/reply")
    def preview_wechat_reply(pet_id: str, request: WechatReplyRequest) -> dict[str, Any]:
        try:
            return service.preview_wechat_reply(
                pet_id=pet_id,
                group_name=request.group_name,
                sender_name=request.sender_name,
                message_text=request.message_text,
                recent_context=request.recent_context,
                mentioned=request.mentioned,
                observed_at=request.observed_at,
                message_fingerprint_value=request.message_fingerprint,
                trace_id=request.trace_id,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/wechat/private-reply")
    def preview_private_reply(pet_id: str, request: WechatPrivateReplyRequest) -> dict[str, Any]:
        try:
            return service.preview_private_reply(
                pet_id=pet_id,
                contact_name=request.contact_name,
                message_text=request.message_text,
                recent_context=request.recent_context,
                observed_at=request.observed_at,
                message_fingerprint_value=request.message_fingerprint,
                trace_id=request.trace_id,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/wechat/manual-decision")
    def record_manual_decision(pet_id: str, request: ManualDecisionRequest) -> dict[str, Any]:
        try:
            return service.record_manual_decision(
                pet_id=pet_id,
                trace_id=request.trace_id,
                group_name=request.group_name,
                decision=request.decision,
                note=request.note,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/pets/{pet_id}/wechat/private-sent")
    def record_private_sent(pet_id: str, request: PrivateSentRequest) -> dict[str, Any]:
        try:
            return service.record_private_sent(
                pet_id=pet_id,
                contact_name=request.contact_name,
                trace_id=request.trace_id,
                message_fingerprint=request.message_fingerprint,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/logs")
    def query_logs(
        trace_id: str | None = Query(default=None),
        service_name: str | None = Query(default=None, alias="service"),
        level: str | None = Query(default=None),
        event: str | None = Query(default=None),
        limit: int = Query(default=200, ge=1, le=1000),
    ) -> list[dict[str, Any]]:
        return service.query_logs(
            trace_id=trace_id,
            service=service_name,
            level=level,
            event=event,
            limit=limit,
        )

    @app.post("/tools/get_pet_current_state")
    def tool_get_pet_current_state(request: ToolPetStateRequest) -> dict[str, Any]:
        pet_id = request.pet_id or settings.default_pet_id
        try:
            return service.get_pet_current_state(pet_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    return app


def _model_dump(model: BaseModel) -> dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump()
    return model.dict()


app = create_app()
