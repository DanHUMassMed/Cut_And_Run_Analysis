"""FastAPI application factory for CUT&RUN Pipeline Control Center."""

from __future__ import annotations

import asyncio
import os
import signal
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from dependencies import AppContainer
from models import ServerShutdownPayload
from routes.config import router as config_router
from routes.pipeline import router as pipeline_router
from routes.results import router as results_router
from routes.samplesheet import router as samplesheet_router
from routes.workspace import router as workspace_router
from services.pipeline_runner import PipelineRunner
from settings import WorkspaceSettings


def _default_shutdown_callback() -> None:
    os.kill(os.getpid(), signal.SIGTERM)


def create_app(
    settings: WorkspaceSettings | None = None,
    runner: PipelineRunner | None = None,
    shutdown_callback: Callable[[], None] | None = None,
) -> FastAPI:
    """Create and configure the CUT&RUN Control Center FastAPI application."""
    initial_container = AppContainer.build(settings=settings, runner=runner)
    resolved_shutdown = shutdown_callback or _default_shutdown_callback

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            active_container: AppContainer = application.state.container
            active_container.broadcaster.close()
            if (
                active_container.pipeline_service.process is not None
                and active_container.pipeline_service.tracker.status == "running"
            ):
                await active_container.pipeline_service.stop()

    application = FastAPI(title="CUT&RUN Control Center", version="2.0.0", lifespan=lifespan)
    application.state.container = initial_container

    @application.middleware("http")
    async def add_security_headers(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        response.headers.setdefault("X-Frame-Options", "SAMEORIGIN")
        return response

    application.mount(
        "/static",
        StaticFiles(directory=str(initial_container.settings.static_dir)),
        name="static",
    )

    @application.get("/", include_in_schema=False)
    async def get_index(request: Request) -> FileResponse:
        active_container: AppContainer = request.app.state.container
        return FileResponse(
            active_container.settings.static_dir / "index.html",
            headers={
                "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
                "Pragma": "no-cache",
                "Expires": "0",
            },
        )

    @application.get("/api/health")
    async def health_check(request: Request) -> dict[str, Any]:
        active_container: AppContainer = request.app.state.container
        return {
            "status": "ok",
            "workspace_dir": str(active_container.settings.workspace_dir),
            "pipeline_status": active_container.pipeline_service.tracker.status,
        }

    @application.post("/api/server/shutdown")
    async def shutdown_server(
        request: Request,
        payload: ServerShutdownPayload | None = None,
    ) -> dict[str, str]:
        active_container: AppContainer = request.app.state.container
        options = payload or ServerShutdownPayload()
        is_running = (
            active_container.pipeline_service.process is not None
            and active_container.pipeline_service.tracker.status == "running"
        )
        if is_running:
            if not options.force:
                raise HTTPException(
                    status_code=409,
                    detail="Pipeline is currently running. Stop it or confirm forced shutdown.",
                )
            await active_container.pipeline_service.stop()

        active_container.broadcaster.close()
        asyncio.get_running_loop().call_later(0.15, resolved_shutdown)
        return {"status": "shutting_down"}

    application.include_router(config_router)
    application.include_router(samplesheet_router)
    application.include_router(pipeline_router)
    application.include_router(results_router)
    application.include_router(workspace_router)
    return application


app = create_app()
