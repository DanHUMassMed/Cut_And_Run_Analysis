#!/usr/bin/env bash

set -e

# ---- CONFIG ----
IN_DIR="./results/05_mapq_filter"
JOB_DIR="jobs/06_index_bam"
SCRIPT="06_index_bam.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$IN_DIR" ]]; then
  echo "ERROR: input results directory not found: $IN_DIR"
  exit 1
fi

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: script not found: $SCRIPT"
  exit 1
fi

# ---- FIND BAM FILES ----
for SAM in "$IN_DIR"/*_mapqfilt.sam; do
    # Handle no-match case
    if [[ ! -e "$SAM" ]]; then
        echo "No SAM files found in $IN_DIR"
        break
    fi

    # Extract sample name
    BASENAME=$(basename "$SAM")
    SAMPLE=${BASENAME%_PicardDedup_mapqfilt.sam}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_index_bam_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$SCRIPT "$SAM"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

echo
echo "All BAM Index job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"
