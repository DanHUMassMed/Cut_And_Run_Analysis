#!/usr/bin/env python3
"""Plot 5: Volcano & MA Plots for Condition Comparisons (from 12_differential_peaks)."""

from __future__ import annotations

import argparse
import math
import re
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from cutandrun_plot_utils import (
    DifferentialPeakRow,
    configure_matplotlib_style,
    despine_axis,
    parse_homer_differential_table,
    save_dual_figure,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Volcano & MA plots and top differential gene TSV from HOMER differential peaks."
    )
    parser.add_argument("--diff-file", type=Path, required=True, help="HOMER *_differential_peaks.txt")
    parser.add_argument("--contrast-id", type=str, required=False, default=None, help="Contrast identifier")
    parser.add_argument("--treatment", type=str, required=False, default="Treatment", help="Treatment condition label")
    parser.add_argument("--background", type=str, required=False, default="Background", help="Background condition label")
    parser.add_argument("--target", type=str, required=False, default="", help="Target mark name")
    parser.add_argument("--fdr-threshold", type=float, default=0.05, help="Significance threshold (default: 0.05)")
    parser.add_argument("--log2fc-threshold", type=float, default=1.0, help="Absolute log2FC threshold (default: 1.0)")
    parser.add_argument("--top-n-labels", type=int, default=12, help="Number of top genes to label on plots")
    parser.add_argument("--out-prefix", type=Path, required=False, default=None, help="Output file prefix")
    return parser.parse_args()


def infer_contrast_labels(
    contrast_id: str,
    treatment_arg: str,
    background_arg: str,
) -> tuple[str, str]:
    if treatment_arg != "Treatment" or background_arg != "Background":
        return treatment_arg, background_arg
    if "_vs_" in contrast_id:
        parts = contrast_id.split("_vs_", 1)
        return parts[0], parts[1]
    return treatment_arg, background_arg


def write_top_differential_tsv(
    rows: list[DifferentialPeakRow],
    tsv_path: Path,
    use_raw_pvalue: bool,
    sig_threshold: float,
    log2fc_threshold: float,
    treatment: str,
    background: str,
) -> None:
    tsv_path.parent.mkdir(parents=True, exist_ok=True)

    def sort_key(r: DifferentialPeakRow) -> tuple[int, float, float]:
        sig_val = r.p_value if use_raw_pvalue else r.fdr
        is_sig = 0 if (sig_val < sig_threshold and abs(r.log2_fc) >= log2fc_threshold) else 1
        return (is_sig, sig_val, -abs(r.log2_fc))

    sorted_rows = sorted(rows, key=sort_key)

    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write(
            "PeakID\tChr\tStart\tEnd\tGene_Name\tGene_Description\tGenomic_Feature\tDistance_to_TSS\t"
            f"Mean_{background}_Tags\tMean_{treatment}_Tags\tLog2_Fold_Change\tP_Value\tAdj_P_Value_FDR\tDirection\n"
        )
        for r in sorted_rows[:500]:
            sig_val = r.p_value if use_raw_pvalue else r.fdr
            if sig_val < sig_threshold and r.log2_fc >= log2fc_threshold:
                direction = f"Up_in_{treatment}"
            elif sig_val < sig_threshold and r.log2_fc <= -log2fc_threshold:
                direction = f"Up_in_{background}"
            else:
                direction = "NS"
            dist_str = str(r.distance_to_tss) if r.distance_to_tss is not None else "NA"
            handle.write(
                f"{r.peak_id}\t{r.chrom}\t{r.start}\t{r.end}\t{r.gene_name}\t{r.gene_description}\t"
                f"{r.annotation_category}\t{dist_str}\t{r.bg_tag_count:.2f}\t{r.treat_tag_count:.2f}\t"
                f"{r.log2_fc:.4f}\t{r.p_value:.4e}\t{r.fdr:.4e}\t{direction}\n"
            )


