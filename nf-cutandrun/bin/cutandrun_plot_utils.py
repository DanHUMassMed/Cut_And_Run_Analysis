#!/usr/bin/env python3
"""Shared domain models, parsers, and publication-grade matplotlib helpers for CUT&RUN QC plots."""

from __future__ import annotations

import csv
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

import matplotlib
import matplotlib.pyplot as plt
import numpy as np

# Use non-interactive Agg backend for headless container execution
matplotlib.use("Agg")

# Colorblind-safe Okabe-Ito inspired palette
PALETTE_HEX: list[str] = [
    "#0072B2",  # Blue
    "#D55E00",  # Vermilion / Orange-Red
    "#009E73",  # Bluish Green
    "#CC79A7",  # Reddish Purple
    "#E69F00",  # Orange / Gold
    "#56B4E9",  # Sky Blue
    "#F0E442",  # Yellow
    "#332288",  # Indigo
]

FEATURE_ORDER: list[str] = [
    "Promoter-TSS",
    "5' UTR",
    "Exon",
    "Intron",
    "3' UTR",
    "TTS",
    "Non-coding",
    "Intergenic",
    "Other / Unannotated",
]

FEATURE_COLORS: dict[str, str] = {
    "Promoter-TSS": "#0072B2",
    "5' UTR": "#56B4E9",
    "Exon": "#009E73",
    "Intron": "#E69F00",
    "3' UTR": "#F0E442",
    "TTS": "#CC79A7",
    "Non-coding": "#882255",
    "Intergenic": "#D55E00",
    "Other / Unannotated": "#999999",
}


@dataclass(frozen=True)
class SampleMetadata:
    """Metadata record parsed from samplesheet.csv."""

    sample_id: str
    sample_name: str
    condition: str
    target: str
    replicate: int
    control_id: str | None = None


@dataclass
class HomerAnnotatedPeakRow:
    """Single row from HOMER annotatePeaks.pl output."""

    peak_id: str
    chrom: str
    start: int
    end: int
    strand: str
    annotation_raw: str
    annotation_category: str
    distance_to_tss: int | None
    gene_name: str
    gene_description: str
    gene_type: str
    tag_counts: list[float] = field(default_factory=list)

    @property
    def width_bp(self) -> int:
        return max(abs(self.end - self.start), 1)

    @property
    def width_kb(self) -> float:
        return self.width_bp / 1000.0


@dataclass
class HomerAnnotatedTable:
    """Parsed representation of a HOMER annotatePeaks.pl table."""

    target: str
    sample_ids: list[str]
    sample_names: list[str]
    sample_conditions: list[str]
    rows: list[HomerAnnotatedPeakRow]

    @property
    def num_peaks(self) -> int:
        return len(self.rows)

    @property
    def num_samples(self) -> int:
        return len(self.sample_ids)

    def tag_matrix(self) -> np.ndarray:
        """Return (N_peaks, N_samples) matrix of normalized tag counts."""
        if not self.rows or not self.sample_ids:
            return np.zeros((0, len(self.sample_ids)), dtype=np.float64)
        return np.array([row.tag_counts for row in self.rows], dtype=np.float64)

    def tags_per_kb_matrix(self) -> np.ndarray:
        """Return (N_peaks, N_samples) matrix of length-normalized tags per kb."""
        mat = self.tag_matrix()
        if mat.size == 0:
            return mat
        widths_kb = np.array([row.width_kb for row in self.rows], dtype=np.float64)[:, np.newaxis]
        return mat / widths_kb

    def widths_bp(self) -> np.ndarray:
        """Return 1D array of peak widths in base pairs."""
        return np.array([row.width_bp for row in self.rows], dtype=np.int64)


