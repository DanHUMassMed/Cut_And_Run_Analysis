#!/usr/bin/env bash
set -euo pipefail

RESUME="-resume"
if [ "${1:-}" = "false" ] || [ "${1:-}" = "--no-resume" ]; then
    RESUME=""
    shift
elif [ "${1:-}" = "true" ] || [ "${1:-}" = "--resume" ]; then
    RESUME="-resume"
    shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

email="$(sed -nE "s/^[[:space:]]*email[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" config/experiment.config | head -n 1)"
nextflow -c config/experiment.config run ../../Cut_And_Run_Analysis -profile docker,arm64 ${RESUME} -N "${email}" "$@"

