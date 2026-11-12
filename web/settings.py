"""Workspace path and runtime settings for CUT&RUN Control Center."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path


def _default_user_config_dir() -> Path:
    override = os.environ.get("CUTANDRUN_CONFIG_DIR", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / ".config" / "cutandrun"


def _read_last_workspace(user_config_dir: Path) -> Path | None:
    registry_path = user_config_dir / "workspaces.json"
    if not registry_path.exists():
        return None
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    raw_last = payload.get("last_workspace") if isinstance(payload, dict) else None
    if not isinstance(raw_last, str) or not raw_last.strip():
        return None
    candidate = Path(raw_last).expanduser()
    if candidate.is_dir():
        return candidate.resolve()
    return None


@dataclass(frozen=True, slots=True)
class WorkspaceSettings:
    """Immutable workspace and server configuration paths."""

    pipeline_dir: Path
    workspace_dir: Path
    static_dir: Path
    port: int | None = None
    user_config_dir: Path = field(default_factory=_default_user_config_dir)

    @classmethod
    def from_env(cls) -> WorkspaceSettings:
        """Build settings from env vars, remembered workspace, or repository defaults."""
        web_dir = Path(__file__).resolve().parent
        pipeline_dir = web_dir.parent
        user_config_dir = _default_user_config_dir()

        raw_analysis_dir = os.environ.get("ANALYSIS_DIR", "").strip()
        if raw_analysis_dir:
            workspace_dir = Path(raw_analysis_dir).expanduser().resolve()
        else:
            remembered = _read_last_workspace(user_config_dir)
            workspace_dir = remembered if remembered is not None else pipeline_dir.resolve()

        raw_port = os.environ.get("PORT")
        port = int(raw_port) if raw_port and raw_port.isdigit() else None
        return cls(
            pipeline_dir=pipeline_dir,
            workspace_dir=workspace_dir,
            static_dir=web_dir / "static",
            port=port,
            user_config_dir=user_config_dir,
        )

    @property
    def config_path(self) -> Path:
        return self.workspace_dir / "config" / "experiment.config"

    @property
    def samplesheet_path(self) -> Path:
        return self.workspace_dir / "config" / "samplesheet.csv"

    @property
    def run_sh_path(self) -> Path:
        return self.workspace_dir / "run.sh"

    @property
    def weblog_config_path(self) -> Path:
        return self.workspace_dir / ".nextflow" / "weblog.config"

    @property
    def results_base_dir(self) -> Path:
        return self.workspace_dir / "results"