@dataclass
class DifferentialPeakRow:
    """Single row from HOMER getDifferentialPeaksReplicates.pl -all output."""

    peak_id: str
    chrom: str
    start: int
    end: int
    annotation_category: str
    distance_to_tss: int | None
    gene_name: str
    gene_description: str
    bg_tag_count: float
    treat_tag_count: float
    log2_fc: float
    p_value: float
    fdr: float

    @property
    def mean_log2_signal(self) -> float:
        """Return A = 0.5 * (log2(treat + 1) + log2(bg + 1)) for MA plotting."""
        return 0.5 * (math.log2(max(self.treat_tag_count, 0.0) + 1.0) + math.log2(max(self.bg_tag_count, 0.0) + 1.0))

    @property
    def display_label(self) -> str:
        """Return clean gene name or fallback coordinate/PeakID for plot callouts."""
        cleaned = self.gene_name.strip()
        if cleaned and cleaned not in {"-", "NA", ""}:
            return cleaned
        return f"{self.chrom}:{self.start}"


def configure_matplotlib_style() -> None:
    """Configure publication-quality matplotlib defaults."""
    plt.rcParams.update(
        {
            "font.family": "sans-serif",
            "font.sans-serif": ["DejaVu Sans", "Arial", "Helvetica"],
            "font.size": 10,
            "axes.titlesize": 12,
            "axes.titleweight": "bold",
            "axes.labelsize": 10,
            "axes.labelweight": "bold",
            "axes.edgecolor": "#333333",
            "axes.linewidth": 0.9,
            "xtick.labelsize": 9,
            "ytick.labelsize": 9,
            "legend.fontsize": 9,
            "figure.titlesize": 14,
            "figure.titleweight": "bold",
            "svg.fonttype": "none",
            "savefig.bbox": "tight",
            "savefig.pad_inches": 0.15,
        }
    )


def despine_axis(ax: plt.Axes, top: bool = True, right: bool = True) -> None:
    """Remove top and right spines for a clean modern appearance."""
    if top:
        ax.spines["top"].set_visible(False)
    if right:
        ax.spines["right"].set_visible(False)


def save_dual_figure(fig: plt.Figure, out_base: Path, dpi: int = 300) -> tuple[Path, Path]:
    """Save figure as both editable vector SVG and high-resolution PNG."""
    out_base.parent.mkdir(parents=True, exist_ok=True)
    svg_path = out_base.with_suffix(".svg")
    png_path = out_base.with_suffix(".png")
    fig.savefig(svg_path, format="svg")
    fig.savefig(png_path, format="png", dpi=dpi)
    plt.close(fig)
    return svg_path, png_path


def load_samplesheet(samplesheet_path: Path | None) -> dict[str, SampleMetadata]:
    """Parse samplesheet.csv into a dictionary keyed by sample_id."""
    if samplesheet_path is None or not samplesheet_path.exists():
        return {}
    records: dict[str, SampleMetadata] = {}
    with samplesheet_path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            sample_id = (row.get("sample_id") or "").strip()
            if not sample_id:
                continue
            sample_name = (row.get("sample_name") or sample_id).strip()
            condition = (row.get("condition") or sample_name).strip()
            target = (row.get("target") or "default").strip()
            rep_str = (row.get("replicate") or "1").strip()
            try:
                replicate = int(rep_str)
            except ValueError:
                replicate = 1
            control_id = (row.get("control_id") or "").strip() or None
            records[sample_id] = SampleMetadata(
                sample_id=sample_id,
                sample_name=sample_name,
                condition=condition,
                target=target,
                replicate=replicate,
                control_id=control_id,
            )
    return records


