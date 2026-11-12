"""Repository protocols and file-system implementations for workspace artifacts."""

from __future__ import annotations

import csv
from pathlib import Path
from typing import Any, Protocol

from config_parser import parse_experiment_config, serialize_experiment_config
from models import ContrastModel, ExperimentConfigModel
from settings import WorkspaceSettings

SAMPLESHEET_FIELDNAMES = [
    "sample_id",
    "sample_name",
    "condition",
    "target",
    "replicate",
    "control_id",
]

RESULTS_GLOBS = ("*.png", "*.svg", "*.tsv", "*.txt", "*.pdf", "*.html")


class ConfigRepository(Protocol):
    """Persistence contract for experiment configuration."""

    def exists(self) -> bool: ...
    def load(self) -> tuple[ExperimentConfigModel, str]: ...
    def save(self, model: ExperimentConfigModel) -> None: ...
    def update_contrasts(self, contrasts: list[ContrastModel]) -> ExperimentConfigModel: ...


class SamplesheetRepository(Protocol):
    """Persistence and discovery contract for samplesheet rows."""

    def load(self) -> list[dict[str, str]]: ...
    def save(self, rows: list[dict[str, Any]]) -> int: ...
    def discover_bams(self, input_dir: Path) -> list[str]: ...


class ResultsRepository(Protocol):
    """Read-only contract for pipeline output discovery and safe file access."""

    def results_dir_for(self, experiment: str) -> Path: ...
    def list_files(self, experiment: str) -> tuple[Path, bool, list[dict[str, Any]]]: ...
    def resolve_safe_file(self, experiment: str, file_path: str) -> Path | None: ...


class FileConfigRepository:
    """File-backed ConfigRepository reading/writing `experiment.config` with .bak backups."""

    def __init__(self, settings: WorkspaceSettings) -> None:
        self._settings = settings

    def exists(self) -> bool:
        return self._settings.config_path.exists()

    def load(self) -> tuple[ExperimentConfigModel, str]:
        path = self._settings.config_path
        if not path.exists():
            raise FileNotFoundError("experiment.config not found")
        raw = path.read_text(encoding="utf-8")
        return parse_experiment_config(raw), raw

    def save(self, model: ExperimentConfigModel) -> None:
        path = self._settings.config_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            bak_path = path.with_suffix(".config.bak")
            bak_path.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        path.write_text(serialize_experiment_config(model), encoding="utf-8")

    def update_contrasts(self, contrasts: list[ContrastModel]) -> ExperimentConfigModel:
        model, _ = self.load()
        updated = model.model_copy(update={"diff_contrasts": contrasts})
        self.save(updated)
        return updated


class FileSamplesheetRepository:
    """File-backed SamplesheetRepository reading/writing `samplesheet.csv` with .bak backups."""

    def __init__(self, settings: WorkspaceSettings) -> None:
        self._settings = settings

    def load(self) -> list[dict[str, str]]:
        path = self._settings.samplesheet_path
        if not path.exists():
            return []
        with open(path, encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            return [dict(row) for row in reader]

    def save(self, rows: list[dict[str, Any]]) -> int:
        path = self._settings.samplesheet_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            bak_path = path.with_suffix(".csv.bak")
            bak_path.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")

        with open(path, mode="w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=SAMPLESHEET_FIELDNAMES)
            writer.writeheader()
            for row in rows:
                cleaned = {key: row.get(key, "") for key in SAMPLESHEET_FIELDNAMES}
                writer.writerow(cleaned)
        return len(rows)

    def discover_bams(self, input_dir: Path) -> list[str]:
        bam_dir = input_dir / "06_index_bam"
        if not bam_dir.exists():
            raise FileNotFoundError(f"Path not found: {bam_dir}")
        return [p.stem for p in sorted(bam_dir.glob("*.bam"))]


class FileResultsRepository:
    """File-backed ResultsRepository with strict `is_relative_to` sandboxing."""

    def __init__(self, settings: WorkspaceSettings) -> None:
        self._settings = settings

    def results_dir_for(self, experiment: str) -> Path:
        base = self._settings.results_base_dir.resolve()
        candidate = (base / experiment).resolve()
        if not candidate.is_relative_to(base):
            raise ValueError("Invalid experiment results path")
        return candidate

    def list_files(self, experiment: str) -> tuple[Path, bool, list[dict[str, Any]]]:
        results_dir = self.results_dir_for(experiment)
        if not results_dir.exists():
            return results_dir, False, []

        matched_files: list[dict[str, Any]] = []
        seen: set[Path] = set()
        for ext in RESULTS_GLOBS:
            for file_path in results_dir.rglob(ext):
                resolved = file_path.resolve()
                if resolved in seen or not resolved.is_file() or not resolved.is_relative_to(results_dir):
                    continue
                seen.add(resolved)
                rel = file_path.relative_to(results_dir)
                matched_files.append(
                    {
                        "path": rel.as_posix(),
                        "name": file_path.name,
                        "category": rel.parts[0] if len(rel.parts) > 1 else "general",
                        "subfolder": rel.parent.as_posix() if rel.parent.as_posix() != "." else "",
                        "size": file_path.stat().st_size,
                    }
                )
        matched_files.sort(key=lambda item: str(item["path"]))
        return results_dir, True, matched_files

    def resolve_safe_file(self, experiment: str, file_path: str) -> Path | None:
        if not file_path or file_path.startswith("/"):
            return None
        results_dir = self.results_dir_for(experiment)
        target = (results_dir / file_path).resolve()
        if not target.is_relative_to(results_dir) or not target.exists() or not target.is_file():
            return None
        return target
