#!/usr/bin/env bash

set -e

# ---- CONFIG ----
PICARD_JAR="/pi/thomas.fazzio-umw/Sarah/picard-tools-2.5.0/picard.jar"
RESULTS_DIR="./results/04_dedup"
TMP_DIR="/tmp"

mkdir -p "$RESULTS_DIR"

# ---- INPUT ----
SAM_IN="$1"

# ---- CHECK ----
if [[ -z "$SAM_IN" ]]; then
  echo "Usage: $0 <input.sam>"
  exit 1
fi

if [[ ! -f "$SAM_IN" ]]; then
  echo "ERROR: Input SAM not found: $SAM_IN"
  exit 1
fi

if [[ ! -f "$PICARD_JAR" ]]; then
  echo "ERROR: Picard jar not found: $PICARD_JAR"
  exit 1
fi

# ---- DERIVE SAMPLE NAME ----
BASE=$(basename "$SAM_IN")
BASE=${BASE%.sam}
SAMPLE=${BASE%_bowtieoutput}

# ---- OUTPUT FILES ----
SORTED_BAM="${RESULTS_DIR}/${SAMPLE}_PicardSort.bam"
DEDUP_BAM="${RESULTS_DIR}/${SAMPLE}_PicardDedup.bam"
METRICS="${RESULTS_DIR}/${SAMPLE}_dup.txt"

# ---- LOAD MODULES ----
module load samtools/1.16.1

# ---- SORT SAM → BAM ----
echo "Sorting SAM for $SAMPLE..."

java -Xmx4g -jar "$PICARD_JAR" \
  SortSam \
  INPUT="$SAM_IN" \
  OUTPUT="$SORTED_BAM" \
  VALIDATION_STRINGENCY=LENIENT \
  TMP_DIR="$TMP_DIR" \
  SORT_ORDER=coordinate

# ---- MARK / REMOVE DUPLICATES ----
echo "Removing duplicates for $SAMPLE..."

java -Xmx4g -jar "$PICARD_JAR" \
  MarkDuplicates \
  INPUT="$SORTED_BAM" \
  OUTPUT="$DEDUP_BAM" \
  VALIDATION_STRINGENCY=LENIENT \
  TMP_DIR="$TMP_DIR" \
  METRICS_FILE="$METRICS" \
  REMOVE_DUPLICATES=true

echo "Duplicate removal complete for $SAMPLE"
echo "Output:"
echo "  $DEDUP_BAM"
echo "  $METRICS"