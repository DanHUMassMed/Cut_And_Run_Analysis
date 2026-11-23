#!/usr/bin/env python3
"""Compute FRiP (Fraction of Reads in Peaks) and aggregate upstream read-retention & depth QC.

Produces:
- frip_summary.tsv
- read_retention_depth_summary.tsv
- frip_comparison.{svg,png}
- read_retention_funnel.{svg,png}
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import matplotlib.pyplot as plt
import numpy as np

from cutandrun_plot_utils import (
    IGG_COLOR_HEX,
    PALETTE_HEX,
    SampleMetadata,
    build_condition_color_map,
    configure_matplotlib_style,
    despine_axis,
    is_igg_label,
    load_samplesheet,
    save_dual_figure,
)

try:
    import pysam
except ImportError:  # pragma: no cover - pysam is bundled in deeptools container
    pysam = None  # type: ignore[assignment]


# =============================================================================
# Domain Models
# =============================================================================
@dataclass
class SampleDepthMetrics:
    """Aggregated read-retention, duplication, and sequencing depth metrics for one sample."""

    meta: SampleMetadata
    raw_pairs: int | None = None
    trimmed_pairs: int | None = None
    trim_retention_pct: float | None = None
    bowtie2_overall_align_pct: float | None = None
    picard_pairs_examined: int | None = None
    picard_unmapped_reads: int | None = None
    approx_align_pct: float | None = None
    total_dup_pct: float | None = None
    optical_dup_pct: float | None = None
    pcr_dup_pct: float | None = None
    est_library_size: int | None = None
    final_mapped_reads: int | None = None
    final_properly_paired_reads: int | None = None
    final_fragments: int | None = None
    chrm_pct: float | None = None
    mean_insert_size: float | None = None
    homer_total_tags: float | None = None
    homer_tags_per_bp: float | None = None
    homer_frag_length: float | None = None
    bam_size_mb: float | None = None
    est_genome_coverage_x: float | None = None


@dataclass(frozen=True)
class FripRecord:
    """FRiP calculation result for a (sample, peak_set) pair."""

    sample_id: str
    sample_name: str
    condition: str
    target: str
    role: str
    peak_set: str
    peak_set_type: str
    peak_count: int
    total_mapped_reads: int
    reads_in_peaks: int
    frip_pct: float


# =============================================================================
# CLI & File Matching Helpers
# =============================================================================
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compute FRiP (target vs. IgG) and Read-Retention/Depth QC summary tables and plots."
    )
    parser.add_argument("--samplesheet", type=Path, required=True, help="Path to samplesheet.csv")
    parser.add_argument("--bams", type=Path, nargs="*", default=[], help="Indexed BAM files")
    parser.add_argument("--sample-peaks", type=Path, nargs="*", default=[], help="Per-sample active peak BED files")
    parser.add_argument("--master-peaks", type=Path, nargs="*", default=[], help="Per-target master peak BED files")
    parser.add_argument("--tagdirs", type=Path, nargs="*", default=[], help="HOMER tag directories")
    parser.add_argument("--trimmomatic-logs", type=Path, nargs="*", default=[], help="Optional Trimmomatic logs")
    parser.add_argument("--bowtie2-logs", type=Path, nargs="*", default=[], help="Optional Bowtie2 logs")
    parser.add_argument("--picard-dups", type=Path, nargs="*", default=[], help="Optional Picard *_dup.txt files")
    parser.add_argument("--bam-stats", type=Path, nargs="*", default=[], help="Optional samtools flagstat/idxstats/stats")
    parser.add_argument("--chrom-sizes", type=Path, default=None, help="Optional chrom.sizes file for genome length")
    parser.add_argument("--outdir", type=Path, default=Path("."), help="Output directory")
    return parser.parse_args()


def match_file_to_sample_id(
    path: Path,
    sample_ids: Iterable[str],
    suffixes: tuple[str, ...],
) -> str | None:
    """Match a filename or directory name to a known sample_id by stripping known suffixes."""
    name = path.name
    for suffix in suffixes:
        if name.endswith(suffix):
            candidate = name[: -len(suffix)]
            if candidate in sample_ids:
                return candidate
    stem = path.stem
    if stem in sample_ids:
        return stem
    for sid in sorted(sample_ids, key=len, reverse=True):
        if name == sid or name.startswith(f"{sid}_") or name.startswith(f"{sid}."):
            return sid
    return None


def load_genome_size(chrom_sizes_path: Path | None) -> int:
    """Sum chromosome sizes from chrom.sizes (defaults to ce11 100,286,401 bp if unavailable)."""
    if chrom_sizes_path is None or not chrom_sizes_path.exists():
        return 100_286_401
    total = 0
    with chrom_sizes_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.strip().split("\t")
            if len(parts) >= 2:
                try:
                    total += int(parts[1])
                except ValueError:
                    continue
    return total if total > 0 else 100_286_401


# =============================================================================
# Upstream QC Log Parsers (Graceful Degradation)
# =============================================================================
def parse_trimmomatic_log(log_path: Path) -> tuple[int | None, int | None, float | None]:
    """Parse Input Read Pairs and Both Surviving from a Trimmomatic log."""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(
        r"Input Read Pairs:\s*(\d+)\s+Both Surviving:\s*(\d+)\s*\(([\d.]+)%\)",
        text,
    )
    if not match:
        return None, None, None
    return int(match.group(1)), int(match.group(2)), float(match.group(3))


def parse_bowtie2_log(log_path: Path) -> float | None:
    """Parse overall alignment rate (%) from a Bowtie2 log."""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"([\d.]+)%\s+overall alignment rate", text)
    return float(match.group(1)) if match else None


def parse_picard_dup(dup_path: Path) -> dict[str, float | int | None]:
    """Parse Picard MarkDuplicates metrics table."""
    result: dict[str, float | int | None] = {
        "pairs_examined": None,
        "unmapped_reads": None,
        "approx_align_pct": None,
        "total_dup_pct": None,
        "optical_dup_pct": None,
        "pcr_dup_pct": None,
        "est_library_size": None,
    }
    lines = dup_path.read_text(encoding="utf-8", errors="replace").splitlines()
    for idx, line in enumerate(lines):
        if line.startswith("LIBRARY\t") and idx + 1 < len(lines):
            headers = line.split("\t")
            values = lines[idx + 1].split("\t")
            row = dict(zip(headers, values))

            def _to_int(key: str) -> int | None:
                val = row.get(key, "").strip()
                return int(val) if val.isdigit() else None

            def _to_float(key: str) -> float | None:
                val = row.get(key, "").strip()
                try:
                    return float(val) if val else None
                except ValueError:
                    return None

            pairs_ex = _to_int("READ_PAIRS_EXAMINED")
            unpaired_ex = _to_int("UNPAIRED_READS_EXAMINED") or 0
            unmapped = _to_int("UNMAPPED_READS")
            pair_dups = _to_int("READ_PAIR_DUPLICATES")
            opt_dups = _to_int("READ_PAIR_OPTICAL_DUPLICATES")
            pct_dup = _to_float("PERCENT_DUPLICATION")
            est_lib = _to_int("ESTIMATED_LIBRARY_SIZE")

            result["pairs_examined"] = pairs_ex
            result["unmapped_reads"] = unmapped
            result["est_library_size"] = est_lib
            if pct_dup is not None:
                result["total_dup_pct"] = pct_dup * 100.0
            if pairs_ex and pairs_ex > 0:
                if unmapped is not None:
                    aligned_reads = 2 * pairs_ex + unpaired_ex
                    total_reads = aligned_reads + unmapped
                    if total_reads > 0:
                        result["approx_align_pct"] = (aligned_reads / total_reads) * 100.0
                if opt_dups is not None:
                    result["optical_dup_pct"] = (opt_dups / pairs_ex) * 100.0
                if pair_dups is not None and opt_dups is not None:
                    pcr_dups = max(pair_dups - opt_dups, 0)
                    result["pcr_dup_pct"] = (pcr_dups / pairs_ex) * 100.0
            break
    return result


def parse_flagstat(flagstat_path: Path) -> tuple[int | None, int | None]:
    """Parse mapped and properly paired QC-passed read counts from samtools flagstat."""
    mapped: int | None = None
    properly_paired: int | None = None
    for line in flagstat_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if " mapped (" in line and mapped is None:
            m = re.match(r"^(\d+)\s+\+", line.strip())
            if m:
                mapped = int(m.group(1))
        elif " properly paired (" in line and properly_paired is None:
            m = re.match(r"^(\d+)\s+\+", line.strip())
            if m:
                properly_paired = int(m.group(1))
    return mapped, properly_paired


def parse_idxstats(idxstats_path: Path) -> tuple[int | None, float | None]:
    """Parse total mapped reads and chrM (%) from samtools idxstats."""
    total_mapped = 0
    chrm_mapped = 0
    for line in idxstats_path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.strip().split("\t")
        if len(parts) < 3:
            continue
        chrom = parts[0]
        if chrom == "*":
            continue
        try:
            mapped = int(parts[2])
        except ValueError:
            continue
        total_mapped += mapped
        if chrom.lower() in {"chrm", "mt", "mtdna", "chrmt"}:
            chrm_mapped += mapped
    if total_mapped == 0:
        return None, None
    return total_mapped, (chrm_mapped / total_mapped) * 100.0


def parse_samtools_stats(stats_path: Path) -> float | None:
    """Parse average insert size from samtools stats SN summary."""
    for line in stats_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("SN\tinsert size average:"):
            parts = line.split("\t")
            if len(parts) >= 3:
                try:
                    return float(parts[2])
                except ValueError:
                    return None
    return None


def parse_homer_taginfo(tagdir: Path) -> tuple[float | None, float | None, float | None]:
    """Parse Total Tags, tagsPerBP, and fragmentLengthEstimate from HOMER tagInfo.txt."""
    taginfo = tagdir / "tagInfo.txt"
    if not taginfo.exists():
        return None, None, None
    total_tags: float | None = None
    tags_per_bp: float | None = None
    frag_len: float | None = None
    for line in taginfo.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("genome\t"):
            parts = line.split("\t")
            if len(parts) >= 3:
                try:
                    total_tags = float(parts[2])
                except ValueError:
                    pass
        elif line.startswith("fragmentLengthEstimate="):
            try:
                frag_len = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
        elif line.startswith("tagsPerBP="):
            try:
                tags_per_bp = float(line.split("=", 1)[1].strip())
            except ValueError:
                pass
    return total_tags, tags_per_bp, frag_len


# =============================================================================
# BED Interval Merging & pysam FRiP Calculation
# =============================================================================
def load_merged_bed_intervals(bed_paths: list[Path]) -> tuple[dict[str, list[tuple[int, int]]], int]:
    """Load one or more BED/Peak files and return sorted, merged non-overlapping intervals per chrom."""
    raw_by_chrom: dict[str, list[tuple[int, int]]] = {}
    raw_peak_count = 0
    for bed_path in bed_paths:
        if not bed_path.exists():
            continue
        with bed_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or stripped.startswith("track") or stripped.startswith("browser"):
                    continue
                parts = stripped.split("\t")
                if len(parts) < 3:
                    continue
                try:
                    start = int(parts[1])
                    end = int(parts[2])
                except ValueError:
                    continue
                if end <= start:
                    continue
                raw_by_chrom.setdefault(parts[0], []).append((start, end))
                raw_peak_count += 1

    merged_by_chrom: dict[str, list[tuple[int, int]]] = {}
    for chrom, intervals in raw_by_chrom.items():
        intervals.sort()
        merged: list[tuple[int, int]] = []
        cur_s, cur_e = intervals[0]
        for s, e in intervals[1:]:
            if s <= cur_e:
                cur_e = max(cur_e, e)
            else:
                merged.append((cur_s, cur_e))
                cur_s, cur_e = s, e
        merged.append((cur_s, cur_e))
        merged_by_chrom[chrom] = merged
    return merged_by_chrom, raw_peak_count


def _is_primary_mapped(read: "pysam.AlignedSegment") -> bool:
    return not (read.is_unmapped or read.is_secondary or read.is_supplementary)


def count_bam_mapped_and_chrm(bam_path: Path) -> tuple[int, float | None]:
    """Count total primary mapped reads and chrM (%) from an indexed BAM via pysam."""
    if pysam is None or not bam_path.exists():
        return 0, None
    with pysam.AlignmentFile(str(bam_path), "rb") as bam:
        total_primary = bam.count(until_eof=True, read_callback=_is_primary_mapped)
        idx_stats = bam.get_index_statistics()
        idx_total = sum(stat.mapped for stat in idx_stats)
        chrm_mapped = sum(
            stat.mapped
            for stat in idx_stats
            if stat.contig.lower() in {"chrm", "mt", "mtdna", "chrmt"}
        )
        chrm_pct = (chrm_mapped / idx_total) * 100.0 if idx_total > 0 else None
    return int(total_primary), chrm_pct


def count_reads_in_merged_peaks(
    bam_path: Path,
    merged_intervals: dict[str, list[tuple[int, int]]],
) -> int:
    """Count primary mapped reads overlapping merged non-overlapping peak intervals (no double counting)."""
    if pysam is None or not bam_path.exists() or not merged_intervals:
        return 0
    reads_in_peaks = 0
    with pysam.AlignmentFile(str(bam_path), "rb") as bam:
        valid_contigs = set(bam.references)
        for chrom, intervals in merged_intervals.items():
            if chrom not in valid_contigs:
                continue
            prev_end: int | None = None
            for start, end in intervals:
                for read in bam.fetch(chrom, start, end):
                    if not _is_primary_mapped(read):
                        continue
                    # Because intervals are strictly non-overlapping and sorted, any read with
                    # reference_start < prev_end already overlapped the previous interval.
                    if prev_end is not None and read.reference_start < prev_end:
                        continue
                    reads_in_peaks += 1
                prev_end = end
    return reads_in_peaks


# =============================================================================
# TSV Writers
# =============================================================================
def _fmt_int(val: int | None) -> str:
    return str(val) if val is not None else "NA"


def _fmt_float(val: float | None, decimals: int = 2) -> str:
    return f"{val:.{decimals}f}" if val is not None else "NA"


def write_depth_summary_tsv(metrics_list: list[SampleDepthMetrics], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    headers = [
        "sample_id",
        "sample_name",
        "condition",
        "target",
        "role",
        "raw_read_pairs",
        "trimmed_read_pairs",
        "trim_retention_pct",
        "bowtie2_align_pct",
        "approx_picard_align_pct",
        "picard_pairs_examined",
        "total_dup_pct",
        "optical_dup_pct",
        "pcr_dup_pct",
        "est_library_size",
        "final_mapped_reads",
        "final_usable_fragments",
        "homer_total_tags",
        "homer_tags_per_bp",
        "est_frag_length_bp",
        "chrm_pct",
        "bam_size_mb",
        "est_genome_coverage_x",
    ]
    with out_path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(headers) + "\n")
        for m in metrics_list:
            role = "Control" if is_igg_label(m.meta.target) else "Target"
            frag_len = m.mean_insert_size or m.homer_frag_length
            row = [
                m.meta.sample_id,
                m.meta.sample_name,
                m.meta.condition,
                m.meta.target,
                role,
                _fmt_int(m.raw_pairs),
                _fmt_int(m.trimmed_pairs),
                _fmt_float(m.trim_retention_pct, 2),
                _fmt_float(m.bowtie2_overall_align_pct, 2),
                _fmt_float(m.approx_align_pct, 2),
                _fmt_int(m.picard_pairs_examined),
                _fmt_float(m.total_dup_pct, 2),
                _fmt_float(m.optical_dup_pct, 2),
                _fmt_float(m.pcr_dup_pct, 2),
                _fmt_int(m.est_library_size),
                _fmt_int(m.final_mapped_reads),
                _fmt_int(m.final_fragments),
                _fmt_float(m.homer_total_tags, 1),
                _fmt_float(m.homer_tags_per_bp, 4),
                _fmt_float(frag_len, 1),
                _fmt_float(m.chrm_pct, 3),
                _fmt_float(m.bam_size_mb, 2),
                _fmt_float(m.est_genome_coverage_x, 2),
            ]
            handle.write("\t".join(row) + "\n")


def write_frip_summary_tsv(records: list[FripRecord], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    headers = [
        "sample_id",
        "sample_name",
        "condition",
        "target",
        "role",
        "peak_set",
        "peak_set_type",
        "peak_count",
        "total_mapped_reads",
        "reads_in_peaks",
        "frip_pct",
    ]
    with out_path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(headers) + "\n")
        for rec in records:
            row = [
                rec.sample_id,
                rec.sample_name,
                rec.condition,
                rec.target,
                rec.role,
                rec.peak_set,
                rec.peak_set_type,
                str(rec.peak_count),
                str(rec.total_mapped_reads),
                str(rec.reads_in_peaks),
                f"{rec.frip_pct:.3f}",
            ]
            handle.write("\t".join(row) + "\n")


# =============================================================================
# Publication-Grade Plots
# =============================================================================
def plot_frip_comparison(records: list[FripRecord], outdir: Path) -> None:
    configure_matplotlib_style()
    master_recs = [r for r in records if r.peak_set_type == "target_peak_set"]
    sample_recs = [r for r in records if r.peak_set_type == "per_sample"]

    has_master = len(master_recs) > 0
    has_sample = len(sample_recs) > 0

    if not has_master and not has_sample:
        fig, ax = plt.subplots(figsize=(8.0, 4.0))
        ax.text(0.5, 0.5, "No peak BED files available for FRiP calculation", ha="center", va="center")
        ax.axis("off")
        save_dual_figure(fig, outdir / "frip_comparison")
        return

    n_panels = int(has_master) + int(has_sample)
    fig, axes = plt.subplots(1, n_panels, figsize=(7.5 * n_panels, max(4.5, 0.45 * max(len(master_recs), len(sample_recs)) + 2.2)))
    if n_panels == 1:
        axes = [axes]

    panel_idx = 0
    if has_master:
        ax = axes[panel_idx]
        panel_idx += 1
        labels = [f"{r.sample_name}\n[{r.peak_set}]" for r in master_recs]
        vals = [r.frip_pct for r in master_recs]
        colors = [
            IGG_COLOR_HEX if r.role == "Control" else PALETTE_HEX[0]
            for r in master_recs
        ]
        y_pos = np.arange(len(master_recs))
        bars = ax.barh(y_pos, vals, color=colors, edgecolor="#222222", linewidth=0.7, height=0.68, zorder=3)
        max_v = max(vals, default=10.0)
        for bar, v in zip(bars, vals):
            ax.text(
                bar.get_width() + max(max_v * 0.02, 0.4),
                bar.get_y() + bar.get_height() / 2.0,
                f"{v:.1f}%",
                va="center",
                ha="left",
                fontsize=8.5,
                fontweight="bold",
            )
        ax.axvline(5.0, color="#7F7F7F", linestyle=":", linewidth=1.1, label="5% background guide", zorder=2)
        ax.axvline(10.0, color="#009E73", linestyle="--", linewidth=1.1, label="10% enrichment guide", zorder=2)
        ax.set_yticks(y_pos)
        ax.set_yticklabels(labels)
        ax.invert_yaxis()
        ax.set_xlabel("FRiP (% of Mapped Reads in Target Peak Set)")
        ax.set_xlim(0, max(max_v * 1.25, 15.0))
        ax.set_title("A. Target vs. IgG FRiP on Shared Target Peak Sets")
        ax.xaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
        ax.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="lower right", fontsize=8.5)
        despine_axis(ax)

    if has_sample:
        ax = axes[panel_idx]
        labels = [r.sample_name for r in sample_recs]
        vals = [r.frip_pct for r in sample_recs]
        cond_colors = build_condition_color_map([r.condition for r in sample_recs])
        colors = [cond_colors[r.condition] for r in sample_recs]
        y_pos = np.arange(len(sample_recs))
        bars = ax.barh(y_pos, vals, color=colors, edgecolor="#222222", linewidth=0.7, height=0.68, zorder=3)
        max_v = max(vals, default=10.0)
        for bar, v, rec in zip(bars, vals, sample_recs):
            ax.text(
                bar.get_width() + max(max_v * 0.02, 0.4),
                bar.get_y() + bar.get_height() / 2.0,
                f"{v:.1f}% ({rec.peak_count:,} peaks)",
                va="center",
                ha="left",
                fontsize=8.5,
                fontweight="bold",
            )
        ax.axvline(10.0, color="#009E73", linestyle="--", linewidth=1.1, label="10% enrichment guide", zorder=2)
        ax.set_yticks(y_pos)
        ax.set_yticklabels(labels)
        ax.invert_yaxis()
        ax.set_xlabel("FRiP (% of Mapped Reads in Own Peaks)")
        ax.set_xlim(0, max(max_v * 1.38, 15.0))
        panel_letter = "B" if has_master else "A"
        ax.set_title(f"{panel_letter}. Per-Sample FRiP (Own Called Peaks)")
        ax.xaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
        ax.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="lower right", fontsize=8.5)
        despine_axis(ax)

    fig.suptitle("Fraction of Reads in Peaks (FRiP) — Enrichment vs. Background", y=1.02)
    fig.tight_layout()
    save_dual_figure(fig, outdir / "frip_comparison")


def plot_read_retention_funnel(metrics_list: list[SampleDepthMetrics], outdir: Path) -> None:
    configure_matplotlib_style()
    if not metrics_list:
        fig, ax = plt.subplots(figsize=(8.0, 4.0))
        ax.text(0.5, 0.5, "No sample depth metrics available", ha="center", va="center")
        ax.axis("off")
        save_dual_figure(fig, outdir / "read_retention_funnel")
        return

    names = [m.meta.sample_name for m in metrics_list]
    n_samples = len(names)
    x = np.arange(n_samples)

    fig, axes = plt.subplots(1, 3, figsize=(17.5, 5.4), gridspec_kw={"width_ratios": [1.35, 1.05, 1.0]})
    ax_ret, ax_dup, ax_cov = axes

    # Panel A: Read-Pair Retention Across Pipeline Stages (Millions)
    stage_defs = [
        ("Raw Pairs", [m.raw_pairs for m in metrics_list], "#0072B2"),
        ("Trimmed Pairs", [m.trimmed_pairs for m in metrics_list], "#56B4E9"),
        ("Aligned Pairs (Picard)", [m.picard_pairs_examined for m in metrics_list], "#E69F00"),
        ("Final Usable Fragments", [m.final_fragments for m in metrics_list], "#009E73"),
    ]
    active_stages = [
        (label, vals, color)
        for label, vals, color in stage_defs
        if any(v is not None for v in vals)
    ]
    if active_stages:
        width = 0.78 / len(active_stages)
        for s_idx, (label, vals, color) in enumerate(active_stages):
            offset = (s_idx - (len(active_stages) - 1) / 2.0) * width
            heights = [(v / 1e6) if v is not None else 0.0 for v in vals]
            ax_ret.bar(x + offset, heights, width=width * 0.92, label=label, color=color, edgecolor="#222222", linewidth=0.5, zorder=3)
        ax_ret.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", fontsize=8.5)
    else:
        ax_ret.text(0.5, 0.5, "No read-count stages available", ha="center", va="center", transform=ax_ret.transAxes)
    ax_ret.set_xticks(x)
    ax_ret.set_xticklabels(names, rotation=30, ha="right")
    ax_ret.set_ylabel("Read Pairs / Fragments (Millions)")
    ax_ret.set_title("A. Read Retention Across Pipeline Stages")
    ax_ret.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_ret)

    # Panel B: Duplication Breakdown (Unique vs. Optical vs. True PCR)
    has_dup = any(m.total_dup_pct is not None for m in metrics_list)
    if has_dup:
        pcr_vals = np.array([m.pcr_dup_pct or 0.0 for m in metrics_list])
        opt_vals = np.array([m.optical_dup_pct or 0.0 for m in metrics_list])
        tot_vals = np.array([m.total_dup_pct or 0.0 for m in metrics_list])
        # If optical/pcr breakdown unavailable, plot total dup as single bar
        if np.all(pcr_vals == 0) and np.all(opt_vals == 0):
            ax_dup.bar(x, tot_vals, color="#D55E00", edgecolor="#222222", linewidth=0.6, label="Total Duplication (%)", zorder=3)
        else:
            ax_dup.bar(x, pcr_vals, color="#D55E00", edgecolor="#222222", linewidth=0.6, label="True PCR Dups (%)", zorder=3)
            ax_dup.bar(x, opt_vals, bottom=pcr_vals, color="#F0E442", edgecolor="#222222", linewidth=0.6, label="Optical Dups (%)", zorder=3)
        ax_dup.axhline(30.0, color="#7F7F7F", linestyle="--", linewidth=1.0, label="30% warning guide", zorder=2)
        ax_dup.set_ylim(0, max(float(np.max(tot_vals)) * 1.25, 35.0))
        ax_dup.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", fontsize=8.5)
    else:
        ax_dup.text(0.5, 0.5, "No Picard duplication metrics", ha="center", va="center", transform=ax_dup.transAxes)
    ax_dup.set_xticks(x)
    ax_dup.set_xticklabels(names, rotation=30, ha="right")
    ax_dup.set_ylabel("Duplication Rate (%)")
    ax_dup.set_title("B. Library Duplication Breakdown")
    ax_dup.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_dup)

    # Panel C: Estimated Genome Coverage (X) & chrM%
    cov_vals = [m.est_genome_coverage_x or 0.0 for m in metrics_list]
    cond_colors = build_condition_color_map([m.meta.condition for m in metrics_list])
    bar_colors = [
        IGG_COLOR_HEX if is_igg_label(m.meta.target) else cond_colors[m.meta.condition]
        for m in metrics_list
    ]
    bars = ax_cov.bar(x, cov_vals, color=bar_colors, edgecolor="#222222", linewidth=0.6, zorder=3)
    max_cov = max(cov_vals, default=10.0)
    for bar, m in zip(bars, metrics_list):
        cov_str = f"{m.est_genome_coverage_x:.1f}x" if m.est_genome_coverage_x is not None else "NA"
        chrm_str = f"\nchrM {m.chrm_pct:.2f}%" if m.chrm_pct is not None else ""
        ax_cov.text(
            bar.get_x() + bar.get_width() / 2.0,
            bar.get_height() + max(max_cov * 0.02, 0.3),
            f"{cov_str}{chrm_str}",
            ha="center",
            va="bottom",
            fontsize=8.0,
            fontweight="bold",
        )
    ax_cov.set_xticks(x)
    ax_cov.set_xticklabels(names, rotation=30, ha="right")
    ax_cov.set_ylabel("Estimated Mean Genome Coverage (X)")
    ax_cov.set_ylim(0, max(max_cov * 1.28, 10.0))
    ax_cov.set_title("C. Sequencing Depth & Mitochondrial %")
    ax_cov.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_cov)

    fig.suptitle("Read Retention, Library Complexity & Sequencing Depth Summary", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, outdir / "read_retention_funnel")


# =============================================================================
# Main Orchestration
# =============================================================================
def main() -> None:
    args = parse_args()
    samples_map = load_samplesheet(args.samplesheet)
    sample_ids = set(samples_map.keys())
    genome_size = load_genome_size(args.chrom_sizes)

    # Order samples: experimental targets first (grouped by target, sample_name), IgG controls last
    ordered_metas = sorted(
        samples_map.values(),
        key=lambda m: (1 if is_igg_label(m.target) else 0, m.target.lower(), m.sample_name.lower()),
    )

    # Map staged files by sample_id
    bam_by_id: dict[str, Path] = {}
    for p in args.bams:
        sid = match_file_to_sample_id(p, sample_ids, (".bam",))
        if sid:
            bam_by_id[sid] = p

    tagdir_by_id: dict[str, Path] = {}
    for p in args.tagdirs:
        sid = match_file_to_sample_id(p, sample_ids, ("_tagdir",))
        if sid:
            tagdir_by_id[sid] = p

    trim_by_id: dict[str, Path] = {}
    for p in args.trimmomatic_logs:
        sid = match_file_to_sample_id(p, sample_ids, ("_trimmomatic.log", ".log"))
        if sid:
            trim_by_id[sid] = p

    bt2_by_id: dict[str, Path] = {}
    for p in args.bowtie2_logs:
        sid = match_file_to_sample_id(p, sample_ids, ("_bowtie2.log", ".log"))
        if sid:
            bt2_by_id[sid] = p

    dup_by_id: dict[str, Path] = {}
    for p in args.picard_dups:
        sid = match_file_to_sample_id(p, sample_ids, ("_dup.txt", ".txt"))
        if sid:
            dup_by_id[sid] = p

    flagstat_by_id: dict[str, Path] = {}
    idxstats_by_id: dict[str, Path] = {}
    stats_by_id: dict[str, Path] = {}
    for p in args.bam_stats:
        if p.name.endswith(".flagstat"):
            sid = match_file_to_sample_id(p, sample_ids, (".flagstat",))
            if sid:
                flagstat_by_id[sid] = p
        elif p.name.endswith(".idxstats"):
            sid = match_file_to_sample_id(p, sample_ids, (".idxstats",))
            if sid:
                idxstats_by_id[sid] = p
        elif p.name.endswith(".stats"):
            sid = match_file_to_sample_id(p, sample_ids, (".stats",))
            if sid:
                stats_by_id[sid] = p

    sample_peak_by_id: dict[str, Path] = {}
    peak_suffixes = (
        "_macs2_merge_ready_peaks.bed",
        "_homer_merge_ready_peaks.bed",
        "_merge_ready_peaks.bed",
        "_peaks.narrowPeak",
        "_peaks.broadPeak",
        "_peaks.bed",
        ".narrowPeak",
        ".broadPeak",
        ".bed",
    )
    for p in args.sample_peaks:
        sid = match_file_to_sample_id(p, sample_ids, peak_suffixes)
        if sid:
            sample_peak_by_id[sid] = p

    # Map master peaks by target name
    known_targets = {m.target for m in ordered_metas if not is_igg_label(m.target)}
    master_peak_by_target: dict[str, Path] = {}
    for p in args.master_peaks:
        for tgt in sorted(known_targets, key=len, reverse=True):
            if p.name.startswith(f"{tgt}_") or p.stem == tgt:
                master_peak_by_target[tgt] = p
                break

    # 1. Aggregate Depth & Read-Retention Metrics
    metrics_list: list[SampleDepthMetrics] = []
    bam_total_primary_by_id: dict[str, int] = {}

    for meta in ordered_metas:
        sid = meta.sample_id
        m = SampleDepthMetrics(meta=meta)

        if sid in trim_by_id:
            m.raw_pairs, m.trimmed_pairs, m.trim_retention_pct = parse_trimmomatic_log(trim_by_id[sid])

        if sid in bt2_by_id:
            m.bowtie2_overall_align_pct = parse_bowtie2_log(bt2_by_id[sid])

        if sid in dup_by_id:
            dup_info = parse_picard_dup(dup_by_id[sid])
            m.picard_pairs_examined = dup_info["pairs_examined"]  # type: ignore[assignment]
            m.picard_unmapped_reads = dup_info["unmapped_reads"]  # type: ignore[assignment]
            m.approx_align_pct = dup_info["approx_align_pct"]  # type: ignore[assignment]
            m.total_dup_pct = dup_info["total_dup_pct"]  # type: ignore[assignment]
            m.optical_dup_pct = dup_info["optical_dup_pct"]  # type: ignore[assignment]
            m.pcr_dup_pct = dup_info["pcr_dup_pct"]  # type: ignore[assignment]
            m.est_library_size = dup_info["est_library_size"]  # type: ignore[assignment]

        if sid in flagstat_by_id:
            m.final_mapped_reads, m.final_properly_paired_reads = parse_flagstat(flagstat_by_id[sid])

        if sid in idxstats_by_id:
            idx_total, m.chrm_pct = parse_idxstats(idxstats_by_id[sid])
            if m.final_mapped_reads is None:
                m.final_mapped_reads = idx_total

        if sid in stats_by_id:
            m.mean_insert_size = parse_samtools_stats(stats_by_id[sid])

        if sid in tagdir_by_id:
            m.homer_total_tags, m.homer_tags_per_bp, m.homer_frag_length = parse_homer_taginfo(tagdir_by_id[sid])

        if sid in bam_by_id and bam_by_id[sid].exists():
            bam_path = bam_by_id[sid]
            m.bam_size_mb = bam_path.stat().st_size / (1024.0 * 1024.0)
            primary_count, pysam_chrm_pct = count_bam_mapped_and_chrm(bam_path)
            if primary_count > 0:
                bam_total_primary_by_id[sid] = primary_count
                if m.final_mapped_reads is None:
                    m.final_mapped_reads = primary_count
            if m.chrm_pct is None and pysam_chrm_pct is not None:
                m.chrm_pct = pysam_chrm_pct

        # Estimate usable fragments
        if m.final_properly_paired_reads is not None and m.final_properly_paired_reads > 0:
            m.final_fragments = m.final_properly_paired_reads // 2
        elif m.final_mapped_reads is not None and m.final_mapped_reads > 0:
            m.final_fragments = m.final_mapped_reads // 2
        elif m.homer_total_tags is not None:
            m.final_fragments = int(round(m.homer_total_tags))

        # Estimate genome-wide mean coverage (X)
        frag_len = m.mean_insert_size or m.homer_frag_length or 150.0
        if m.final_fragments is not None and genome_size > 0:
            m.est_genome_coverage_x = (m.final_fragments * frag_len) / float(genome_size)

        metrics_list.append(m)

    # 2. Compute FRiP (Per-sample peaks AND Shared Target Peak Sets including IgG controls)
    frip_records: list[FripRecord] = []

    # 2A. Per-sample FRiP for experimental samples
    for meta in ordered_metas:
        if is_igg_label(meta.target):
            continue
        sid = meta.sample_id
        if sid not in bam_by_id or sid not in sample_peak_by_id:
            continue
        total_reads = bam_total_primary_by_id.get(sid, 0)
        if total_reads <= 0:
            continue
        intervals, peak_count = load_merged_bed_intervals([sample_peak_by_id[sid]])
        in_peaks = count_reads_in_merged_peaks(bam_by_id[sid], intervals)
        frip_pct = (in_peaks / total_reads) * 100.0
        frip_records.append(
            FripRecord(
                sample_id=sid,
                sample_name=meta.sample_name,
                condition=meta.condition,
                target=meta.target,
                role="Target",
                peak_set=meta.sample_name,
                peak_set_type="per_sample",
                peak_count=peak_count,
                total_mapped_reads=total_reads,
                reads_in_peaks=in_peaks,
                frip_pct=frip_pct,
            )
        )

    # 2B. Shared target peak set FRiP (Targets + IgG controls evaluated on the exact same peak set)
    igg_metas = [m for m in ordered_metas if is_igg_label(m.target)]
    for target in sorted(known_targets, key=str.lower):
        target_metas = [m for m in ordered_metas if m.target == target]
        if target in master_peak_by_target:
            peak_paths = [master_peak_by_target[target]]
        else:
            peak_paths = [sample_peak_by_id[m.sample_id] for m in target_metas if m.sample_id in sample_peak_by_id]

        if not peak_paths:
            continue

        intervals, peak_count = load_merged_bed_intervals(peak_paths)
        if not intervals:
            continue

        # Select matched IgG controls for this target (referenced via control_id, else all IgG controls)
        referenced_ctrl_ids = {m.control_id for m in target_metas if m.control_id}
        matched_igg = (
            [m for m in igg_metas if m.sample_id in referenced_ctrl_ids]
            if referenced_ctrl_ids
            else igg_metas
        )

        for meta in target_metas + matched_igg:
            sid = meta.sample_id
            if sid not in bam_by_id:
                continue
            total_reads = bam_total_primary_by_id.get(sid, 0)
            if total_reads <= 0:
                continue
            in_peaks = count_reads_in_merged_peaks(bam_by_id[sid], intervals)
            frip_pct = (in_peaks / total_reads) * 100.0
            role = "Control" if is_igg_label(meta.target) else "Target"
            frip_records.append(
                FripRecord(
                    sample_id=sid,
                    sample_name=meta.sample_name,
                    condition=meta.condition,
                    target=meta.target,
                    role=role,
                    peak_set=f"{target}_peaks",
                    peak_set_type="target_peak_set",
                    peak_count=peak_count,
                    total_mapped_reads=total_reads,
                    reads_in_peaks=in_peaks,
                    frip_pct=frip_pct,
                )
            )

    # 3. Write TSV tables & plots
    args.outdir.mkdir(parents=True, exist_ok=True)
    write_depth_summary_tsv(metrics_list, args.outdir / "read_retention_depth_summary.tsv")
    write_frip_summary_tsv(frip_records, args.outdir / "frip_summary.tsv")
    plot_frip_comparison(frip_records, args.outdir)
    plot_read_retention_funnel(metrics_list, args.outdir)


if __name__ == "__main__":
    main()
