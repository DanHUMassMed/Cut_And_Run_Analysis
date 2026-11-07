#!/usr/bin/env bash

set -e

# ---- CONFIG ----
RESULTS_DIR="./results/05_mapq_filter"
MAPQ=10

mkdir -p "$RESULTS_DIR"

# ---- INPUT ----
BAM_IN="$1"

# ---- CHECK ----
if [[ -z "$BAM_IN" ]]; then
  echo "Usage: $0 <input_dedup.bam>"
  exit 1
fi

if [[ ! -f "$BAM_IN" ]]; then
  echo "ERROR: Input BAM not found: $BAM_IN"
  exit 1
fi

# ---- DERIVE SAMPLE NAME ----
BASE=$(basename "$BAM_IN")
BASE=${BASE%.bam}
SAMPLE=${BASE%_PicardDedup}

# ---- OUTPUT ----
SAM_OUT="${RESULTS_DIR}/${SAMPLE}_PicardDedup_mapqfilt.sam"

# ---- LOAD MODULE ----
module load samtools/1.16.1

# ---- RUN FILTER ----
echo "Filtering low-quality reads (MAPQ < $MAPQ) for $SAMPLE..."

samtools view -h -q "$MAPQ" "$BAM_IN" > "$SAM_OUT"

echo "Filtering complete for $SAMPLE"
echo "Output:"
echo "  $SAM_OUT"