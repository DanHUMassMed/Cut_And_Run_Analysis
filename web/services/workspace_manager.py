"""Workspace discovery, initialization, recent history, and runtime switching."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import TYPE_CHECKING, Any, Protocol

from config_parser import serialize_experiment_config
from models import ExperimentConfigModel
from repositories import SAMPLESHEET_FIELDNAMES
from settings import WorkspaceSettings

if TYPE_CHECKING:
    from fastapi import FastAPI

    from dependencies import AppContainer

MAX_RECENT_WORKSPACES = 10
SAFE_EXP_SANITIZE_RE = re.compile(r"[^A-Za-z0-9._-]+")

STARTER_RUN_SH = """#!/usr/bin/env bash
set -euo pipefail

RESUME="-resume"
if [ "${1:-}" = "false" ] || [ "${1:-}" = "--no-resume" ]; then
    RESUME=""
    shift
elif [ "${1:-}" = "true" ] || [ "${1:-}" = "--resume" ]; then
    RESUME="-resume"
    shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

resolve_pipeline_dir() {
    if [ -n "${PIPELINE_DIR:-}" ] && [ -f "${PIPELINE_DIR}/main.nf" ]; then
        echo "${PIPELINE_DIR}"
        return 0
    fi
    if [ -f "${SCRIPT_DIR}/../../Cut_And_Run_Analysis/main.nf" ]; then
        (cd "${SCRIPT_DIR}/../../Cut_And_Run_Analysis" && pwd -P)
        return 0
    fi
    if [ -f "${HOME}/.config/cutandrun/env" ]; then
        # shellcheck disable=SC1090
        source "${HOME}/.config/cutandrun/env"
        if [ -n "${PIPELINE_DIR:-}" ] && [ -f "${PIPELINE_DIR}/main.nf" ]; then
            echo "${PIPELINE_DIR}"
            return 0
        fi
    fi
    echo "Error: Could not locate Cut_And_Run_Analysis pipeline directory. Set PIPELINE_DIR." >&2
    return 1
}

