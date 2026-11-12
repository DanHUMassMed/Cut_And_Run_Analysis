"""Domain models and schemas for CUT&RUN Control Center."""

from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

EXPERIMENT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
EMAIL_FORMAT_RE = re.compile(r"^[^@\s\"'\\]+@[^@\s\"'\\]+\.[^@\s\"'\\]+$")
CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")
MEMORY_LIMIT_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*\.?\s*(B|KB|MB|GB|TB)\s*$", re.IGNORECASE)
TIME_LIMIT_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*\.?\s*(ms|s|m|h|d)\s*$", re.IGNORECASE)


def _reject_control_chars(value: str, field_name: str) -> str:
    if CONTROL_CHARS_RE.search(value):
        raise ValueError(f"{field_name} must not contain control characters or newlines")
    return value


def _normalize_nextflow_unit(
    value: str,
    pattern: re.Pattern[str],
    field_name: str,
    *,
    uppercase_unit: bool,
    allowed_units: str,
) -> str:
    """Validate and normalize a Nextflow numeric+unit literal (e.g., 16.GB or 72.h)."""
    cleaned = _reject_control_chars(value.strip(), field_name)
    match = pattern.fullmatch(cleaned)
    if not match:
        raise ValueError(f"{field_name} must be a positive number followed by a unit ({allowed_units})")
    amount_str, unit = match.groups()
    if float(amount_str) <= 0:
        raise ValueError(f"{field_name} must be greater than zero")
    normalized_unit = unit.upper() if uppercase_unit else unit.lower()
    return f"{amount_str}.{normalized_unit}"


class ContrastModel(BaseModel):
    """Differential peak comparison contrast definition."""

    id: str
    treatment: str
    background: str
    target: str

    @field_validator("id", "treatment", "background", "target")
    @classmethod
    def validate_no_control_chars(cls, value: str, info: Any) -> str:
        return _reject_control_chars(value.strip(), info.field_name or "contrast field")


class PathSettings(BaseModel):
    """Experiment identity and filesystem path settings."""

    email: str = ""
    experiment: str = ""
    input_dir: str = ""
    bigwig_source: Literal["deepTools", "UCSC"] = "deepTools"
    outdir: str = "${launchDir}/results/${params.experiment}"
    samplesheet: str = "${launchDir}/config/samplesheet.csv"


class StepToggles(BaseModel):
    """Boolean switches for individual Nextflow pipeline stages."""

    run_macs2_callpeak: bool = True
    run_homer_findpeaks: bool = True
    run_merge_replicate_peaks: bool = True
    run_merge_master_peaks: bool = True
    run_homer_annotatepeaks: bool = True
    run_homer_diffpeaks: bool = True
    run_deeptools_metapeak: bool = True
    run_homer_findmotifs: bool = True
    run_meme_streme: bool = True
    run_summary_plots: bool = True


class PeakMergingSettings(BaseModel):
    """Replicate/master peak merging settings."""

    active_peak_caller: Literal["macs2", "homer"] = "macs2"
    min_replicate_overlap: int = Field(default=2, ge=1, le=100)


class ReferenceSettings(BaseModel):
    """Genome reference assets."""

    genome_name: str = "ce11"
    homer_dir: str = "${projectDir}/assets/homer_ce11"
    genome_fasta: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11"
    chrom_sizes: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11/chrom.sizes"


class Macs2Settings(BaseModel):
    """MACS2 peak calling parameters."""

    macs2_gsize: str = "ce"
    macs2_format: Literal["BAMPE", "BAM", "BED"] = "BAMPE"
    macs2_qvalue: float = Field(default=0.01, gt=0.0, le=1.0)
    macs2_broad: bool = False
    macs2_broad_cutoff: float = Field(default=0.1, gt=0.0, le=1.0)


class HomerSettings(BaseModel):
    """HOMER findPeaks and annotatePeaks parameters."""

    homer_peak_style: Literal["factor", "histone"] = "factor"
    annotatepeaks_size: str = "given"


class MetapeakSettings(BaseModel):
    """deepTools computeMatrix & plotHeatmap parameters."""

    metapeak_upstream: int = Field(default=2000, ge=0)
    metapeak_downstream: int = Field(default=2000, ge=0)
    metapeak_reference_point: str = "center"
    heatmap_colormap: str = "inferno"
    heatmap_interpolation: str = "nearest"