def normalize_homer_annotation(raw_annotation: str) -> str:
    """Normalize raw HOMER Annotation strings into canonical genomic categories."""
    cleaned = raw_annotation.strip()
    if not cleaned or cleaned == "NA":
        return "Other / Unannotated"
    prefix = cleaned.split(" (")[0].split(".")[0].strip()
    lower = prefix.lower()
    if lower.startswith("promoter-tss") or lower.startswith("promoter"):
        return "Promoter-TSS"
    if lower.startswith("5' utr") or lower.startswith("5'-utr"):
        return "5' UTR"
    if lower.startswith("3' utr") or lower.startswith("3'-utr"):
        return "3' UTR"
    if lower.startswith("exon") or lower.startswith("coding"):
        return "Exon"
    if lower.startswith("intron"):
        return "Intron"
    if lower.startswith("tts"):
        return "TTS"
    if lower.startswith("non-coding") or lower.startswith("ncrna"):
        return "Non-coding"
    if lower.startswith("intergenic"):
        return "Intergenic"
    return "Other / Unannotated"


def extract_sample_id_from_tag_header(column_header: str) -> str:
    """Extract sample_id from a HOMER Tag Count column header."""
    # Example header:
    # "L9254-0001-0001_S141_L004 Tag Count in given bp (21443251.0 Total, ...)"
    # or "/path/to/L9254-0001-0001_S141_L004 Tag Count..."
    token = column_header.split(" Tag Count")[0].strip()
    token = Path(token).name
    if token.endswith("_tagdir"):
        token = token[: -len("_tagdir")]
    return token


def parse_homer_annotated_table(
    table_path: Path,
    samplesheet_map: dict[str, SampleMetadata],
    target_override: str | None = None,
) -> HomerAnnotatedTable:
    """Parse a HOMER annotatePeaks.pl output table into a structured HomerAnnotatedTable."""
    standard_col_count = 19
    target_name = target_override or re.sub(r"_annotated_peaks\.txt$", "", table_path.name)

    with table_path.open("r", encoding="utf-8") as handle:
        header_line = ""
        for line in handle:
            if line.startswith("#") and not line.startswith("#PeakID"):
                continue
            header_line = line.rstrip("\r\n")
            break

        if not header_line:
            return HomerAnnotatedTable(
                target=target_name,
                sample_ids=[],
                sample_names=[],
                sample_conditions=[],
                rows=[],
            )

        headers = header_line.split("\t")
        # Exclude any appended *_per_kb columns if present
        tag_col_indices: list[int] = []
        sample_ids: list[str] = []
        sample_names: list[str] = []
        sample_conditions: list[str] = []

        for idx in range(standard_col_count, len(headers)):
            col_name = headers[idx]
            if col_name.endswith("_per_kb"):
                continue
            sid = extract_sample_id_from_tag_header(col_name)
            tag_col_indices.append(idx)
            sample_ids.append(sid)
            if sid in samplesheet_map:
                meta = samplesheet_map[sid]
                sample_names.append(meta.sample_name)
                sample_conditions.append(meta.condition)
            else:
                sample_names.append(sid)
                sample_conditions.append(sid)

        rows: list[HomerAnnotatedPeakRow] = []
        for line in handle:
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.rstrip("\r\n").split("\t")
            if len(fields) < standard_col_count:
                continue
            try:
                start = int(fields[2])
                end = int(fields[3])
            except ValueError:
                continue

            dist_tss: int | None = None
            try:
                dist_tss = int(float(fields[9]))
            except (ValueError, IndexError):
                dist_tss = None

            raw_ann = fields[7] if len(fields) > 7 else "NA"
            ann_cat = normalize_homer_annotation(raw_ann)
            gene_name = fields[15].strip() if len(fields) > 15 else ""
            gene_desc = fields[17].strip() if len(fields) > 17 else ""
            gene_type = fields[18].strip() if len(fields) > 18 else ""

            tag_vals: list[float] = []
            for col_idx in tag_col_indices:
                if col_idx < len(fields):
                    try:
                        tag_vals.append(float(fields[col_idx]))
                    except ValueError:
                        tag_vals.append(0.0)
                else:
                    tag_vals.append(0.0)

            rows.append(
                HomerAnnotatedPeakRow(
                    peak_id=fields[0],
                    chrom=fields[1],
                    start=start,
                    end=end,
                    strand=fields[4],
                    annotation_raw=raw_ann,
                    annotation_category=ann_cat,
                    distance_to_tss=dist_tss,
                    gene_name=gene_name,
                    gene_description=gene_desc,
                    gene_type=gene_type,
                    tag_counts=tag_vals,
                )
            )

    return HomerAnnotatedTable(
        target=target_name,
        sample_ids=sample_ids,
        sample_names=sample_names,
        sample_conditions=sample_conditions,
        rows=rows,
    )


