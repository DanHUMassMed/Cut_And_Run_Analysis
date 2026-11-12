"""Configuration endpoints."""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException

from dependencies import get_config_repo
from models import ContrastsUpdatePayload, ExperimentConfigModel
from repositories import ConfigRepository

router = APIRouter(prefix="/api/config", tags=["config"])

ConfigRepoDep = Annotated[ConfigRepository, Depends(get_config_repo)]


@router.get("")
async def get_config(repo: ConfigRepoDep) -> dict[str, Any]:
    try:
        model, raw = repo.load()
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="experiment.config not found") from exc
    return {"config": model.model_dump(), "raw": raw}


@router.put("")
async def update_config(
    model: ExperimentConfigModel,
    repo: ConfigRepoDep,
) -> dict[str, Any]:
    repo.save(model)
    return {"status": "ok", "config": model.model_dump()}


@router.patch("/contrasts")
async def update_contrasts(
    payload: ContrastsUpdatePayload,
    repo: ConfigRepoDep,
) -> dict[str, Any]:
    try:
        updated = repo.update_contrasts(payload.diff_contrasts)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="experiment.config not found") from exc
    return {
        "status": "ok",
        "diff_contrasts": [c.model_dump() for c in updated.diff_contrasts],
    }
