#!/bin/bash
REMOTE_DIR="remote:Walker_lab_shared/Bioinformatics_parent/cut_run103026"

rclone copy -P -vv "./CUT_RUN_analysis_pipeline.pdf" "${REMOTE_DIR}/00_overview/"
#rclone copy -P -vv "./md5_report.html" "${REMOTE_DIR}/02_fastqc/"

#rclone copy -P -vv "./results/02_fastqc" "${REMOTE_DIR}/02_fastqc/" --include "*.html"

rclone copy -P -vv "./results/03_align" "${REMOTE_DIR}/03_align/" --include "*.sam"

rclone copy -P -vv "./results/04_dedup" "${REMOTE_DIR}/04_dedup/" --include "*.txt"

rclone copy -P -vv "./results/05_mapq_filter" "${REMOTE_DIR}/05_mapq_filter/" --include "*.sam"

rclone copy -P -vv "./results/06_index_bam" "${REMOTE_DIR}/06_index_bam/" --include "*.*"

rclone copy -P -vv "./results/07_ucsc" "${REMOTE_DIR}/07_ucsc" --include "**/*"

rclone copy -P -vv "./results/08_bigwig" "${REMOTE_DIR}/08_bigwig/" --include "*.bw"
