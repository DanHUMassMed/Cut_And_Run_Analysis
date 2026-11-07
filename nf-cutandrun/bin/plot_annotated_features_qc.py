#!/usr/bin/env python3
"""Plots 2, 3, & 4 from 11_peak_quantification/<target>_annotated_peaks.txt:
- Plot 2: Genomic Feature Breakdown (Bar + Donut + Distance to TSS Histogram)
- Plot 3: Sample Correlation Heatmap & 2D PCA Scatter Plot
- Plot 4: Signal Distribution (Tag Count & Tags/kb) & Peak Width Violin/Box Plots
"""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from scipy.cluster.hierarchy import leaves_list, linkage
from scipy.spatial.distance import squareform

from cutandrun_plot_utils import (
    FEATURE_COLORS,
    FEATURE_ORDER,
    HomerAnnotatedTable,
    build_condition_color_map,
    configure_matplotlib_style,
    despine_axis,
    load_samplesheet,
    parse_homer_annotated_table,
    save_dual_figure,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Genomic Feature Breakdown (Plot 2), Sample Correlation/PCA (Plot 3), and Signal/Width Violin Plots (Plot 4)."
    )
    parser.add_argument("--annotated-peaks", type=Path, required=True, help="HOMER <target>_annotated_peaks.txt")
    parser.add_argument("--samplesheet", type=Path, required=False, default=None, help="Path to samplesheet.csv")
    parser.add_argument("--target", type=str, required=False, default=None, help="Target name (e.g. H3K4me3)")
    parser.add_argument("--outdir", type=Path, default=Path("."), help="Output directory")
    return parser.parse_args()


