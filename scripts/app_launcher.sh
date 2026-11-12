#!/usr/bin/env bash
set -euo pipefail

# Helper invoked by the macOS .app bundle (Contents/Resources/app_launcher.sh).
# Usage: app_launcher.sh <app_bundle_path> <check|start|stop|save-pipeline <dir>>

APP_BUNDLE="${1:?Missing app bundle path}"
ACTION="${2:?Missing action}"

USER_CONFIG_DIR="${CUTANDRUN_CONFIG_DIR:-${HOME}/.config/cutandrun}"
USER_ENV_FILE="${USER_CONFIG_DIR}/env"

if [[ "${ACTION}" == "save-pipeline" ]]; then
    TARGET_DIR="${3:?Missing pipeline directory}"
    if [[ ! -x "${TARGET_DIR}/manage.sh" ]]; then
        echo "Selected folder does not contain manage.sh: ${TARGET_DIR}" >&2
        exit 1
    fi
    mkdir -p "${USER_CONFIG_DIR}"
    printf 'PIPELINE_DIR=%q\n' "${TARGET_DIR}" > "${USER_ENV_FILE}"
    exit 0
fi

APP_PARENT="$(cd "$(dirname "${APP_BUNDLE}")" && pwd -P)"
RESOLVED_PIPELINE_DIR=""
RESOLVED_ANALYSIS_DIR="${ANALYSIS_DIR:-}"

# 1. Explicit environment override (if set before launch)
if [[ -n "${PIPELINE_DIR:-}" && -x "${PIPELINE_DIR}/manage.sh" ]]; then
    RESOLVED_PIPELINE_DIR="${PIPELINE_DIR}"
fi

# 2. Sibling / relative repo detection
if [[ -z "${RESOLVED_PIPELINE_DIR}" && -x "${APP_PARENT}/manage.sh" ]]; then
    RESOLVED_PIPELINE_DIR="${APP_PARENT}"
elif [[ -f "${APP_PARENT}/run.sh" || -f "${APP_PARENT}/config/experiment.config" ]]; then
    RESOLVED_ANALYSIS_DIR="${RESOLVED_ANALYSIS_DIR:-${APP_PARENT}}"
    if [[ -z "${RESOLVED_PIPELINE_DIR}" && -x "${APP_PARENT}/../../Cut_And_Run_Analysis/manage.sh" ]]; then
        RESOLVED_PIPELINE_DIR="$(cd "${APP_PARENT}/../../Cut_And_Run_Analysis" && pwd -P)"
    fi
fi

# 3. User-level config (~/.config/cutandrun/env)
if [[ -z "${RESOLVED_PIPELINE_DIR}" && -f "${USER_ENV_FILE}" ]]; then
    unset PIPELINE_DIR || true
    # shellcheck disable=SC1090
    source "${USER_ENV_FILE}"
    if [[ -n "${PIPELINE_DIR:-}" && -x "${PIPELINE_DIR}/manage.sh" ]]; then
        RESOLVED_PIPELINE_DIR="${PIPELINE_DIR}"
    fi
fi

if [[ -z "${RESOLVED_PIPELINE_DIR}" || ! -x "${RESOLVED_PIPELINE_DIR}/manage.sh" ]]; then
    echo "MISSING_PIPELINE_DIR" >&2
    exit 42
fi

export PORT="${PORT:-8000}"
if [[ -n "${RESOLVED_ANALYSIS_DIR}" ]]; then
    export ANALYSIS_DIR="${RESOLVED_ANALYSIS_DIR}"
else
    unset ANALYSIS_DIR || true
fi

case "${ACTION}" in
    check)
        "${RESOLVED_PIPELINE_DIR}/manage.sh" app-info
        ;;
    start)
        "${RESOLVED_PIPELINE_DIR}/manage.sh" start
        ;;
    stop)
        "${RESOLVED_PIPELINE_DIR}/manage.sh" stop
        ;;
    *)
        echo "Unknown action: ${ACTION}" >&2
        exit 1
        ;;
esac
