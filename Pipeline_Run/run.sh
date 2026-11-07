#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

email="$(sed -nE "s/^[[:space:]]*email[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" config/experiment.config | head -n 1)"
nextflow -c config/experiment.config run ../nf-cutandrun-base -resume -N "${email}" "$@"