def parse_homer_differential_table(diff_path: Path) -> list[DifferentialPeakRow]:
    """Parse HOMER getDifferentialPeaksReplicates.pl -all output table."""
    rows: list[DifferentialPeakRow] = []
    with diff_path.open("r", encoding="utf-8") as handle:
        header_fields: list[str] = []
        for line in handle:
            stripped = line.rstrip("\r\n")
            if not stripped:
                continue
            if stripped.startswith("#cmd=") or stripped.startswith("PeakID"):
                header_fields = stripped.split("\t")
                break
            if stripped.startswith("#"):
                continue
            header_fields = stripped.split("\t")
            break

        if not header_fields:
            return rows

        for line in handle:
            stripped = line.rstrip("\r\n")
            if not stripped or stripped.startswith("#"):
                continue
            fields = stripped.split("\t")
            if len(fields) < 22:
                continue
            try:
                start = int(fields[2])
                end = int(fields[3])
            except ValueError:
                continue

            dist_tss: int | None = None
            try:
                dist_tss = int(float(fields[9]))
            except ValueError:
                dist_tss = None

            raw_ann = fields[7]
            ann_cat = normalize_homer_annotation(raw_ann)
            gene_name = fields[15].strip() if len(fields) > 15 else ""
            gene_desc = fields[17].strip() if len(fields) > 17 else ""

            # Last 3 columns are always Log2 Fold Change, p-value, adj. p-value
            # Preceding columns (index 19 .. len-4) are background and treatment tag counts
            try:
                log2_fc = float(fields[-3])
                p_val = float(fields[-2])
                fdr_val = float(fields[-1])
            except ValueError:
                continue

            tag_cols = fields[19:-3]
            bg_val = 0.0
            treat_val = 0.0
            if len(tag_cols) >= 2:
                half = len(tag_cols) // 2
                try:
                    bg_vals = [float(x) for x in tag_cols[:half]]
                    treat_vals = [float(x) for x in tag_cols[half:]]
                    bg_val = sum(bg_vals) / max(len(bg_vals), 1)
                    treat_val = sum(treat_vals) / max(len(treat_vals), 1)
                except ValueError:
                    bg_val, treat_val = 0.0, 0.0

            rows.append(
                DifferentialPeakRow(
                    peak_id=fields[0],
                    chrom=fields[1],
                    start=start,
                    end=end,
                    annotation_category=ann_cat,
                    distance_to_tss=dist_tss,
                    gene_name=gene_name,
                    gene_description=gene_desc,
                    bg_tag_count=bg_val,
                    treat_tag_count=treat_val,
                    log2_fc=log2_fc,
                    p_value=max(p_val, 1e-300),
                    fdr=max(fdr_val, 1e-300),
                )
            )
    return rows


def count_bed_intervals(bed_path: Path) -> int:
    """Count non-empty, non-comment, non-header lines in a BED/narrowPeak/broadPeak file."""
    if not bed_path.exists():
        return 0
    count = 0
    with bed_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("track") or stripped.startswith("browser"):
                continue
            count += 1
    return count


def build_condition_color_map(conditions: Sequence[str]) -> dict[str, str]:
    """Assign deterministic colorblind-safe hex colors to unique conditions."""
    unique_conds: list[str] = []
    for cond in conditions:
        if cond not in unique_conds:
            unique_conds.append(cond)
    return {cond: PALETTE_HEX[i % len(PALETTE_HEX)] for i, cond in enumerate(unique_conds)}

