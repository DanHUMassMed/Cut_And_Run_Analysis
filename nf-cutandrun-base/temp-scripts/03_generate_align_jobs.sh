#!/usr/bin/env bash

set -e

# ---- CONFIG ----
TRIM_DIR="./results/01_trim"
JOB_DIR="jobs/03_align"
ALIGN_SCRIPT="03_align.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$TRIM_DIR" ]]; then
  echo "ERROR: Trim results directory not found: $TRIM_DIR"
  exit 1
fi

if [[ ! -f "$ALIGN_SCRIPT" ]]; then
  echo "ERROR: Align script not found: $ALIGN_SCRIPT"
  exit 1
fi

# ---- FIND PAIRED FILES ----
for R1 in "$TRIM_DIR"/*paired.trim_1.fastq.gz; do
    # Derive R2
    R2="${R1/_1./_2.}"

    # Check pair exists
    if [[ ! -f "$R2" ]]; then
        echo "WARNING: Missing pair for $R1, skipping"
        continue
    fi

    # Extract sample name
    BASENAME=$(basename "$R1")
    SAMPLE=${BASENAME%_1.*}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_align_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$ALIGN_SCRIPT "$R1" "$R2"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

echo
echo "All alignment job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"