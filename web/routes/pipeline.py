"""Pipeline execution, monitoring, webhook, and pre-flight endpoints."""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncGenerator
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse

from dependencies import get_pipeline_service, get_preflight_service
from models import PipelineStartPayload
from services.pipeline_runner import PipelineService
from services.preflight import PreflightService

router = APIRouter(tags=["pipeline"])

PreflightServiceDep = Annotated[PreflightService, Depends(get_preflight_service)]
PipelineServiceDep = Annotated[PipelineService, Depends(get_pipeline_service)]


@router.post("/api/preflight")
async def run_preflight(service: PreflightServiceDep) -> dict[str, Any]:
    return await asyncio.to_thread(service.run_checks)


@router.post("/api/pipeline/start")
async def start_pipeline(
    payload: PipelineStartPayload,
    request: Request,
    service: PipelineServiceDep,
) -> dict[str, Any]:
    try:
        return await service.start(resume=payload.resume, request_port=request.url.port)
    except RuntimeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.post("/api/pipeline/stop")
async def stop_pipeline(service: PipelineServiceDep) -> dict[str, Any]:
    try:
        return await service.stop()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@router.post("/api/pipeline/webhook")
async def receive_pipeline_webhook(
    payload: dict[str, Any],
    service: PipelineServiceDep,
) -> dict[str, str]:
    return await service.handle_webhook(payload)


@router.get("/api/pipeline/status")
async def get_pipeline_status(service: PipelineServiceDep) -> dict[str, Any]:
    return service.get_status()


@router.get("/api/pipeline/stream")
async def get_log_stream(request: Request, service: PipelineServiceDep) -> StreamingResponse:
    queue = service.broadcaster.subscribe()

    async def event_generator() -> AsyncGenerator[str, None]:
        try:
            init_payload = {
                "type": "init_state",
                "status": service.tracker.status,
                "run_name": service.tracker.run_name,
                "stats": service.tracker.stats,
                "tasks": list(service.tracker.tasks.values()),
                "start_time": service.tracker.start_time,
                "end_time": service.tracker.end_time,
            }
            yield f"data: {json.dumps(init_payload)}\n\n"

            for line in service.broadcaster.history:
                yield f"data: {json.dumps({'type': 'log', 'line': line})}\n\n"

            while not service.broadcaster.closed:
                if await request.is_disconnected():
                    break
                try:
                    msg = await asyncio.wait_for(queue.get(), timeout=5.0)
                except TimeoutError:
                    yield ": keepalive\n\n"
                    continue
                if msg is None:
                    break
                yield f"data: {json.dumps(msg)}\n\n"
        except asyncio.CancelledError:
            pass
        finally:
            service.broadcaster.unsubscribe(queue)

    return StreamingResponse(event_generator(), media_type="text/event-stream")