class MotifSettings(BaseModel):
    """Motif discovery (HOMER & MEME STREME) parameters."""

    homer_motif_size: str = "100"
    meme_slop_left: int = Field(default=50, ge=0)
    meme_slop_right: int = Field(default=49, ge=0)
    meme_streme_nmotifs: int = Field(default=20, ge=1, le=200)


class SummaryPlotSettings(BaseModel):
    """Volcano plot and automated QC cutoff settings."""

    volcano_fdr_threshold: float = Field(default=0.05, gt=0.0, le=1.0)
    volcano_log2fc_threshold: float = Field(default=1.0, ge=0.0)
    volcano_top_n_labels: int = Field(default=12, ge=0, le=500)


class _ResourceLimitsFields(BaseModel):
    """Shared Nextflow process.resourceLimits fields and validation."""

    resource_cpus: int = Field(default=8, ge=1, le=1024)
    resource_memory: str = "16.GB"
    resource_time: str = "72.h"

    @field_validator("resource_memory")
    @classmethod
    def validate_resource_memory(cls, value: str) -> str:
        return _normalize_nextflow_unit(
            value,
            MEMORY_LIMIT_RE,
            "resource_memory",
            uppercase_unit=True,
            allowed_units="B, KB, MB, GB, TB",
        )

    @field_validator("resource_time")
    @classmethod
    def validate_resource_time(cls, value: str) -> str:
        return _normalize_nextflow_unit(
            value,
            TIME_LIMIT_RE,
            "resource_time",
            uppercase_unit=False,
            allowed_units="ms, s, m, h, d",
        )


class ResourceLimitsSettings(_ResourceLimitsFields):
    """Nextflow process.resourceLimits upper bounds."""


class ConfigSections(BaseModel):
    """Segregated configuration view grouped by pipeline concern."""

    paths: PathSettings
    toggles: StepToggles
    merging: PeakMergingSettings
    resources: ResourceLimitsSettings
    reference: ReferenceSettings
    macs2: Macs2Settings
    homer: HomerSettings
    metapeak: MetapeakSettings
    motifs: MotifSettings
    summary_plots: SummaryPlotSettings
    diff_contrasts: list[ContrastModel] = Field(default_factory=list)


class ContrastsUpdatePayload(BaseModel):
    """Targeted payload for updating differential contrasts without resending all config fields."""

    diff_contrasts: list[ContrastModel] = Field(default_factory=list)


