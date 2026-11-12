"""Samplesheet management endpoints."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException

from dependencies import get_config_repo, get_samplesheet_repo
from models import SamplesheetPayload
from repositories import ConfigRepository, SamplesheetRepository

router = APIRouter(prefix="/api/samplesheet", tags=["samplesheet"])

ConfigRepoDep = Annotated[ConfigRepository, Depends(get_config_repo)]
SamplesheetRepoDep = Annotated[SamplesheetRepository, Depends(get_samplesheet_repo)]


@router.get("")
async def get_samplesheet(repo: SamplesheetRepoDep) -> dict[str, Any]:
    return {"rows": repo.load()}


@router.put("")
async def update_samplesheet(
    payload: SamplesheetPayload,
    repo: SamplesheetRepoDep,
) -> dict[str, Any]:
    count = repo.save(payload.rows)
    return {"status": "ok", "count": count}


@router.post("/discover")
async def discover_samples(
    config_repo: ConfigRepoDep,
    samples_repo: SamplesheetRepoDep,
) -> dict[str, Any]:
    try:
        cfg, _ = config_repo.load()
    except FileNotFoundError as exc:
        raise HTTPException(status_code=400, detail="Config file missing") from exc

    if not cfg.input_dir:
        return {"discovered": [], "error": "Input directory is not configured"}

    try:
        sample_ids = samples_repo.discover_bams(Path(cfg.input_dir))
    except FileNotFoundError as exc:
        return {"discovered": [], "error": str(exc)}
    return {"discovered": sample_ids}
