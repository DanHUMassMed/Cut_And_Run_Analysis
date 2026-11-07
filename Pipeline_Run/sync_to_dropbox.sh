#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

EXPERIMENT="$(sed -nE "s/^[[:space:]]*experiment[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" config/experiment.config | head -n 1)"
REMOTE_DIR="remote:Walker_lab_shared/Bioinformatics_parent/${EXPERIMENT}"
RESULTS_DIR="./results/${EXPERIMENT}"

if [[ ! -d "${RESULTS_DIR}" ]]; then
    echo "ERROR: Results directory not found: ${RESULTS_DIR}"
    exit 1
fi

echo "Syncing upstream results from ${RESULTS_DIR} to ${REMOTE_DIR}..."

[[ -d "${RESULTS_DIR}/01_trim" ]]        && rclone copy -P -vv "${RESULTS_DIR}/01_trim"        "${REMOTE_DIR}/01_trim/"        --include "*_paired.fq.gz"
[[ -d "${RESULTS_DIR}/02_fastqc" ]]      && rclone copy -P -vv "${RESULTS_DIR}/02_fastqc"      "${REMOTE_DIR}/02_fastqc/"      --include "**/*"
[[ -d "${RESULTS_DIR}/02_multiqc" ]]     && rclone copy -P -vv "${RESULTS_DIR}/02_multiqc"     "${REMOTE_DIR}/02_multiqc/"     --include "**/*"
[[ -d "${RESULTS_DIR}/03_align" ]]       && rclone copy -P -vv "${RESULTS_DIR}/03_align"       "${REMOTE_DIR}/03_align/"       --include "*.sam"
[[ -d "${RESULTS_DIR}/04_dedup" ]]       && rclone copy -P -vv "${RESULTS_DIR}/04_dedup"       "${REMOTE_DIR}/04_dedup/"       --include "*.txt"
[[ -d "${RESULTS_DIR}/05_mapq_filter" ]] && rclone copy -P -vv "${RESULTS_DIR}/05_mapq_filter" "${REMOTE_DIR}/05_mapq_filter/" --include "*.sam"
[[ -d "${RESULTS_DIR}/06_index_bam" ]]   && rclone copy -P -vv "${RESULTS_DIR}/06_index_bam"   "${REMOTE_DIR}/06_index_bam/"   --include "*.*"
[[ -d "${RESULTS_DIR}/07_ucsc" ]]        && rclone copy -P -vv "${RESULTS_DIR}/07_ucsc"        "${REMOTE_DIR}/07_ucsc/"        --include "**/*"
[[ -d "${RESULTS_DIR}/08_bigwig" ]]      && rclone copy -P -vv "${RESULTS_DIR}/08_bigwig"      "${REMOTE_DIR}/08_bigwig/"      --include "*.bw"

echo "Dropbox sync complete for ${EXPERIMENT}!"

