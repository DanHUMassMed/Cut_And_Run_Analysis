#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

EXPERIMENT="$(sed -nE "s/^[[:space:]]*experiment[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" config/experiment.config | head -n 1)"
REMOTE_DIR="remote:Walker_lab_shared/Bioinformatics_parent/${EXPERIMENT}"
LOCAL_FASTQ_DIR="./data/fastq"

mkdir -p "${LOCAL_FASTQ_DIR}"
echo "Staging raw FASTQ files from ${REMOTE_DIR}/fastq to ${LOCAL_FASTQ_DIR}..."
rclone copy "${REMOTE_DIR}/fastq" "${LOCAL_FASTQ_DIR}" -P --transfers 4