def annotate_top_points(
    ax: plt.Axes,
    candidates: list[tuple[float, float, str, str]],
    x_span: float,
    y_span: float,
) -> None:
    """Place non-overlapping callout labels for top candidate peaks using vertical repulsion."""
    if not candidates:
        return
    # Deduplicate by gene label, keeping the most extreme point
    deduped: list[tuple[float, float, str, str]] = []
    seen_genes: set[str] = set()
    for item in sorted(candidates, key=lambda t: abs(t[1]), reverse=True):
        if item[2] not in seen_genes:
            seen_genes.add(item[2])
            deduped.append(item)

    placed_boxes: list[tuple[float, float]] = []
    min_dy = y_span * 0.055
    min_dx = x_span * 0.16

    for idx, (x_val, y_val, label, color) in enumerate(deduped):
        direction = -1.0 if (idx % 2 == 1) else 1.0
        if x_val < -0.2 * x_span:
            direction = -1.0
        elif x_val > 0.2 * x_span:
            direction = 1.0

        tx = x_val + direction * (x_span * 0.04)
        ty = y_val + (y_span * 0.03 if y_val >= 0 else -y_span * 0.03)

        # Push vertically away from already-placed labels nearby in x
        for _step in range(25):
            collision = False
            for px, py in placed_boxes:
                if abs(tx - px) < min_dx and abs(ty - py) < min_dy:
                    collision = True
                    ty += min_dy * (0.65 if ty >= py else -0.65)
            if not collision:
                break

        placed_boxes.append((tx, ty))
        ha_align = "left" if tx >= x_val else "right"
        ax.annotate(
            label,
            xy=(x_val, y_val),
            xytext=(tx, ty),
            ha=ha_align,
            va="center",
            fontsize=8,
            fontweight="bold",
            color=color,
            bbox={"boxstyle": "round,pad=0.15", "fc": "white", "ec": color, "lw": 0.6, "alpha": 0.90},
            arrowprops={"arrowstyle": "-", "color": color, "lw": 0.6, "alpha": 0.75},
            zorder=6,
        )


