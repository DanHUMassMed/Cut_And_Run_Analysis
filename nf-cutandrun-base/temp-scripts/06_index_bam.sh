#!/usr/bin/env bash

set -e

# ---- CONFIG ----
RESULTS_DIR="./results/06_index_bam"

mkdir -p "$RESULTS_DIR"

# ---- INPUT ----
SAM_IN="$1"

# ---- CHECK ----
if [[ -z "$SAM_IN" ]]; then
  echo "Usage: $0 <input.malqfilt.sam>"
  exit 1
fi

if [[ ! -f "$SAM_IN" ]]; then
  echo "ERROR: Input SAM not found: $SAM_IN"
  exit 1
fi

# ---- DERIVE SAMPLE NAME ----
BASE=$(basename "$SAM_IN")
BASE=${BASE%.sam}
SAMPLE=${BASE%_PicardDedup_mapqfilt}

# ---- OUTPUT ----
BAM_OUT="${RESULTS_DIR}/${SAMPLE}.bam"
BW_OUT="${RESULTS_DIR}/${SAMPLE}.bw"

# ---- LOAD MODULE ----
module load samtools/1.16.1
module load deeptools/3.5.6

# ---- RUN FILTER ----
echo "Index Bam for $SAMPLE..."

samtools view -bh "$SAM_IN" > "$BAM_OUT"
samtools index "$BAM_OUT"
bamCoverage -b "$BAM_OUT" --normalizeUsing RPKM -o "$BW_OUT"

echo "Filtering complete for $SAMPLE"
echo "Output:"
echo "  $SAM_OUT"
