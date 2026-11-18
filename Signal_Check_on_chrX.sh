#!/usr/bin/env bash
set -euo pipefail

# Signal_Check_on_chrX.sh
# Corroborates germline X-silencing vs. somatic X-expression in C. elegans (ce11):
#   1. H3K4me3 signal & peak density (chrX vs. Autosomes, All peaks & Promoter-TSS only)
#   2. Reciprocal H3K27me3 enrichment on chrX vs. Autosomes
#   3. Top N2_H3K4me3 Promoter-TSS peaks on chrX & differential chrX summary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_results_dir() {
    local candidates=(
        "${PWD}/results/cut_run103026B"
        "${SCRIPT_DIR}/results/cut_run103026B"
        "${SCRIPT_DIR}/../Experiment_Cut_Run_103026/Analysis_Run/results/cut_run103026B"
        "${SCRIPT_DIR}/docs/Example_Run/results/cut_run103026B"
    )
    local d
    for d in "${candidates[@]}"; do
        if [ -d "${d}/11_peak_quantification" ]; then
            echo "${d}"
            return 0
        fi
    done
    return 1
}

if ! RESULTS_DIR="$(find_results_dir)"; then
    echo "Error: Could not locate results/cut_run103026B/11_peak_quantification." >&2
    echo "Run from your Analysis_Run directory or ensure results/cut_run103026B exists." >&2
    exit 1
fi

export RESULTS_DIR

python3 - <<'PYEOF'
import os
import statistics
from pathlib import Path

results_dir = Path(os.environ["RESULTS_DIR"])
h3k4_path = results_dir / "11_peak_quantification" / "H3K4me3_annotated_peaks.txt"
h3k27_path = results_dir / "11_peak_quantification" / "H3K27me3_annotated_peaks.txt"
diff_path = results_dir / "12_differential_peaks" / "EV_INT_vs_N2_H3K4me3_differential_peaks.txt"

# ce11 chromosome lengths in Mb (from assets/homer_ce11/data/genomes/ce11/chrom.sizes)
CHROM_MB = {
    "chrI": 15.072434,
    "chrII": 15.279421,
    "chrIII": 13.783801,
    "chrIV": 17.493829,
    "chrV": 20.924180,
    "chrX": 17.718942,
    "chrM": 0.013794,
}
AUTOSOME_MB = sum(v for k, v in CHROM_MB.items() if k not in {"chrX", "chrM"})
CHRX_MB = CHROM_MB["chrX"]


def find_sample_cols(headers: list[str], sample_ids: dict[str, str]) -> dict[str, int]:
    found: dict[str, int] = {}
    for idx in range(19, len(headers)):
        col = headers[idx]
        if col.endswith("_per_kb"):
            continue
        for label, sid in sample_ids.items():
            if sid in col:
                found[label] = idx
    return found


def parse_annotated(path: Path, sample_ids: dict[str, str]):
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        header = []
        for line in fh:
            if line.startswith("#") and not line.startswith("#PeakID"):
                continue
            header = line.rstrip("\r\n").split("\t")
            break
        if not header:
            return {}, []
        cols = find_sample_cols(header, sample_ids)
        rows = []
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.rstrip("\r\n").split("\t")
            if len(parts) < 20:
                continue
            chrom = parts[1]
            ann = parts[7] if len(parts) > 7 else ""
            gene = parts[15].strip() if len(parts) > 15 else ""
            vals = {}
            for label, col_idx in cols.items():
                try:
                    vals[label] = float(parts[col_idx]) if col_idx < len(parts) else 0.0
                except ValueError:
                    vals[label] = 0.0
            rows.append({
                "chrom": chrom,
                "start": parts[2],
                "end": parts[3],
                "is_promoter": ann.lower().startswith("promoter-tss"),
                "gene": gene or "NA",
                "vals": vals,
            })
        return cols, rows


def print_region_summary(title: str, rows: list[dict], sample_labels: list[str], primary_label: str) -> None:
    print(f"\n--- {title} ---")
    header = f"{'Region':<12} {'Peaks':>7} {'Peaks/Mb':>9}"
    for lbl in sample_labels:
        header += f" {lbl+'_Mean':>12} {lbl+'_Med':>11}"
    print(header)

    region_stats = {}
    for region in ("chrX", "Autosomes"):
        sub = [
            r for r in rows
            if (r["chrom"] == "chrX") == (region == "chrX") and r["chrom"] != "chrM"
        ]
        mb = CHRX_MB if region == "chrX" else AUTOSOME_MB
        n = len(sub)
        density = n / mb if mb > 0 else 0.0
        line = f"{region:<12} {n:>7d} {density:>9.2f}"
        region_stats[region] = {}
        for lbl in sample_labels:
            arr = [r["vals"].get(lbl, 0.0) for r in sub]
            mean_v = statistics.mean(arr) if arr else 0.0
            med_v = statistics.median(arr) if arr else 0.0
            region_stats[region][lbl] = (mean_v, med_v)
            line += f" {mean_v:>12.2f} {med_v:>11.2f}"
        print(line)

    if primary_label in region_stats["chrX"] and primary_label in region_stats["Autosomes"]:
        x_mean, x_med = region_stats["chrX"][primary_label]
        a_mean, a_med = region_stats["Autosomes"][primary_label]
        r_mean = (x_mean / a_mean) if a_mean > 0 else 0.0
        r_med = (x_med / a_med) if a_med > 0 else 0.0
        print(f"  -> {primary_label} chrX / Autosomes ratio: Mean = {r_mean:.2f}x, Median = {r_med:.2f}x")