# =============================================================================
# Plot 2: Genomic Feature Breakdown & Distance to TSS
# =============================================================================
def generate_plot2_genomic_features(table: HomerAnnotatedTable, outdir: Path) -> None:
    configure_matplotlib_style()
    counts = Counter(row.annotation_category for row in table.rows)
    total = max(table.num_peaks, 1)

    ordered_cats = [cat for cat in FEATURE_ORDER if counts.get(cat, 0) > 0]
    if not ordered_cats:
        ordered_cats = ["Other / Unannotated"]

    tsv_path = outdir / f"{table.target}_genomic_features.tsv"
    tsv_path.parent.mkdir(parents=True, exist_ok=True)
    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write("Target\tGenomic_Feature\tPeak_Count\tPercentage\n")
        for cat in FEATURE_ORDER:
            cnt = counts.get(cat, 0)
            pct = (cnt / total) * 100.0 if table.num_peaks > 0 else 0.0
            handle.write(f"{table.target}\t{cat}\t{cnt}\t{pct:.2f}\n")

    fig, axes = plt.subplots(1, 3, figsize=(16.5, 5.2), gridspec_kw={"width_ratios": [1.25, 1.05, 1.2]})
    ax_bar, ax_donut, ax_tss = axes

    # Panel A: Horizontal Bar Chart sorted by count
    sorted_cats = sorted(ordered_cats, key=lambda c: counts[c], reverse=False)
    y_pos = np.arange(len(sorted_cats))
    bar_vals = [counts[c] for c in sorted_cats]
    bar_colors = [FEATURE_COLORS.get(c, "#999999") for c in sorted_cats]

    bars = ax_bar.barh(y_pos, bar_vals, color=bar_colors, edgecolor="#222222", linewidth=0.7, height=0.68, zorder=3)
    max_bar = max(bar_vals, default=1)
    for bar, cnt in zip(bars, bar_vals):
        pct = (cnt / total) * 100.0
        ax_bar.text(
            bar.get_width() + max_bar * 0.02,
            bar.get_y() + bar.get_height() / 2.0,
            f"{cnt:,} ({pct:.1f}%)",
            va="center",
            ha="left",
            fontsize=8.5,
            fontweight="bold",
            color="#222222",
        )

    ax_bar.set_yticks(y_pos)
    ax_bar.set_yticklabels(sorted_cats)
    ax_bar.set_xlabel("Number of Peaks")
    ax_bar.set_xlim(0, max_bar * 1.32)
    ax_bar.set_title(f"A. {table.target} Peaks by Genomic Region")
    ax_bar.xaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_bar)

    # Panel B: Donut Chart
    donut_cats = sorted(ordered_cats, key=lambda c: counts[c], reverse=True)
    donut_vals = [counts[c] for c in donut_cats]
    donut_colors = [FEATURE_COLORS.get(c, "#999999") for c in donut_cats]

    wedges, _ = ax_donut.pie(
        donut_vals,
        colors=donut_colors,
        startangle=140,
        counterclock=False,
        wedgeprops={"width": 0.44, "edgecolor": "white", "linewidth": 1.5},
    )
    ax_donut.text(
        0,
        0,
        f"{table.num_peaks:,}\nMaster Peaks",
        ha="center",
        va="center",
        fontsize=10,
        fontweight="bold",
        color="#222222",
    )
    legend_labels = [f"{c} ({(counts[c] / total) * 100.0:.1f}%)" for c in donut_cats]
    ax_donut.legend(
        wedges,
        legend_labels,
        loc="center left",
        bbox_to_anchor=(0.92, 0.5),
        frameon=False,
        fontsize=8.5,
    )
    ax_donut.set_title(f"B. {table.target} Feature Proportions")

    # Panel C: Distance to TSS Histogram (-5 kb to +5 kb)
    tss_dists = [
        row.distance_to_tss / 1000.0
        for row in table.rows
        if row.distance_to_tss is not None and -5000 <= row.distance_to_tss <= 5000
    ]
    if tss_dists:
        ax_tss.hist(
            tss_dists,
            bins=50,
            range=(-5.0, 5.0),
            color="#0072B2",
            edgecolor="white",
            linewidth=0.4,
            alpha=0.85,
            zorder=3,
        )
        ax_tss.axvline(0.0, color="#D55E00", linestyle="--", linewidth=1.3, label="TSS (0 kb)", zorder=4)
        ax_tss.axvspan(-0.5, 0.5, color="#D55E00", alpha=0.12, label="Promoter (±0.5 kb)", zorder=2)
        ax_tss.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="upper right", fontsize=8.5)
    else:
        ax_tss.text(0.5, 0.5, "No peaks within ±5 kb of TSS", ha="center", va="center")

    ax_tss.set_title(f"C. {table.target} Peak Distance to Nearest TSS")
    ax_tss.set_xlabel("Distance to Nearest TSS (kb)")
    ax_tss.set_ylabel("Number of Peaks")
    ax_tss.set_xlim(-5.0, 5.0)
    ax_tss.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_tss)

    fig.suptitle(f"Genomic Feature Breakdown & TSS Proximity — {table.target}", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, outdir / f"{table.target}_genomic_features")


