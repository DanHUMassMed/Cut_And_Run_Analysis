#!/usr/bin/env bash

set -e

# ---- CONFIG ----
DEDUP_DIR="./results/04_dedup"
JOB_DIR="jobs/05_mapq_filter"
MAPQ_SCRIPT="05_remove_low_qual.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$DEDUP_DIR" ]]; then
  echo "ERROR: Dedup results directory not found: $DEDUP_DIR"
  exit 1
fi

if [[ ! -f "$MAPQ_SCRIPT" ]]; then
  echo "ERROR: MAPQ filter script not found: $MAPQ_SCRIPT"
  exit 1
fi

# ---- FIND BAM FILES ----
for BAM in "$DEDUP_DIR"/*_PicardDedup.bam; do
    # Handle no-match case
    if [[ ! -e "$BAM" ]]; then
        echo "No BAM files found in $DEDUP_DIR"
        break
    fi

    # Extract sample name
    BASENAME=$(basename "$BAM")
    SAMPLE=${BASENAME%_PicardDedup.bam}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_mapq_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$MAPQ_SCRIPT "$BAM"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

echo
echo "All MAPQ filter job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"