if not h3k4_path.exists():
    raise SystemExit(f"Error: Annotated peak table not found: {h3k4_path}")

print("========================================================================")
print(" H3K4me3 Signal Check on chrX vs. Autosomes (N2 vs. EV_INT)")
print("========================================================================")

h3k4_ids = {
    "N2": "L9254-0001-0004_S66_L008",
    "EV_INT": "L9254-0001-0001_S141_L004",
    "EV_MC": "L9254-0001-0006_S68_L008",
}
cols4, rows4 = parse_annotated(h3k4_path, h3k4_ids)
labels4 = [k for k in ("N2", "EV_INT", "EV_MC") if k in cols4]

print_region_summary("H3K4me3: All Master Peaks", rows4, labels4, "N2")
prom_rows4 = [r for r in rows4 if r["is_promoter"]]
print_region_summary("H3K4me3: Promoter-TSS Peaks Only", prom_rows4, labels4, "N2")

print("\n--- H3K4me3: Per-Chromosome Breakdown (All Peaks) ---")
p_hdr = f"{'Chrom':<10} {'Peaks':>7} {'Peaks/Mb':>9}"
for lbl in labels4:
    p_hdr += f" {lbl+'_Mean':>12} {lbl+'_Med':>11}"
print(p_hdr)
for chrom in sorted({r["chrom"] for r in rows4}):
    sub = [r for r in rows4 if r["chrom"] == chrom]
    mb = CHROM_MB.get(chrom, 0.0)
    dens = (len(sub) / mb) if mb > 0 else 0.0
    line = f"{chrom:<10} {len(sub):>7d} {dens:>9.2f}"
    for lbl in labels4:
        arr = [r["vals"].get(lbl, 0.0) for r in sub]
        line += f" {statistics.mean(arr):>12.2f} {statistics.median(arr):>11.2f}"
    print(line)

if "N2" in cols4:
    print("\n--- Top 15 N2_H3K4me3 Promoter-TSS Peaks on chrX (Somatic Activity) ---")
    chrx_prom = sorted(
        [r for r in prom_rows4 if r["chrom"] == "chrX"],
        key=lambda r: r["vals"].get("N2", 0.0),
        reverse=True,
    )[:15]
    print(f"{'Chrom':<8} {'Start':>10} {'End':>10} {'Gene':<16} {'N2_Tag':>10} {'EV_INT_Tag':>12}")
    for r in chrx_prom:
        print(
            f"{r['chrom']:<8} {r['start']:>10} {r['end']:>10} {r['gene']:<16} "
            f"{r['vals'].get('N2', 0.0):>10.2f} {r['vals'].get('EV_INT', 0.0):>12.2f}"
        )

if h3k27_path.exists():
    print("\n========================================================================")
    print(" Reciprocal Check: H3K27me3 Signal on chrX vs. Autosomes")
    print("========================================================================")
    h3k27_ids = {
        "N2": "L9254-0001-0005_S67_L008",
        "EV_INT": "L9254-0001-0002_S142_L004",
    }
    cols27, rows27 = parse_annotated(h3k27_path, h3k27_ids)
    labels27 = [k for k in ("N2", "EV_INT") if k in cols27]
    if labels27:
        print_region_summary("H3K27me3: All Master Peaks (Expect chrX >= Autosomes)", rows27, labels27, "N2")

if diff_path.exists():
    print("\n========================================================================")
    print(" Top chrX Peaks in Differential Table (EV_INT vs N2 H3K4me3)")
    print("========================================================================")
    with diff_path.open("r", encoding="utf-8", errors="replace") as fh:
        next(fh, None)
        print(f"{'Chrom':<10} {'Start':>10} {'End':>10} {'Gene':<16} {'log2FC':>9} {'p-value':>11} {'FDR':>11}")
        shown = 0
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.rstrip("\r\n").split("\t")
            if len(parts) < 22 or parts[1] != "chrX":
                continue
            gene = parts[15].strip() if len(parts) > 15 and parts[15].strip() else "NA"
            try:
                lfc = float(parts[-3])
                pval = float(parts[-2])
                fdr = float(parts[-1])
            except ValueError:
                continue
            print(f"{parts[1]:<10} {parts[2]:>10} {parts[3]:>10} {gene:<16} {lfc:>9.2f} {pval:>11.2e} {fdr:>11.2e}")
            shown += 1
            if shown >= 20:
                break
PYEOF
