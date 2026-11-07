#/bin/bash
REMOTE_DIR="remote:Walker_lab_shared/Bioinformatics_parent/cut_run103026/trimmomatic"
rclone copy "${REMOTE_DIR}" "./results/01_trim" -P --transfers 4