def render_volcano_and_ma(
    rows: list[DifferentialPeakRow],
    contrast_id: str,
    treatment: str,
    background: str,
    target: str,
    fdr_threshold: float,
    log2fc_threshold: float,
    top_n_labels: int,
    out_prefix: Path,
) -> None:
    configure_matplotlib_style()

    if not rows:
        fig, ax = plt.subplots(figsize=(8, 4))
        ax.text(0.5, 0.5, f"No differential peaks found for {contrast_id}", ha="center", va="center")
        save_dual_figure(fig, out_prefix)
        return

    # Check whether BH-adjusted p-values have any < 1.0 values
    has_informative_fdr = any(r.fdr < 0.9999 for r in rows)
    use_raw_pvalue = not has_informative_fdr

    write_top_differential_tsv(
        rows=rows,
        tsv_path=out_prefix.parent / f"{contrast_id}_top_differential_genes.tsv",
        use_raw_pvalue=use_raw_pvalue,
        sig_threshold=fdr_threshold,
        log2fc_threshold=log2fc_threshold,
        treatment=treatment,
        background=background,
    )

    log2_fcs = np.array([r.log2_fc for r in rows], dtype=np.float64)
    mean_signals = np.array([r.mean_log2_signal for r in rows], dtype=np.float64)
    sig_vals = np.array([r.p_value if use_raw_pvalue else r.fdr for r in rows], dtype=np.float64)
    neg_log10_sig = -np.log10(np.clip(sig_vals, 1e-300, 1.0))

    up_mask = (sig_vals < fdr_threshold) & (log2_fcs >= log2fc_threshold)
    down_mask = (sig_vals < fdr_threshold) & (log2_fcs <= -log2fc_threshold)
    ns_mask = ~(up_mask | down_mask)

    n_up = int(np.sum(up_mask))
    n_down = int(np.sum(down_mask))
    n_ns = int(np.sum(ns_mask))

    color_up = "#D55E00"    # Vermilion (Up in Treatment)
    color_down = "#0072B2"  # Blue (Up in Background)
    color_ns = "#B0B0B0"    # Muted Gray

    fig, axes = plt.subplots(1, 2, figsize=(15.5, 6.2))
    ax_vol, ax_ma = axes

    metric_label = "Raw p-value (all FDR = 1.0)" if use_raw_pvalue else "Adjusted p-value (FDR)"
    short_metric = "p" if use_raw_pvalue else "FDR"

    # =========================================================================
    # Panel A: Volcano Plot
    # =========================================================================
    ax_vol.scatter(
        log2_fcs[ns_mask],
        neg_log10_sig[ns_mask],
        s=14,
        color=color_ns,
        alpha=0.45,
        edgecolors="none",
        label=f"Not Significant ({n_ns:,})",
        zorder=2,
    )
    ax_vol.scatter(
        log2_fcs[down_mask],
        neg_log10_sig[down_mask],
        s=24,
        color=color_down,
        alpha=0.80,
        edgecolors="none",
        label=f"Higher in {background} ({n_down:,})",
        zorder=3,
    )
    ax_vol.scatter(
        log2_fcs[up_mask],
        neg_log10_sig[up_mask],
        s=24,
        color=color_up,
        alpha=0.80,
        edgecolors="none",
        label=f"Higher in {treatment} ({n_up:,})",
        zorder=3,
    )

    y_thresh = -math.log10(fdr_threshold)
    ax_vol.axhline(y_thresh, color="#444444", linestyle="--", linewidth=1.0, zorder=4)
    ax_vol.axvline(log2fc_threshold, color="#444444", linestyle="--", linewidth=1.0, zorder=4)
    ax_vol.axvline(-log2fc_threshold, color="#444444", linestyle="--", linewidth=1.0, zorder=4)

    # Select top genes to annotate on Volcano & MA plots
    up_indices = np.where(up_mask)[0]
    down_indices = np.where(down_mask)[0]

    # If no points pass threshold, still label the top 5 most extreme peaks so plot is informative
    if up_indices.size == 0 and down_indices.size == 0:
        ranked_all = np.argsort(-(neg_log10_sig * np.abs(log2_fcs)))[: min(8, len(rows))]
        vol_candidates = [
            (
                float(log2_fcs[i]),
                float(neg_log10_sig[i]),
                rows[i].display_label,
                color_up if log2_fcs[i] >= 0 else color_down,
            )
            for i in ranked_all
        ]
        ma_candidates = [
            (
                float(mean_signals[i]),
                float(log2_fcs[i]),
                rows[i].display_label,
                color_up if log2_fcs[i] >= 0 else color_down,
            )
            for i in ranked_all
        ]
    else:
        half_n = max(top_n_labels // 2, 4)
        top_up = sorted(up_indices, key=lambda i: (sig_vals[i], - abs(log2_fcs[i])))[:half_n]
        top_down = sorted(down_indices, key=lambda i: (sig_vals[i], -abs(log2_fcs[i])))[:half_n]
        vol_candidates = [
            (float(log2_fcs[i]), float(neg_log10_sig[i]), rows[i].display_label, color_up) for i in top_up
        ] + [
            (float(log2_fcs[i]), float(neg_log10_sig[i]), rows[i].display_label, color_down) for i in top_down
        ]
        ma_candidates = [
            (float(mean_signals[i]), float(log2_fcs[i]), rows[i].display_label, color_up) for i in top_up
        ] + [
            (float(mean_signals[i]), float(log2_fcs[i]), rows[i].display_label, color_down) for i in top_down
        ]

    max_abs_fc = max(float(np.max(np.abs(log2_fcs))) * 1.22, log2fc_threshold * 1.8, 2.5)
    max_y = max(float(np.max(neg_log10_sig)) * 1.22, y_thresh * 1.4, 2.0)

    annotate_top_points(ax_vol, vol_candidates, x_span=2.0 * max_abs_fc, y_span=max_y)

    ax_vol.set_xlim(-max_abs_fc, max_abs_fc)
    ax_vol.set_ylim(-0.04 * max_y, max_y)

    ax_vol.set_title(f"A. Volcano Plot ({treatment} vs. {background})")
    ax_vol.set_xlabel(f"Log2 Fold Change  [ ← Higher in {background} | Higher in {treatment} → ]")
    ax_vol.set_ylabel(f"-log10({metric_label})")
    ax_vol.grid(True, linestyle=":", alpha=0.45, zorder=0)
    ax_vol.legend(
        title=f"Thresholds: {short_metric} < {fdr_threshold}, |log2FC| ≥ {log2fc_threshold}",
        frameon=True,
        facecolor="white",
        edgecolor="#CCCCCC",
        loc="upper right",
    )
    despine_axis(ax_vol)

    # =========================================================================
    # Panel B: MA Plot (Mean Log2 Signal vs Log2 Fold Change)
    # =========================================================================
    ax_ma.scatter(
        mean_signals[ns_mask],
        log2_fcs[ns_mask],
        s=14,
        color=color_ns,
        alpha=0.45,
        edgecolors="none",
        label=f"Not Significant ({n_ns:,})",
        zorder=2,
    )
    ax_ma.scatter(
        mean_signals[down_mask],
        log2_fcs[down_mask],
        s=24,
        color=color_down,
        alpha=0.80,
        edgecolors="none",
        label=f"Higher in {background} ({n_down:,})",
        zorder=3,
    )
    ax_ma.scatter(
        mean_signals[up_mask],
        log2_fcs[up_mask],
        s=24,
        color=color_up,
        alpha=0.80,
        edgecolors="none",
        label=f"Higher in {treatment} ({n_up:,})",
        zorder=3,
    )

    ax_ma.axhline(0.0, color="#222222", linestyle="-", linewidth=1.0, zorder=4)
    ax_ma.axhline(log2fc_threshold, color="#444444", linestyle="--", linewidth=1.0, zorder=4)
    ax_ma.axhline(-log2fc_threshold, color="#444444", linestyle="--", linewidth=1.0, zorder=4)

    ma_x_span = max(float(np.ptp(mean_signals)), 4.0)
    annotate_top_points(ax_ma, ma_candidates, x_span=ma_x_span, y_span=2.0 * max_abs_fc)

    ax_ma.set_xlim(float(np.min(mean_signals)) - ma_x_span * 0.12, float(np.max(mean_signals)) + ma_x_span * 0.15)
    ax_ma.set_ylim(-max_abs_fc, max_abs_fc)
    ax_ma.set_title(f"B. MA Plot — Signal Intensity vs. Fold Change")
    ax_ma.set_xlabel("Mean Normalized Signal: 0.5 × [log2(Treatment + 1) + log2(Background + 1)]")
    ax_ma.set_ylabel(f"Log2 Fold Change ({treatment} / {background})")
    ax_ma.grid(True, linestyle=":", alpha=0.45, zorder=0)
    ax_ma.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="upper right")
    despine_axis(ax_ma)

    target_str = f" [{target}]" if target else ""
    fig.suptitle(f"Differential Peak Analysis: {contrast_id}{target_str}", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, out_prefix)


def main() -> None:
    args = parse_args()
    contrast_id = args.contrast_id or re.sub(r"_differential_peaks\.txt$", "", args.diff_file.name)
    treatment, background = infer_contrast_labels(contrast_id, args.treatment, args.background)
    out_prefix = args.out_prefix or Path(f"{contrast_id}_volcano_ma")

    rows = parse_homer_differential_table(args.diff_file)
    render_volcano_and_ma(
        rows=rows,
        contrast_id=contrast_id,
        treatment=treatment,
        background=background,
        target=args.target,
        fdr_threshold=args.fdr_threshold,
        log2fc_threshold=args.log2fc_threshold,
        top_n_labels=args.top_n_labels,
        out_prefix=out_prefix,
    )


if __name__ == "__main__":
    main()
