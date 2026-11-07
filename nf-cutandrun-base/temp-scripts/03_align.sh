#!/usr/bin/env bash

set -e

# ---- CONFIG ----
BOWTIE2_INDEX="/share/data/umw_biocore/genome_data/c_elegans/ce11_ws245/ce11_ws245"
RESULTS_DIR="./results/03_align"
mkdir -p "$RESULTS_DIR"

# ---- INPUT FILES ----
R1="$1"
R2="$2"

# ---- CHECK INPUTS ----
if [[ -z "$R1" || -z "$R2" ]]; then
  echo "Usage: $0 <R1_paired.fq.gz> <R2_paired.fq.gz>"
  exit 1
fi

if [[ ! -f "$R1" ]]; then
  echo "ERROR: File not found: $R1"
  exit 1
fi

if [[ ! -f "$R2" ]]; then
  echo "ERROR: File not found: $R2"
  exit 1
fi

# ---- DERIVE SAMPLE NAME ----
BASE_R1=$(basename "$R1")
BASE_R1=${BASE_R1%.fastq.gz}
BASE_R1=${BASE_R1%.fq.gz}
SAMPLE=${BASE_R1%.paired.trim_1*}

# ---- OUTPUT FILE ----
SAM_OUT="${RESULTS_DIR}/${SAMPLE}_bowtieoutput.sam"

# ---- LOAD MODULES ----
module load bowtie2/2.5.0
module load samtools/1.16.1

# ---- RUN ALIGNMENT ----
echo "Running Bowtie2 alignment for sample: $SAMPLE"
echo "Input: $R1, $R2"
echo "Output: $SAM_OUT"

bowtie2 -q \
  --very-sensitive \
  -N 0 \
  -X 500 \
  -p 16 \
  -x "$BOWTIE2_INDEX" \
  -1 "$R1" -2 "$R2" \
  -S "$SAM_OUT"

echo "Alignment complete for $SAMPLE"