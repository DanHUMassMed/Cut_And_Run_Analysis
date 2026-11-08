#!/usr/bin/env python3
"""Plot 1: Peak Count & Replicate Overlap Bar Chart (from 09_peaks & 10_merged_peaks)."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from cutandrun_plot_utils import (
    SampleMetadata,
     configure_matplotlib_style,
    count_bed_intervals,
    despine_axis,
    load_samplesheet,
    save_dual_figure,
)


@dataclass
class PeakCountRecord:
    """Single peak count entry across pipeline stages."""

    target: str
    stage: str
    entity_id: str
    display_name: str
    condition: str
    peak_count: int
    source_file: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Peak Count & Replicate Overlap Bar Chart and TSV summary."
    )
    parser.add_argument("--samplesheet", type=Path, required=False, default=None, help="Path to samplesheet.csv")
    parser.add_argument(
        "--macs2-peaks",
        type=Path,
        nargs="*",
        default=[],
        help="MACS2 per-sample peak files (*_peaks.narrowPeak / *_peaks.broadPeak)",
    )
    parser.add_argument(
        "--homer-peaks",
        type=Path,
        nargs="*",
        default=[],
        help="HOMER per-sample peak files (*_peaks.bed)",
    )
    parser.add_argument(
        "--sample-peaks",
        type=Path,
        nargs="*",
        default=[],
        help="Active caller per-sample peak files (used when caller-specific lists are not provided)",
    )
    parser.add_argument(
        "--replicated-peaks",
        type=Path,
        nargs="*",
        default=[],
        help="Replicate-merged BED files (*_replicated_peaks.bed)",
    )
    parser.add_argument(
        "--master-peaks",
        type=Path,
        nargs="*",
        default=[],
        help="Master merged BED files per target (*_master_peaks.bed)",
    )
    parser.add_argument(
        "--peak-files",
        type=Path,
        nargs="*",
        default=[],
        help="Mixed list of peak files auto-classified by filename suffix (*_peaks.narrowPeak, *_peaks.bed, *_replicated_peaks.bed, *_master_peaks.bed)",
    )
    parser.add_argument("--out-prefix", type=Path, default=Path("peak_counts_summary"), help="Output file prefix")
    return parser.parse_args()


def strip_known_suffixes(filename: str, suffixes: list[str]) -> str:
    for suffix in suffixes:
        if filename.endswith(suffix):
            return filename[: -len(suffix)]
    return Path(filename).stem


def collect_peak_records(
    samplesheet_map: dict[str, SampleMetadata],
    macs2_files: list[Path],
    homer_files: list[Path],
    sample_files: list[Path],
    replicated_files: list[Path],
    master_files: list[Path],
) -> list[PeakCountRecord]:
    records: list[PeakCountRecord] = []

    condition_to_target: dict[str, str] = {}
    for meta in samplesheet_map.values():
        if meta.target.lower() != "igg":
            condition_to_target[meta.condition] = meta.target

    sample_suffixes = [
        "_peaks.narrowPeak",
        "_peaks.broadPeak",
        "_peaks.bed",
        ".narrowPeak",
        ".broadPeak",
        ".bed",
    ]

    def add_sample_files(files: list[Path], stage_label: str) -> None:
        seen_paths: set[str] = set()
        for path in sorted(files, key=lambda p: p.name):
            if not path.exists() or path.name in seen_paths:
                continue
            seen_paths.add(path.name)
            sample_id = strip_known_suffixes(path.name, sample_suffixes)
            meta = samplesheet_map.get(sample_id)
            if meta and meta.target.lower() == "igg":
                continue
            target = meta.target if meta else "default"
            display_name = meta.sample_name if meta else sample_id
            condition = meta.condition if meta else sample_id
            records.append(
                PeakCountRecord(
                    target=target,
                    stage=stage_label,
                    entity_id=sample_id,
                    display_name=display_name,
                    condition=condition,
                    peak_count=count_bed_intervals(path),
                    source_file=path.name,
                )
            )

    if macs2_files or homer_files:
        add_sample_files(macs2_files, "MACS2 Sample Peaks")
        add_sample_files(homer_files, "HOMER Sample Peaks")
    else:
        add_sample_files(sample_files, "Sample Peaks")

    for path in sorted(replicated_files, key=lambda p: p.name):
        if not path.exists():
            continue
        cond_id = strip_known_suffixes(path.name, ["_replicated_peaks.bed", ".bed"])
        target = condition_to_target.get(cond_id, "default")
        records.append(
            PeakCountRecord(
                target=target,
                stage="Replicate-Merged Peaks",
                entity_id=cond_id,
                display_name=cond_id,
                condition=cond_id,
                peak_count=count_bed_intervals(path),
                source_file=path.name,
            )
        )

    for path in sorted(master_files, key=lambda p: p.name):
        if not path.exists():
            continue
        target_id = strip_known_suffixes(path.name, ["_master_peaks.bed", ".bed"])
        records.append(
            PeakCountRecord(
                target=target_id,
                stage="Master Peaks (Target Union)",
                entity_id=target_id,
                display_name=f"{target_id} Master",
                condition="Master Union",
                peak_count=count_bed_intervals(path),
                source_file=path.name,
            )
        )

    return records


def write_tsv_summary(records: list[PeakCountRecord], tsv_path: Path) -> None:
    tsv_path.parent.mkdir(parents=True, exist_ok=True)
    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write("Target\tStage\tEntity_ID\tDisplay_Name\tCondition\tPeak_Count\tSource_File\n")
        for rec in records:
            handle.write(
                f"{rec.target}\t{rec.stage}\t{rec.entity_id}\t{rec.display_name}\t"
                f"{rec.condition}\t{rec.peak_count}\t{rec.source_file}\n"
            )


def render_peak_counts_figure(records: list[PeakCountRecord], out_prefix: Path) -> None:
    configure_matplotlib_style()

    targets = sorted({rec.target for rec in records})
    if not targets:
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.text(0.5, 0.5, "No peak files found to plot.", ha="center", va="center")
        save_dual_figure(fig, out_prefix)
        return

    stage_colors: dict[str, str] = {
        "MACS2 Sample Peaks": "#0072B2",
        "Sample Peaks": "#0072B2",
        "HOMER Sample Peaks": "#56B4E9",
        "Replicate-Merged Peaks": "#009E73",
        "Master Peaks (Target Union)": "#D55E00",
    }

    fig, axes = plt.subplots(
        1,
        len(targets),
        figsize=(max(6.5 * len(targets), 8.0), 5.8),
        squeeze=False,
    )

    for idx, target in enumerate(targets):
        ax = axes[0, idx]
        target_recs = [r for r in records if r.target == target]

        # Collect condition/sample names (excluding Master Union)
        sample_entities: list[str] = []
        for r in target_recs:
            if r.stage != "Master Peaks (Target Union)" and r.display_name not in sample_entities:
                sample_entities.append(r.display_name)

        active_stages = [
            s
            for s in ["MACS2 Sample Peaks", "Sample Peaks", "HOMER Sample Peaks", "Replicate-Merged Peaks"]
            if any(r.stage == s for r in target_recs)
        ]

        x_labels = sample_entities + [f"{target}\nMaster Union"]
        x_pos = np.arange(len(x_labels), dtype=np.float64)

        num_stages = max(len(active_stages), 1)
        total_group_width = 0.72
        bar_width = total_group_width / num_stages

        max_val = max((r.peak_count for r in target_recs), default=100)

        for s_idx, stage in enumerate(active_stages):
            offset = (s_idx - (num_stages - 1) / 2.0) * bar_width
            counts: list[int] = []
            for name in sample_entities:
                matches = [r.peak_count for r in target_recs if r.stage == stage and r.display_name == name]
                counts.append(matches[0] if matches else 0)

            positions = x_pos[:-1] + offset
            bars = ax.bar(
                positions,
                counts,
                width=bar_width * 0.92,
                color=stage_colors.get(stage, "#0072B2"),
                edgecolor="#222222",
                linewidth=0.7,
                label=stage,
                zorder=3,
            )
            for bar, val in zip(bars, counts):
                if val > 0:
                    ax.text(
                        bar.get_x() + bar.get_width() / 2.0,
                        bar.get_height() + max_val * 0.015,
                        f"{val:,}",
                        ha="center",
                        va="bottom",
                        fontsize=8,
                        fontweight="bold",
                        color="#222222",
                    )

        # Plot Master Peak count bar at the far right
        master_matches = [r.peak_count for r in target_recs if r.stage == "Master Peaks (Target Union)"]
        if master_matches:
            m_val = master_matches[0]
            m_bar = ax.bar(
                [x_pos[-1]],
                [m_val],
                width=min(bar_width * 1.3, 0.5),
                color=stage_colors["Master Peaks (Target Union)"],
                edgecolor="#222222",
                linewidth=0.9,
                label="Master Peaks (Target Union)",
                zorder=3,
            )
            ax.text(
                m_bar[0].get_x() + m_bar[0].get_width() / 2.0,
                m_val + max_val * 0.015,
                f"{m_val:,}",
                ha="center",
                va="bottom",
                fontsize=9,
                fontweight="bold",
                color="#B22222",
            )
            ax.axhline(
                m_val,
                color=stage_colors["Master Peaks (Target Union)"],
                linestyle="--",
                linewidth=1.0,
                alpha=0.5,
                zorder=2,
            )

        ax.set_title(f"{target} — Peak Calling & Merging Progression")
        ax.set_xticks(x_pos)
        ax.set_xticklabels(x_labels, rotation=22, ha="right")
        ax.set_ylabel("Number of Peaks")
        ax.set_ylim(0, max_val * 1.32)
        ax.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
        despine_axis(ax)
        ax.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="upper left")

    fig.suptitle("CUT&RUN Peak Count & Replicate Overlap Summary", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, out_prefix)


def main() -> None:
    args = parse_args()
    samplesheet_map = load_samplesheet(args.samplesheet)

    macs2_files = list(args.macs2_peaks)
    homer_files = list(args.homer_peaks)
    sample_files = list(args.sample_peaks)
    replicated_files = list(args.replicated_peaks)
    master_files = list(args.master_peaks)

    for p in args.peak_files:
        name = p.name
        if name.endswith("_master_peaks.bed"):
            master_files.append(p)
        elif name.endswith("_replicated_peaks.bed"):
            replicated_files.append(p)
        elif name.endswith("_peaks.narrowPeak") or name.endswith("_peaks.broadPeak"):
            macs2_files.append(p)
        elif name.endswith("_peaks.bed"):
            homer_files.append(p)
        else:
            sample_files.append(p)

    records = collect_peak_records(
        samplesheet_map=samplesheet_map,
        macs2_files=macs2_files,
        homer_files=homer_files,
        sample_files=sample_files,
        replicated_files=replicated_files,
        master_files=master_files,
    )
    write_tsv_summary(records, args.out_prefix.with_suffix(".tsv"))
    render_peak_counts_figure(records, args.out_prefix)


if __name__ == "__main__":
    main()
