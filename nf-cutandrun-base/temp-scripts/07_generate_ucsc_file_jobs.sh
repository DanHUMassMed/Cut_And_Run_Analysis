#!/usr/bin/env bash

set -e

# ---- CONFIG ----
MAPQ_DIR="./results/05_mapq_filter"
JOB_DIR="jobs/07_ucsc"
UCSC_SCRIPT="07_ucsc_file.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$MAPQ_DIR" ]]; then
  echo "ERROR: MAPQ results directory not found: $MAPQ_DIR"
  exit 1
fi

if [[ ! -f "$UCSC_SCRIPT" ]]; then
  echo "ERROR: UCSC script not found: $UCSC_SCRIPT"
  exit 1
fi

# ---- FIND SAM FILES ----
for SAM in "$MAPQ_DIR"/*_PicardDedup_mapqfilt.sam; do
    # Handle no-match case
    if [[ ! -e "$SAM" ]]; then
        echo "No SAM files found in $MAPQ_DIR"
        break
    fi

    # Extract sample name
    BASENAME=$(basename "$SAM")
    SAMPLE=${BASENAME%_PicardDedup_mapqfilt.sam}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_ucsc_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$UCSC_SCRIPT "$SAM"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

echo
echo "All UCSC job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"