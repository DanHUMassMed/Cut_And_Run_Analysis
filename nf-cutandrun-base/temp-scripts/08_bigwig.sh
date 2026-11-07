#!/usr/bin/env bash

set -e

# ---- CONFIG ----
RESULTS_DIR="./results/08_bigwig"
CHROM_SIZES="${2:-${CHROM_SIZES:-/share/data/umw_biocore/genome_data/c_elegans/ce11_ws245/ce11_ws245.chrom.sizes}}"

mkdir -p "$RESULTS_DIR"

# ---- INPUT ----
INPUT="$1"

# ---- CHECK ----
if [[ -z "$INPUT" ]]; then
  echo "Usage: $0 <input.bedGraph[.gz] | sample_dir | sample_name> [chrom_sizes]"
  exit 1
fi

# ---- RESOLVE INPUT & SAMPLE NAME ----
if [[ -f "$INPUT" ]]; then
  BG_FILE="$INPUT"
  BASE=$(basename "$BG_FILE")
  BASE=${BASE%.gz}
  BASE=${BASE%.bedgraph}
  BASE=${BASE%.bedGraph}
  SAMPLE=${BASE%.ucsc}
elif [[ -d "$INPUT" ]]; then
  SAMPLE=$(basename "$INPUT")
  BG_FILE=$(ls "$INPUT"/*.bedGraph.gz "$INPUT"/*.bedGraph 2>/dev/null | head -n 1)
  if [[ -z "$BG_FILE" || ! -f "$BG_FILE" ]]; then
    echo "ERROR: No bedGraph[.gz] file found in directory: $INPUT"
    exit 1
  fi
else
  # Treat as sample name
  SAMPLE="$INPUT"
  TAG_DIR="./results/07_ucsc/${SAMPLE}"
  BG_FILE=$(ls "$TAG_DIR"/*.bedGraph.gz "$TAG_DIR"/*.bedGraph 2>/dev/null | head -n 1)
  if [[ -z "$BG_FILE" || ! -f "$BG_FILE" ]]; then
    echo "ERROR: bedGraph[.gz] file not found for sample $SAMPLE in $TAG_DIR"
    exit 1
  fi
fi

if [[ ! -f "$CHROM_SIZES" ]]; then
  echo "ERROR: Chromosome sizes file not found: $CHROM_SIZES"
  echo "Please specify a valid chrom.sizes file as argument 2 or set CHROM_SIZES env var."
  exit 1
fi

# ---- OUTPUT FILES ----
BIGWIG_OUT="${RESULTS_DIR}/${SAMPLE}.bw"
UNZIPPED_BG="${RESULTS_DIR}/${SAMPLE}.temp.bedGraph"

# Clean up temporary bedGraph on exit
trap 'rm -f "$UNZIPPED_BG"' EXIT

# ---- LOAD MODULES ----
module load ucsc_utilities/20240312

# ---- FORMAT BEDGRAPH & GENERATE BIGWIG ----
echo "Decompressing and formatting bedGraph for sample: $SAMPLE..."
echo "Source: $BG_FILE"

# Remove comments (#) and track lines, sort by chrom and start position
if [[ "$BG_FILE" =~ \.gz$ ]]; then
  gzip -dc "$BG_FILE"
else
  cat "$BG_FILE"
fi | grep -v '^#' | grep -v '^track' | sort -k1,1 -k2,2n > "$UNZIPPED_BG"

echo "Generating BigWig: $BIGWIG_OUT"
bedGraphToBigWig "$UNZIPPED_BG" "$CHROM_SIZES" "$BIGWIG_OUT"

echo "BigWig conversion complete for $SAMPLE"
echo "Output:"
echo "  $BIGWIG_OUT"