# =============================================================================
# Plot 3: Sample Correlation Heatmap & PCA Plot
# =============================================================================
def generate_plot3_correlation_and_pca(table: HomerAnnotatedTable, outdir: Path) -> None:
    configure_matplotlib_style()
    mat = table.tag_matrix()
    log2_mat = np.log2(np.maximum(mat, 0.0) + 1.0)
    n_samples = table.num_samples
    sample_names = table.sample_names

    if n_samples >= 2 and log2_mat.shape[0] >= 2:
        corr_matrix = np.corrcoef(log2_mat, rowvar=False)
        corr_matrix = np.nan_to_num(corr_matrix, nan=0.0)
        np.fill_diagonal(corr_matrix, 1.0)
    else:
        corr_matrix = np.ones((max(n_samples, 1), max(n_samples, 1)), dtype=np.float64)

    # Hierarchical clustering order when >= 3 samples
    order = list(range(n_samples))
    if n_samples >= 3:
        dist_mat = np.clip(1.0 - corr_matrix, 0.0, 2.0)
        np.fill_diagonal(dist_mat, 0.0)
        condensed = squareform(dist_mat, checks=False)
        if np.any(condensed > 0):
            z_link = linkage(condensed, method="average")
            order = list(leaves_list(z_link))

    ordered_names = [sample_names[i] for i in order]
    ordered_corr = corr_matrix[np.ix_(order, order)]

    # Save correlation TSV
    tsv_path = outdir / f"{table.target}_correlation_matrix.tsv"
    tsv_path.parent.mkdir(parents=True, exist_ok=True)
    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write("Sample\t" + "\t".join(ordered_names) + "\n")
        for s_name, row_vals in zip(ordered_names, ordered_corr):
            vals_str = "\t".join(f"{v:.4f}" for v in row_vals)
            handle.write(f"{s_name}\t{vals_str}\n")

    fig, axes = plt.subplots(1, 2, figsize=(13.5, 5.6), gridspec_kw={"width_ratios": [1.05, 1.15]})
    ax_heat, ax_pca = axes

    # Panel A: Correlation Heatmap
    vmin = max(float(np.min(ordered_corr)) - 0.05, 0.0) if ordered_corr.size > 0 else 0.0
    if vmin > 0.85:
        vmin = 0.80
    im = ax_heat.imshow(ordered_corr, cmap="YlGnBu", vmin=vmin, vmax=1.0, aspect="equal")
    cbar = fig.colorbar(im, ax=ax_heat, fraction=0.046, pad=0.04)
    cbar.set_label("Pearson Correlation (r) on log2(Tag Count + 1)", fontsize=9)

    ax_heat.set_xticks(np.arange(len(ordered_names)))
    ax_heat.set_yticks(np.arange(len(ordered_names)))
    ax_heat.set_xticklabels(ordered_names, rotation=30, ha="right")
    ax_heat.set_yticklabels(ordered_names)

    for i in range(len(ordered_names)):
        for j in range(len(ordered_names)):
            val = ordered_corr[i, j]
            text_color = "white" if val > (vmin + (1.0 - vmin) * 0.62) else "#111111"
            ax_heat.text(
                j,
                i,
                f"{val:.3f}",
                ha="center",
                va="center",
                color=text_color,
                fontsize=9.5,
                fontweight="bold",
            )

    ax_heat.set_title(f"A. {table.target} Sample Correlation Heatmap")

    # Panel B: 2D PCA Scatter Plot across samples
    # Transpose to (N_samples, N_peaks)
    sample_feature_mat = log2_mat.T
    if n_samples >= 2 and sample_feature_mat.shape[1] >= 2:
        centered = sample_feature_mat - np.mean(sample_feature_mat, axis=0, keepdims=True)
        # If n_samples == 2, mean-centering across 2 samples leaves rank 1 (PC2 = 0).
        # For 2 samples, standardize across peaks per sample or include uncentered 2nd singular vector
        # so both PC1 (difference between conditions) and PC2 (shared signal axis) are informative.
        u_mat, s_vals, _ = np.linalg.svd(centered, full_matrices=False)
        var_explained = (s_vals**2) / max(float(np.sum(s_vals**2)), 1e-12) * 100.0
        scores = u_mat * s_vals

        pc1 = scores[:, 0]
        if scores.shape[1] >= 2 and var_explained[1] > 1e-4:
            pc2 = scores[:, 1]
            pc2_var = var_explained[1]
            pc2_label = f"PC2 ({pc2_var:.1f}% variance)"
        else:
            # When only 2 samples exist, use mean sample log2 signal as the vertical axis
            pc2 = np.mean(sample_feature_mat, axis=1)
            pc2_label = "Mean Sample Signal log2(Tags + 1)"

        pc1_var = var_explained[0]
        cond_colors = build_condition_color_map(table.sample_conditions)

        plotted_conds: set[str] = set()
        for idx in range(n_samples):
            cond = table.sample_conditions[idx]
            label = cond if cond not in plotted_conds else None
            plotted_conds.add(cond)
            ax_pca.scatter(
                pc1[idx],
                pc2[idx],
                s=130,
                color=cond_colors[cond],
                edgecolor="#111111",
                linewidth=1.1,
                label=label,
                zorder=4,
            )
            ax_pca.annotate(
                sample_names[idx],
                (pc1[idx], pc2[idx]),
                xytext=(8, 7),
                textcoords="offset points",
                fontsize=9,
                fontweight="bold",
                color="#222222",
                bbox={"boxstyle": "round,pad=0.2", "fc": "white", "ec": "#DDDDDD", "alpha": 0.85},
                zorder=5,
            )

        x_span = max(float(np.ptp(pc1)), 1.0)
        y_span = max(float(np.ptp(pc2)), 0.5)
        ax_pca.set_xlim(float(np.min(pc1)) - x_span * 0.28, float(np.max(pc1)) + x_span * 0.35)
        ax_pca.set_ylim(float(np.min(pc2)) - y_span * 0.28, float(np.max(pc2)) + y_span * 0.28)
        ax_pca.axhline(float(np.mean(pc2)), color="#888888", linestyle=":", linewidth=0.9, zorder=1)
        ax_pca.axvline(0.0, color="#888888", linestyle=":", linewidth=0.9, zorder=1)
        ax_pca.set_xlabel(f"PC1 ({pc1_var:.1f}% variance)")
        ax_pca.set_ylabel(pc2_label)
        ax_pca.grid(True, linestyle=":", alpha=0.5, zorder=0)
        ax_pca.legend(title="Condition", frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="best")
    else:
        ax_pca.text(0.5, 0.5, "At least 2 samples required for PCA", ha="center", va="center")

    ax_pca.set_title(f"B. {table.target} Principal Component Analysis (PCA)")
    despine_axis(ax_pca)

    fig.suptitle(f"Sample Correlation & PCA Clustering — {table.target}", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, outdir / f"{table.target}_correlation_pca")