class ExperimentConfigModel(_ResourceLimitsFields):
    """Complete experiment.config parameter model (flat API contract with validated constraints)."""

    # Experiment & Paths
    email: str = ""
    experiment: str = ""
    input_dir: str = ""
    bigwig_source: Literal["deepTools", "UCSC"] = "deepTools"
    outdir: str = "${launchDir}/results/${params.experiment}"
    samplesheet: str = "${launchDir}/config/samplesheet.csv"

    # Step Toggles
    run_macs2_callpeak: bool = True
    run_homer_findpeaks: bool = True
    run_merge_replicate_peaks: bool = True
    run_merge_master_peaks: bool = True
    run_homer_annotatepeaks: bool = True
    run_homer_diffpeaks: bool = True
    run_deeptools_metapeak: bool = True
    run_homer_findmotifs: bool = True
    run_meme_streme: bool = True
    run_summary_plots: bool = True

    # Peak Merging Settings
    active_peak_caller: Literal["macs2", "homer"] = "macs2"
    min_replicate_overlap: int = Field(default=2, ge=1, le=100)

    # Tool Parameters
    genome_name: str = "ce11"
    homer_dir: str = "${projectDir}/assets/homer_ce11"
    genome_fasta: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11"
    chrom_sizes: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11/chrom.sizes"

    macs2_gsize: str = "ce"
    macs2_format: Literal["BAMPE", "BAM", "BED"] = "BAMPE"
    macs2_qvalue: float = Field(default=0.01, gt=0.0, le=1.0)
    macs2_broad: bool = False
    macs2_broad_cutoff: float = Field(default=0.1, gt=0.0, le=1.0)

    homer_peak_style: Literal["factor", "histone"] = "factor"
    annotatepeaks_size: str = "given"

    diff_contrasts: list[ContrastModel] = Field(default_factory=list)

    metapeak_upstream: int = Field(default=2000, ge=0)
    metapeak_downstream: int = Field(default=2000, ge=0)
    metapeak_reference_point: str = "center"
    heatmap_colormap: str = "inferno"
    heatmap_interpolation: str = "nearest"

    homer_motif_size: str = "100"
    meme_slop_left: int = Field(default=50, ge=0)
    meme_slop_right: int = Field(default=49, ge=0)
    meme_streme_nmotifs: int = Field(default=20, ge=1, le=200)

    volcano_fdr_threshold: float = Field(default=0.05, gt=0.0, le=1.0)
    volcano_log2fc_threshold: float = Field(default=1.0, ge=0.0)
    volcano_top_n_labels: int = Field(default=12, ge=0, le=500)

    @field_validator("experiment")
    @classmethod
    def validate_experiment_name(cls, value: str) -> str:
        cleaned = value.strip()
        if not EXPERIMENT_NAME_RE.match(cleaned):
            raise ValueError(
                "experiment must start with an alphanumeric character and contain only letters, "
                "digits, '.', '_', or '-'"
            )
        return cleaned

    @field_validator("email")
    @classmethod
    def validate_email_format(cls, value: str) -> str:
        cleaned = value.strip()
        _reject_control_chars(cleaned, "email")
        if cleaned and not EMAIL_FORMAT_RE.match(cleaned):
            raise ValueError("email must be a valid email address")
        return cleaned

    @field_validator(
        "input_dir",
        "outdir",
        "samplesheet",
        "genome_name",
        "homer_dir",
        "genome_fasta",
        "chrom_sizes",
        "macs2_gsize",
        "annotatepeaks_size",
        "metapeak_reference_point",
        "heatmap_colormap",
        "heatmap_interpolation",
        "homer_motif_size",
    )
    @classmethod
    def validate_safe_strings(cls, value: str, info: Any) -> str:
        return _reject_control_chars(value.strip(), info.field_name or "string field")

    def to_sections(self) -> ConfigSections:
        """Project flat configuration into segregated sub-models."""
        data = self.model_dump()
        return ConfigSections(
            paths=PathSettings(**data),
            toggles=StepToggles(**data),
            merging=PeakMergingSettings(**data),
            resources=ResourceLimitsSettings(**data),
            reference=ReferenceSettings(**data),
            macs2=Macs2Settings(**data),
            homer=HomerSettings(**data),
            metapeak=MetapeakSettings(**data),
            motifs=MotifSettings(**data),
            summary_plots=SummaryPlotSettings(**data),
            diff_contrasts=self.diff_contrasts,
        )


class SamplesheetPayload(BaseModel):
    """Samplesheet CSV update payload."""

    rows: list[dict[str, Any]]


class PipelineStartPayload(BaseModel):
    """Pipeline launch parameters."""

    resume: bool = True


class ServerShutdownPayload(BaseModel):
    """Server shutdown request options."""

    force: bool = False


class WorkspaceSelectPayload(BaseModel):
    """Payload for switching or initializing an Analysis_Run workspace directory."""

    path: str
    initialize: bool = False
    experiment_name: str | None = None

    @field_validator("path")
    @classmethod
    def validate_path_nonempty(cls, value: str) -> str:
        cleaned = _reject_control_chars(value.strip(), "path")
        if not cleaned:
            raise ValueError("Workspace path must not be empty")
        return cleaned

    @field_validator("experiment_name")
    @classmethod
    def validate_optional_experiment_name(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = _reject_control_chars(value.strip(), "experiment_name")
        if not cleaned:
            return None
        if not EXPERIMENT_NAME_RE.fullmatch(cleaned):
            raise ValueError(
                "experiment_name must start with alphanumeric and contain only letters, digits, '.', '_', '-'"
            )
        return cleaned


class TaskRecord(BaseModel):
    """Normalized Nextflow task execution record across all event sources."""

    task_id: str
    key: str
    name: str
    process: str
    process_short: str
    tag: str = ""
    hash: str = ""
    status: str = "SUBMITTED"
    exit: int | None = None
    duration: str = ""
    realtime: int | float | None = None
    realtime_fmt: str = ""
    cpu_percent: float = 0.0
    peak_rss: str | int = ""
    workdir: str = ""


class PipelineStats(BaseModel):
    """Aggregated Nextflow execution counts and progress percentage."""

    total: int = 0
    submitted: int = 0
    running: int = 0
    completed: int = 0
    cached: int = 0
    failed: int = 0
    percent: float = 0.0
    run_name: str | None = None


class PreflightCheckResult(BaseModel):
    """Outcome of a single pre-flight environment check."""

    name: str
    status: Literal["ok", "warning", "failed"]
    detail: str

