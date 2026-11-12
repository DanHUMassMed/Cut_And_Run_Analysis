"""Application service container and FastAPI dependency providers."""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import Request

from repositories import (
    ConfigRepository,
    FileConfigRepository,
    FileResultsRepository,
    FileSamplesheetRepository,
    ResultsRepository,
    SamplesheetRepository,
)
from services.pipeline_runner import NextflowSubprocessRunner, PipelineRunner, PipelineService
from services.preflight import PreflightService
from services.task_tracker import LogBroadcaster, TaskTracker
from services.workspace_manager import FileWorkspaceRegistry, WorkspaceRegistry, WorkspaceService
from settings import WorkspaceSettings


@dataclass
class AppContainer:
    """Dependency container holding workspace services and repositories."""

    settings: WorkspaceSettings
    config_repo: ConfigRepository
    samplesheet_repo: SamplesheetRepository
    results_repo: ResultsRepository
    tracker: TaskTracker
    broadcaster: LogBroadcaster
    runner: PipelineRunner
    preflight_service: PreflightService
    pipeline_service: PipelineService
    workspace_service: WorkspaceService

    @classmethod
    def build(
        cls,
        settings: WorkspaceSettings | None = None,
        runner: PipelineRunner | None = None,
        workspace_registry: WorkspaceRegistry | None = None,
    ) -> AppContainer:
        resolved_settings = settings or WorkspaceSettings.from_env()
        config_repo = FileConfigRepository(resolved_settings)
        samplesheet_repo = FileSamplesheetRepository(resolved_settings)
        results_repo = FileResultsRepository(resolved_settings)
        tracker = TaskTracker()
        broadcaster = LogBroadcaster()
        resolved_runner = runner or NextflowSubprocessRunner()
        preflight_service = PreflightService(resolved_settings, config_repo)
        pipeline_service = PipelineService(
            settings=resolved_settings,
            config_repo=config_repo,
            tracker=tracker,
            broadcaster=broadcaster,
            runner=resolved_runner,
        )
        resolved_registry = workspace_registry or FileWorkspaceRegistry(
            resolved_settings.user_config_dir
        )
        workspace_service = WorkspaceService(resolved_settings, resolved_registry)
        return cls(
            settings=resolved_settings,
            config_repo=config_repo,
            samplesheet_repo=samplesheet_repo,
            results_repo=results_repo,
            tracker=tracker,
            broadcaster=broadcaster,
            runner=resolved_runner,
            preflight_service=preflight_service,
            pipeline_service=pipeline_service,
            workspace_service=workspace_service,
        )


def get_container(request: Request) -> AppContainer:
    return request.app.state.container  # type: ignore[no-any-return]


def get_config_repo(request: Request) -> ConfigRepository:
    return get_container(request).config_repo


def get_samplesheet_repo(request: Request) -> SamplesheetRepository:
    return get_container(request).samplesheet_repo


def get_results_repo(request: Request) -> ResultsRepository:
    return get_container(request).results_repo


def get_preflight_service(request: Request) -> PreflightService:
    return get_container(request).preflight_service


def get_pipeline_service(request: Request) -> PipelineService:
    return get_container(request).pipeline_service


def get_workspace_service(request: Request) -> WorkspaceService:
    return get_container(request).workspace_service