# =============================================================================
# Plot 4: Signal Distribution & Peak Width Violin/Box Plots
# =============================================================================
def generate_plot4_signal_and_width(table: HomerAnnotatedTable, outdir: Path) -> None:
    configure_matplotlib_style()
    tag_mat = table.tag_matrix()
    tpk_mat = table.tags_per_kb_matrix()
    widths_bp = table.widths_bp()

    log2_tags = np.log2(np.maximum(tag_mat, 0.0) + 1.0)
    log2_tpk = np.log2(np.maximum(tpk_mat, 0.0) + 1.0)

    # Write summary statistics TSV
    tsv_path = outdir / f"{table.target}_signal_summary_stats.tsv"
    tsv_path.parent.mkdir(parents=True, exist_ok=True)
    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write(
            "Target\tSample_Name\tCondition\tNum_Peaks\tMedian_Tag_Count\tIQR_Tag_Count\t"
            "Median_Tags_Per_Kb\tIQR_Tags_Per_Kb\tMedian_Peak_Width_bp\n"
        )
        med_width = float(np.median(widths_bp)) if widths_bp.size > 0 else 0.0
        for idx, s_name in enumerate(table.sample_names):
            cond = table.sample_conditions[idx]
            col_tags = tag_mat[:, idx] if tag_mat.size > 0 else np.zeros(1)
            col_tpk = tpk_mat[:, idx] if tpk_mat.size > 0 else np.zeros(1)
            q25_t, med_t, q75_t = np.percentile(col_tags, [25, 50, 75])
            q25_k, med_k, q75_k = np.percentile(col_tpk, [25, 50, 75])
            handle.write(
                f"{table.target}\t{s_name}\t{cond}\t{table.num_peaks}\t"
                f"{med_t:.2f}\t{(q75_t - q25_t):.2f}\t{med_k:.2f}\t{(q75_k - q25_k):.2f}\t{med_width:.0f}\n"
            )

    fig, axes = plt.subplots(1, 3, figsize=(16.5, 5.4), gridspec_kw={"width_ratios": [1.15, 1.15, 1.0]})
    ax_raw, ax_norm, ax_width = axes

    cond_colors = build_condition_color_map(table.sample_conditions)
    sample_colors = [cond_colors[c] for c in table.sample_conditions]
    positions = np.arange(1, table.num_samples + 1)

    def draw_violin_and_box(ax: plt.Axes, data_matrix: np.ndarray, title: str, ylabel: str) -> None:
        if data_matrix.size == 0 or table.num_samples == 0:
            ax.text(0.5, 0.5, "No signal data available", ha="center", va="center")
            return
        cols = [data_matrix[:, i] for i in range(table.num_samples)]
        parts = ax.violinplot(cols, positions=positions, widths=0.65, showmeans=False, showextrema=False, showmedians=False)
        for pc, color in zip(parts["bodies"], sample_colors):
            pc.set_facecolor(color)
            pc.set_edgecolor("#222222")
            pc.set_alpha(0.65)
            pc.set_linewidth(0.8)

        ax.boxplot(
            cols,
            positions=positions,
            widths=0.18,
            patch_artist=True,
            showfliers=False,
            boxprops={"facecolor": "white", "edgecolor": "#111111", "linewidth": 1.0},
            medianprops={"color": "#D55E00", "linewidth": 2.0},
            whiskerprops={"color": "#111111", "linewidth": 1.0},
            capprops={"color": "#111111", "linewidth": 1.0},
        )
        for pos, col in zip(positions, cols):
            med_val = float(np.median(col))
            ax.text(
                pos,
                med_val,
                f" {med_val:.2f}",
                va="center",
                ha="left",
                fontsize=8,
                fontweight="bold",
                color="#111111",
                bbox={"boxstyle": "round,pad=0.15", "fc": "white", "ec": "none", "alpha": 0.75},
            )

        ax.set_xticks(positions)
        ax.set_xticklabels(table.sample_names, rotation=22, ha="right")
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
        despine_axis(ax)

    draw_violin_and_box(
        ax_raw,
        log2_tags,
        f"A. {table.target} Normalized Signal per Peak",
        "log2(Normalized Tag Count + 1)",
    )
    draw_violin_and_box(
        ax_norm,
        log2_tpk,
        f"B. {table.target} Length-Normalized Signal Density",
        "log2(Tags per kb + 1)",
    )

    # Panel C: Master Peak Width Distribution
    if widths_bp.size > 0:
        log10_w = np.log10(np.maximum(widths_bp, 1))
        ax_width.hist(
            log10_w,
            bins=40,
            color="#009E73",
            edgecolor="white",
            linewidth=0.4,
            alpha=0.85,
            zorder=3,
        )
        q25_w, med_w, q75_w = np.percentile(widths_bp, [25, 50, 75])
        ax_width.axvline(
            np.log10(med_w),
            color="#D55E00",
            linestyle="--",
            linewidth=1.5,
            label=f"Median: {med_w:,.0f} bp\nIQR: {q25_w:,.0f}–{q75_w:,.0f} bp",
            zorder=4,
        )
        tick_bp = [100, 250, 500, 1000, 2500, 5000, 10000]
        ax_width.set_xticks([np.log10(x) for x in tick_bp])
        ax_width.set_xticklabels([f"{x:,}" for x in tick_bp], rotation=25, ha="right")
        ax_width.legend(frameon=True, facecolor="white", edgecolor="#CCCCCC", loc="upper right")
    else:
        ax_width.text(0.5, 0.5, "No peaks available", ha="center", va="center")

    ax_width.set_title(f"C. {table.target} Master Peak Widths")
    ax_width.set_xlabel("Peak Width (bp, log10 scale)")
    ax_width.set_ylabel("Number of Peaks")
    ax_width.yaxis.grid(True, linestyle=":", alpha=0.5, zorder=0)
    despine_axis(ax_width)

    fig.suptitle(f"Signal Intensity & Peak Width Distributions — {table.target}", y=1.03)
    fig.tight_layout()
    save_dual_figure(fig, outdir / f"{table.target}_signal_and_width_distributions")


def main() -> None:
    args = parse_args()
    samplesheet_map = load_samplesheet(args.samplesheet)
    table = parse_homer_annotated_table(
        table_path=args.annotated_peaks,
        samplesheet_map=samplesheet_map,
        target_override=args.target,
    )
    args.outdir.mkdir(parents=True, exist_ok=True)
    generate_plot2_genomic_features(table, args.outdir)
    generate_plot3_correlation_and_pca(table, args.outdir)
    generate_plot4_signal_and_width(table, args.outdir)


if __name__ == "__main__":
    main()

