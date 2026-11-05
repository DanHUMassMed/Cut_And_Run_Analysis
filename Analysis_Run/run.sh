#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

email=daniel.higgins@umassmed.edu
nextflow -c config/experiment.config run ../ -resume -N "${email}" "$@"

