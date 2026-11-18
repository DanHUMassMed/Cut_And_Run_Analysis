#!/usr/bin/env bash
set -euo pipefail

# Peak_Count_by_Chromosome.sh
# Summarizes H3K4me3 peak counts per chromosome (with chrX percentage) for N2 and EV_INT.

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
        if [ -d "${d}/09_peaks" ]; then
            echo "${d}"
            return 0
        fi
    done
    return 1
}

if ! RESULTS_DIR="$(find_results_dir)"; then
    echo "Error: Could not locate results/cut_run103026B/09_peaks." >&2
    echo "Run from your Analysis_Run directory or ensure results/cut_run103026B exists." >&2
    exit 1
fi

summarize_bed() {
    local sample_id="$1"
    local sample_name="$2"
    local caller="$3"
    local bed_file="$4"

    echo "------------------------------------------------------------------------"
    echo "${sample_name} [${caller}] (sample_id: ${sample_id})"
    if [ ! -f "${bed_file}" ]; then
        echo "  (not found)"
        return 0
    fi

    awk '
        !/^#/ && !/^track/ && !/^browser/ && NF >= 3 {
            chr = $1
            counts[chr]++
            total++
        }
        END {
            if (total == 0) {
                print "  Total peaks: 0"
                exit
            }
            for (c in counts) {
                pct = (counts[c] / total) * 100.0
                printf "  %-8s %6d  (%5.1f%%)\n", c, counts[c], pct | "sort -k1,1"
            }
            close("sort -k1,1")
            chrx = counts["chrX"] + 0
            printf "  %-8s %6d  (chrX = %d / %d, %.1f%%)\n", "TOTAL", total, chrx, total, (chrx / total) * 100.0
        }
    ' "${bed_file}"
}

echo "========================================================================"
echo " H3K4me3 Peak Count by Chromosome (ce11)"
echo " Results: ${RESULTS_DIR}"
echo "========================================================================"

summarize_bed "L9254-0001-0004_S66_L008" "N2_H3K4me3"        "MACS2" "${RESULTS_DIR}/09_peaks/macs2/L9254-0001-0004_S66_L008_macs2_merge_ready_peaks.bed"
summarize_bed "L9254-0001-0004_S66_L008" "N2_H3K4me3"        "HOMER" "${RESULTS_DIR}/09_peaks/homer/L9254-0001-0004_S66_L008_homer_merge_ready_peaks.bed"
summarize_bed "L9254-0001-0001_S141_L004" "EV_INT_H3K4me3"   "MACS2" "${RESULTS_DIR}/09_peaks/macs2/L9254-0001-0001_S141_L004_macs2_merge_ready_peaks.bed"
summarize_bed "L9254-0001-0001_S141_L004" "EV_INT_H3K4me3"   "HOMER" "${RESULTS_DIR}/09_peaks/homer/L9254-0001-0001_S141_L004_homer_merge_ready_peaks.bed"
summarize_bed "L9254-0001-0006_S68_L008" "EV_INT_MC_H3K4me3" "MACS2" "${RESULTS_DIR}/09_peaks/macs2/L9254-0001-0006_S68_L008_macs2_merge_ready_peaks.bed"
summarize_bed "L9254-0001-0006_S68_L008" "EV_INT_MC_H3K4me3" "HOMER" "${RESULTS_DIR}/09_peaks/homer/L9254-0001-0006_S68_L008_homer_merge_ready_peaks.bed"
summarize_bed "H3K4me3_master"           "H3K4me3_Master"    "UNION" "${RESULTS_DIR}/10_merged_peaks/master/H3K4me3_master_peaks.bed"
