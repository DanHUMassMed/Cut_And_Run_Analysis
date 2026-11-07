#!/usr/bin/env bash

set -e

# ---- CONFIG ----
ALIGN_DIR="./results/03_align"
JOB_DIR="jobs/04_remove_dups"
DEDUP_SCRIPT="04_remove_dups.sh"

mkdir -p "$JOB_DIR"

# ---- VALIDATE ----
if [[ ! -d "$ALIGN_DIR" ]]; then
  echo "ERROR: Alignment results directory not found: $ALIGN_DIR"
  exit 1
fi

if [[ ! -f "$DEDUP_SCRIPT" ]]; then
  echo "ERROR: Dedup script not found: $DEDUP_SCRIPT"
  exit 1
fi

# ---- FIND SAM FILES ----
for SAM in "$ALIGN_DIR"/*_bowtieoutput.sam; do
    # Handle case where no files match
    if [[ ! -e "$SAM" ]]; then
        echo "No SAM files found in $ALIGN_DIR"
        break
    fi

    # Extract sample name
    BASENAME=$(basename "$SAM")
    SAMPLE=${BASENAME%_bowtieoutput.sam}

    # Job script path
    JOB_SCRIPT="$JOB_DIR/job_dedup_${SAMPLE}.sh"

    # ---- CREATE JOB SCRIPT ----
    cat << EOF > "$JOB_SCRIPT"
#!/usr/bin/env bash
set -e

./$DEDUP_SCRIPT "$SAM"
EOF

    chmod +x "$JOB_SCRIPT"

    echo "Created $JOB_SCRIPT"
done

echo
echo "All dedup job scripts created in: $JOB_DIR"
echo "Submit with:"
echo "  for job in $JOB_DIR/*.sh; do ./submit_short.sh \"\$job\"; done"