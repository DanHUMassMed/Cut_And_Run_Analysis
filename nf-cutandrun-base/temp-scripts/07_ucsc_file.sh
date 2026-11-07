#!/usr/bin/env bash

set -e

# ---- CONFIG ----
RESULTS_DIR="./results/07_ucsc"
mkdir -p "$RESULTS_DIR"

# ---- INPUT ----
SAM_IN="$1"

# ---- CHECK ----
if [[ -z "$SAM_IN" ]]; then
  echo "Usage: $0 <input_mapqfilt.sam>"
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

# ---- OUTPUT DIR ----
TAG_DIR="${RESULTS_DIR}/${SAMPLE}"
mkdir -p "$TAG_DIR"

# ---- LOAD MODULES ----
ml homer_env/4.11
export PATH=~/software/homer/bin:$PATH

module load samtools/1.16.1

# ---- RUN HOMER ----
echo "Creating HOMER tag directory for $SAMPLE..."

makeTagDirectory "$TAG_DIR" "$SAM_IN"

echo "Generating UCSC file for $SAMPLE..."

makeUCSCfile "$TAG_DIR" -o auto

echo "Done for $SAMPLE"
echo "Outputs:"
echo "  Tag Directory: $TAG_DIR"
echo "  UCSC files: inside $TAG_DIR"