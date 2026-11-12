"""Workspace selection, initialization, and directory browsing endpoints."""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request

from dependencies import get_workspace_service
from models import WorkspaceSelectPayload
from services.workspace_manager import WorkspaceService

router = APIRouter(prefix="/api/workspace", tags=["workspace"])

WorkspaceServiceDep = Annotated[WorkspaceService, Depends(get_workspace_service)]


@router.get("")
async def get_workspace_state(service: WorkspaceServiceDep) -> dict[str, Any]:
    return service.get_state()


@router.post("/select")
async def select_workspace(
    payload: WorkspaceSelectPayload,
    request: Request,
    service: WorkspaceServiceDep,
) -> dict[str, Any]:
    try:
        return service.switch_workspace(
            request.app,
            payload.path,
            initialize=payload.initialize,
            experiment_name=payload.experiment_name,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/list-dirs")
async def list_workspace_directories(
    service: WorkspaceServiceDep,
    path: str | None = Query(default=None),
) -> dict[str, Any]:
    try:
        return service.list_directories(path)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
