#!/usr/bin/env bash

set -e

# ---- CONFIG ----
UCSC_DIR="./results/07_ucsc"
JOB_DIR="jobs/08_bigwig"
BIGWIG_SCRIPT="08_bigwig.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$UCSC_DIR" ]]; then
  echo "ERROR: UCSC results directory not found: $UCSC_DIR"
  exit 1
fi

if [[ ! -f "$BIGWIG_SCRIPT" ]]; then
  echo "ERROR: BigWig script not found: $BIGWIG_SCRIPT"
  exit 1
fi

# ---- FIND BEDGRAPH FILES ----
FOUND=0
for BG in "$UCSC_DIR"/*/*.bedGraph.gz "$UCSC_DIR"/*/*.bedGraph "$UCSC_DIR"/*.bedGraph.gz "$UCSC_DIR"/*.bedGraph; do
    # Handle no-match case
    if [[ ! -e "$BG" ]]; then
        continue
    fi

    FOUND=1

    # Extract sample name
    BASENAME=$(basename "$BG")
    BASE=${BASENAME%.gz}
    BASE=${BASE%.bedgraph}
    BASE=${BASE%.bedGraph}
    SAMPLE=${BASE%.ucsc}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_bigwig_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$BIGWIG_SCRIPT "$BG"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

if [[ $FOUND -eq 0 ]]; then
    echo "No bedGraph files found in $UCSC_DIR"
fi

echo
echo "All BigWig job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"
