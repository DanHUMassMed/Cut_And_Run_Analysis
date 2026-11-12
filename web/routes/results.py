"""Pipeline results discovery and sandboxed file serving endpoints."""

from __future__ import annotations

import asyncio
import sys
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from dependencies import AppContainer, get_config_repo, get_container, get_results_repo
from repositories import ConfigRepository, ResultsRepository

router = APIRouter(prefix="/api/results", tags=["results"])

ContainerDep = Annotated[AppContainer, Depends(get_container)]
ConfigRepoDep = Annotated[ConfigRepository, Depends(get_config_repo)]
ResultsRepoDep = Annotated[ResultsRepository, Depends(get_results_repo)]


@router.get("/files")
async def get_results_files(
    config_repo: ConfigRepoDep,
    results_repo: ResultsRepoDep,
) -> dict[str, Any]:
    if not config_repo.exists():
        return {"files": [], "results_dir": "", "exists": False}

    cfg, _ = config_repo.load()
    results_dir, exists, matched_files = await asyncio.to_thread(
        results_repo.list_files, cfg.experiment
    )
    return {
        "files": matched_files,
        "experiment": cfg.experiment,
        "results_dir": str(results_dir),
        "exists": exists,
    }


@router.post("/open-finder")
async def open_in_finder(
    request_container: ContainerDep,
    config_repo: ConfigRepoDep,
    results_repo: ResultsRepoDep,
) -> dict[str, Any]:
    if sys.platform != "darwin":
        raise HTTPException(status_code=501, detail="Finder integration is only supported on macOS")
    if not config_repo.exists():
        raise HTTPException(status_code=404, detail="Config not found")

    cfg, _ = config_repo.load()
    results_dir = results_repo.results_dir_for(cfg.experiment)
    if not results_dir.exists():
        results_dir = request_container.settings.results_base_dir.resolve()

    proc = await asyncio.create_subprocess_exec(
        "open",
        str(results_dir),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=stderr.decode("utf-8", errors="replace") or "Failed to open Finder",
        )
    return {"status": "ok", "path": str(results_dir)}


@router.get("/file/{file_path:path}")
async def serve_result_file(
    file_path: str,
    config_repo: ConfigRepoDep,
    results_repo: ResultsRepoDep,
) -> FileResponse:
    if not config_repo.exists():
        raise HTTPException(status_code=404, detail="Config not found")
    cfg, _ = config_repo.load()
    target = results_repo.resolve_safe_file(cfg.experiment, file_path)
    if target is None:
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(target)