PIPELINE_PATH="$(resolve_pipeline_dir)"
email="$(sed -nE "s/^[[:space:]]*email[[:space:]]*=[[:space:]]*[\\"']([^\\"']+)[\\"'].*/\\1/p" config/experiment.config | head -n 1)"
nextflow -c config/experiment.config run "${PIPELINE_PATH}" -profile docker,arm64 ${RESUME} -N "${email}" "$@"
"""


class WorkspaceRegistry(Protocol):
    """Persistence contract for remembered recent experiment directories."""

    def load_recent(self) -> list[str]: ...
    def record(self, workspace_dir: Path) -> None: ...


class FileWorkspaceRegistry:
    """JSON-backed recent workspace store in user_config_dir/workspaces.json."""

    def __init__(self, user_config_dir: Path) -> None:
        self._registry_path = user_config_dir / "workspaces.json"

    def _read_payload(self) -> dict[str, Any]:
        if not self._registry_path.exists():
            return {}
        try:
            data = json.loads(self._registry_path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (OSError, json.JSONDecodeError):
            return {}

    def load_recent(self) -> list[str]:
        data = self._read_payload()
        raw_recent = data.get("recent_workspaces", [])
        if not isinstance(raw_recent, list):
            return []
        return [str(p) for p in raw_recent if isinstance(p, str) and p.strip()]

    def record(self, workspace_dir: Path) -> None:
        resolved = str(workspace_dir.resolve())
        recent = [p for p in self.load_recent() if p != resolved]
        updated = [resolved, *recent][:MAX_RECENT_WORKSPACES]
        self._registry_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "last_workspace": resolved,
            "recent_workspaces": updated,
        }
        tmp_path = self._registry_path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp_path, self._registry_path)


def _derive_experiment_name(target_dir: Path) -> str:
    candidate = target_dir.parent.name if target_dir.name == "Analysis_Run" and target_dir.parent.name else target_dir.name
    sanitized = SAFE_EXP_SANITIZE_RE.sub("_", candidate).strip("._-")
    if not sanitized or not sanitized[0].isalnum():
        return f"exp_{sanitized or 'cutandrun'}"
    return sanitized[:128]


class WorkspaceService:
    """Inspects, initializes, and switches active Analysis_Run workspaces."""

    def __init__(self, settings: WorkspaceSettings, registry: WorkspaceRegistry) -> None:
        self._settings = settings
        self._registry = registry

    @staticmethod
    def inspect_workspace(workspace_dir: Path) -> dict[str, Any]:
        exists = workspace_dir.is_dir()
        label = (
            f"{workspace_dir.parent.name}/{workspace_dir.name}"
            if workspace_dir.parent.name
            else workspace_dir.name
        )
        return {
            "path": str(workspace_dir),
            "label": label,
            "exists": exists,
            "has_config": (workspace_dir / "config" / "experiment.config").is_file() if exists else False,
            "has_samplesheet": (workspace_dir / "config" / "samplesheet.csv").is_file() if exists else False,
            "has_run_sh": (workspace_dir / "run.sh").is_file() if exists else False,
        }

    def get_state(self) -> dict[str, Any]:
        current_info = self.inspect_workspace(self._settings.workspace_dir)
        recent_paths = self._registry.load_recent()
        if str(self._settings.workspace_dir) not in recent_paths and current_info["has_config"]:
            self._registry.record(self._settings.workspace_dir)
            recent_paths = self._registry.load_recent()

        recent = [
            self.inspect_workspace(Path(p))
            for p in recent_paths
            if Path(p).is_dir()
        ]
        return {
            "current": current_info,
            "pipeline_dir": str(self._settings.pipeline_dir),
            "recent": recent,
        }

    def list_directories(self, raw_path: str | None = None) -> dict[str, Any]:
        """List non-hidden subdirectories of the target path for in-UI folder browsing."""
        if raw_path and raw_path.strip():
            target = Path(raw_path.strip()).expanduser().resolve()
        elif self._settings.workspace_dir != self._settings.pipeline_dir:
            target = self._settings.workspace_dir.parent.resolve()
        else:
            target = self._settings.pipeline_dir.parent.resolve()

        if not target.exists():
            raise FileNotFoundError(f"Directory does not exist: {target}")
        if not target.is_dir():
            raise ValueError(f"Path is not a directory: {target}")

        directories: list[dict[str, Any]] = []
        permission_error: str | None = None
        try:
            entries = sorted(
                (p for p in target.iterdir() if p.is_dir() and not p.name.startswith(".")),
                key=lambda p: p.name.lower(),
            )
            for entry in entries:
                try:
                    has_config = (entry / "config" / "experiment.config").is_file()
                    has_run_sh = (entry / "run.sh").is_file()
                except OSError:
                    has_config = False
                    has_run_sh = False
                directories.append(
                    {
                        "name": entry.name,
                        "path": str(entry),
                        "has_config": has_config,
                        "has_run_sh": has_run_sh,
                    }
                )
        except PermissionError:
            permission_error = f"Permission denied reading contents of {target}"

        parent_path = str(target.parent) if target.parent != target else None
        return {
            "current": str(target),
            "parent": parent_path,
            "home": str(Path.home().resolve()),
            "pipeline_parent": str(self._settings.pipeline_dir.parent.resolve()),
            "directories": directories,
            "error": permission_error,
        }

    def initialize_workspace(
        self,
        target_dir: Path,
        experiment_name: str | None = None,
    ) -> None:
        target_dir.mkdir(parents=True, exist_ok=True)
        config_dir = target_dir / "config"
        config_dir.mkdir(parents=True, exist_ok=True)

        config_path = config_dir / "experiment.config"
        if not config_path.exists():
            exp_name = experiment_name or _derive_experiment_name(target_dir)
            starter_model = ExperimentConfigModel(
                email="user@example.org",
                experiment=exp_name,
                input_dir="",
            )
            config_path.write_text(serialize_experiment_config(starter_model), encoding="utf-8")

        samplesheet_path = config_dir / "samplesheet.csv"
        if not samplesheet_path.exists():
            samplesheet_path.write_text(",".join(SAMPLESHEET_FIELDNAMES) + "\n", encoding="utf-8")

        run_sh_path = target_dir / "run.sh"
        if not run_sh_path.exists():
            run_sh_path.write_text(STARTER_RUN_SH, encoding="utf-8")
            run_sh_path.chmod(0o755)

    def switch_workspace(
        self,
        application: FastAPI,
        raw_path: str,
        *,
        initialize: bool = False,
        experiment_name: str | None = None,
    ) -> dict[str, Any]:
        from dependencies import AppContainer
        from services.pipeline_runner import NextflowSubprocessRunner

        current: AppContainer = application.state.container
        if (
            current.pipeline_service.process is not None
            and current.pipeline_service.tracker.status == "running"
        ):
            raise RuntimeError("Cannot switch workspace while a pipeline run is active")

        resolved = Path(raw_path).expanduser().resolve()
        if resolved.exists() and not resolved.is_dir():
            raise ValueError(f"Path is not a directory: {resolved}")
        if not resolved.exists():
            if not initialize:
                raise FileNotFoundError(f"Directory does not exist: {resolved}")

        if initialize:
            if resolved == current.settings.pipeline_dir.resolve():
                raise ValueError(
                    "Cannot initialize an experiment inside the pipeline repository; choose a separate Analysis_Run folder."
                )
            self.initialize_workspace(resolved, experiment_name=experiment_name)
        elif not resolved.is_dir():
            raise FileNotFoundError(f"Directory does not exist: {resolved}")

        new_settings = WorkspaceSettings(
            pipeline_dir=current.settings.pipeline_dir,
            workspace_dir=resolved,
            static_dir=current.settings.static_dir,
            port=current.settings.port,
            user_config_dir=current.settings.user_config_dir,
        )
        preserved_runner = (
            None if isinstance(current.runner, NextflowSubprocessRunner) else current.runner
        )
        new_container = AppContainer.build(
            settings=new_settings,
            runner=preserved_runner,
            workspace_registry=self._registry,
        )
        self._registry.record(resolved)
        application.state.container = new_container
        return new_container.workspace_service.get_state()
