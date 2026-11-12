#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WEB_DIR="${SCRIPT_DIR}/web"
RUN_DIR="${WEB_DIR}/.run"
PORT="${PORT:-8000}"
PID_FILE="${RUN_DIR}/server_${PORT}.pid"
LOG_FILE="${RUN_DIR}/server_${PORT}.log"
USER_CONFIG_DIR="${CUTANDRUN_CONFIG_DIR:-${HOME}/.config/cutandrun}"
APP_NAME="Cut_and_Run_Control_Center.app"

hydrate_path() {
    local candidates=(
        "${HOME}/.local/bin"
        "${HOME}/.cargo/bin"
        "${HOME}/bin"
        "${HOME}/bin/homer/bin"
        "${HOME}/.sdkman/candidates/java/current/bin"
        "${HOME}/.sdkman/candidates/nextflow/current/bin"
        "/opt/homebrew/bin"
        "/opt/homebrew/sbin"
        "/usr/local/bin"
        "${HOME}/miniforge3/condabin"
        "${HOME}/mambaforge/condabin"
        "${HOME}/miniconda3/condabin"
        "${HOME}/anaconda3/condabin"
    )
    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "${dir}" && ":${PATH}:" != *":${dir}:"* ]]; then
            PATH="${dir}:${PATH}"
        fi
    done

    if ! command -v nextflow >/dev/null 2>&1 || ! command -v java >/dev/null 2>&1 || ! command -v uv >/dev/null 2>&1; then
        local login_path=""
        if [[ -n "${SHELL:-}" && -x "${SHELL}" ]]; then
            login_path="$("${SHELL}" -lc 'printenv PATH' </dev/null 2>/dev/null || true)"
        elif [[ -x "/bin/zsh" ]]; then
            login_path="$(/bin/zsh -lc 'printenv PATH' </dev/null 2>/dev/null || true)"
        fi
        if [[ -n "${login_path}" ]]; then
            local IFS=':'
            local entry
            for entry in ${login_path}; do
                if [[ -n "${entry}" && ":${PATH}:" != *":${entry}:"* ]]; then
                    PATH="${PATH}:${entry}"
                fi
            done
        fi
    fi
    export PATH
}

resolve_uv() {
    if command -v uv >/dev/null 2>&1; then
        command -v uv
        return 0
    fi
    local candidate
    for candidate in \
        "${HOME}/.local/bin/uv" \
        "${HOME}/.cargo/bin/uv" \
        "/opt/homebrew/bin/uv" \
        "/usr/local/bin/uv"; do
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    echo "Error: 'uv' is not installed or not in PATH." >&2
    echo "Please install uv: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    return 1
}

resolve_python() {
    if [[ -x "${WEB_DIR}/.venv/bin/python" ]]; then
        echo "${WEB_DIR}/.venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        command -v python3
    else
        echo ""
    fi
}

realpath_safe() {
    local target="$1"
    local py
    py="$(resolve_python)"
    if [[ -n "${py}" ]]; then
        "${py}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${target}"
    elif [[ -d "${target}" ]]; then
        (cd "${target}" && pwd -P)
    else
        echo "${target}"
    fi
}

save_user_pipeline_env() {
    mkdir -p "${USER_CONFIG_DIR}"
    printf 'PIPELINE_DIR=%q\n' "${SCRIPT_DIR}" > "${USER_CONFIG_DIR}/env"
}

expected_workspace() {
    if [[ -n "${ANALYSIS_DIR:-}" ]]; then
        realpath_safe "${ANALYSIS_DIR}"
        return 0
    fi
    local registry_file="${USER_CONFIG_DIR}/workspaces.json"
    local py
    py="$(resolve_python)"
    if [[ -f "${registry_file}" && -n "${py}" ]]; then
        local remembered
        remembered="$("${py}" -c '
import json, os, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    val = data.get("last_workspace") if isinstance(data, dict) else None
    if isinstance(val, str) and val.strip() and os.path.isdir(os.path.expanduser(val)):
        print(os.path.realpath(os.path.expanduser(val)))
except Exception:
    pass
' "${registry_file}" 2>/dev/null || true)"
        if [[ -n "${remembered}" ]]; then
            echo "${remembered}"
            return 0
        fi
    fi
    echo "${SCRIPT_DIR}"
}

read_pid() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(tr -d '[:space:]' < "${PID_FILE}" 2>/dev/null || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            echo "${pid}"
            return 0
        fi
        rm -f "${PID_FILE}"
    fi
    return 1
}

get_listening_pids() {
    lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null || true
}

fetch_health() {
    curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true
}

json_field() {
    local json_str="$1"
    local field="$2"
    local default_val="${3:-}"
    local py
    py="$(resolve_python)"
    if [[ -z "${py}" || -z "${json_str}" ]]; then
        echo "${default_val}"
        return 0
    fi
    printf '%s' "${json_str}" | "${py}" -c '
import json, sys
field, default_val = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
    val = data.get(field, default_val)
    print(default_val if val is None else val)
except Exception:
    print(default_val)
' "${field}" "${default_val}"
}

open_browser() {
    local url="http://127.0.0.1:${PORT}"
    if [[ "$(uname)" == "Darwin" ]]; then
        open "${url}" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "${url}" >/dev/null 2>&1 || true
    fi
}

open_when_ready() {
    (
        local i
        for i in $(seq 1 60); do
            if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
                open_browser
                exit 0
            fi
            sleep 0.25
        done
    ) </dev/null >/dev/null 2>&1 &
}

start_server() {
    local should_open="true"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-open)
                should_open="false"
                shift
                ;;
            *)
                echo "Unknown option for start: $1" >&2
                exit 1
                ;;
        esac
    done

    local uv_bin
    uv_bin="$(resolve_uv)"

    local health
    health="$(fetch_health)"
    if [[ -n "${health}" ]]; then
        local running_ws expected_ws
        running_ws="$(json_field "${health}" "workspace_dir" "")"
        expected_ws="$(expected_workspace)"
        if [[ -n "${ANALYSIS_DIR:-}" && -n "${running_ws}" && "${running_ws}" != "${expected_ws}" ]]; then
            echo "Error: Control Center is already running on port ${PORT} for a different workspace:" >&2
            echo "  Running:   ${running_ws}" >&2
            echo "  Requested: ${expected_ws}" >&2
            echo "Stop it first with './manage.sh stop' or use a different PORT." >&2
            exit 1
        fi
        echo "Control Center is already running at http://127.0.0.1:${PORT} (workspace: ${running_ws})."
        if [[ "${should_open}" == "true" ]]; then
            open_browser
        fi
        return 0
    fi

    local existing_listeners
    existing_listeners="$(get_listening_pids)"
    if [[ -n "${existing_listeners}" ]]; then
        echo "Error: Port ${PORT} is already in use by PID(s): ${existing_listeners}, and /api/health is not responding." >&2
        echo "Stop the conflicting process or set PORT=<port>." >&2
        exit 1
    fi

    mkdir -p "${RUN_DIR}"
    if [[ -f "${LOG_FILE}" ]]; then
        local log_size
        log_size="$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)"
        if (( log_size > 5242880 )); then
            mv -f "${LOG_FILE}" "${LOG_FILE}.1"
        fi
    fi

    {
        echo ""
        echo "=== Starting CUT&RUN Control Center ($(date '+%Y-%m-%d %H:%M:%S')) ==="
        echo "Workspace: $(expected_workspace)"
        echo "Port: ${PORT}"
    } >> "${LOG_FILE}"

    local venv_python="${WEB_DIR}/.venv/bin/python"
    if [[ ! -x "${venv_python}" ]]; then
        echo "Virtual environment missing; syncing dependencies via uv..." >> "${LOG_FILE}"
        (cd "${WEB_DIR}" && "${uv_bin}" sync >> "${LOG_FILE}" 2>&1)
    fi

    cd "${WEB_DIR}"
    local server_pid
    server_pid="$("${venv_python}" -c '
import os, subprocess, sys
web_dir, log_file, port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(log_file, "ab", buffering=0) as log_fh:
    proc = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "uvicorn",
            "app:app",
            "--host",
            "127.0.0.1",
            "--port",
            port,
            "--timeout-graceful-shutdown",
            "2",
        ],
        cwd=web_dir,
        stdin=subprocess.DEVNULL,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    print(proc.pid)
' "${WEB_DIR}" "${LOG_FILE}" "${PORT}")"
    echo "${server_pid}" > "${PID_FILE}"

    local i
    for i in $(seq 1 60); do
        if ! kill -0 "${server_pid}" 2>/dev/null; then
            rm -f "${PID_FILE}"
            echo "Error: Control Center failed to start (process exited). Recent logs:" >&2
            tail -n 25 "${LOG_FILE}" >&2 || true
            exit 1
        fi
        if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
            echo "Control Center started (PID ${server_pid}) at http://127.0.0.1:${PORT}"
            echo "Logs: ${LOG_FILE}"
            if [[ "${should_open}" == "true" ]]; then
                open_browser
            fi
            return 0
        fi
        sleep 0.25
    done

    echo "Error: Control Center timed out waiting for http://127.0.0.1:${PORT}/api/health. Recent logs:" >&2
    tail -n 25 "${LOG_FILE}" >&2 || true
    exit 1
}

stop_server() {
    echo "Checking for running control center server on port ${PORT}..."
    local pids=()
    local pid_from_file=""
    if pid_from_file="$(read_pid)"; then
        pids+=("${pid_from_file}")
    fi

    local listener
    for listener in $(get_listening_pids); do
        local seen="false"
        local existing
        for existing in "${pids[@]:-}"; do
            if [[ "${existing}" == "${listener}" ]]; then
                seen="true"
                break
            fi
        done
        if [[ "${seen}" == "false" ]]; then
            pids+=("${listener}")
        fi
    done

    if [[ ${#pids[@]} -eq 0 ]]; then
        rm -f "${PID_FILE}"
        echo "No server running on port ${PORT}."
        return 0
    fi

    echo "Stopping process(es): ${pids[*]}"
    kill -TERM "${pids[@]}" 2>/dev/null || true

    local i alive
    for i in $(seq 1 25); do
        alive=()
        local p
        for p in "${pids[@]}"; do
            if kill -0 "${p}" 2>/dev/null; then
                alive+=("${p}")
            fi
        done
        if [[ ${#alive[@]} -eq 0 ]]; then
            rm -f "${PID_FILE}"
            echo "Server on port ${PORT} stopped gracefully."
            return 0
        fi
        sleep 0.2
    done

    echo "Force-stopping remaining process(es): ${alive[*]}"
    kill -KILL "${alive[@]}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    echo "Server on port ${PORT} stopped."
}

status_server() {
    local pid=""
    pid="$(read_pid || true)"
    local health
    health="$(fetch_health)"

    if [[ -n "${health}" ]]; then
        local ws pipeline_state
        ws="$(json_field "${health}" "workspace_dir" "unknown")"
        pipeline_state="$(json_field "${health}" "pipeline_status" "unknown")"
        if [[ -z "${pid}" ]]; then
            pid="$(get_listening_pids | head -n 1 || true)"
        fi
        echo "Status: running"
        echo "URL: http://127.0.0.1:${PORT}"
        echo "PID: ${pid:-unknown}"
        echo "Workspace: ${ws}"
        echo "Pipeline: ${pipeline_state}"
        echo "Logs: ${LOG_FILE}"
        return 0
    fi

    if [[ -n "${pid}" ]]; then
        echo "Status: starting_or_unhealthy (PID ${pid}, port ${PORT} not responding)"
        echo "Logs: ${LOG_FILE}"
        return 1
    fi

    echo "Status: stopped (port ${PORT})"
    echo "Workspace: $(expected_workspace)"
    echo "Logs: ${LOG_FILE}"
    return 1
}

app_info() {
    local health
    health="$(fetch_health)"
    if [[ -n "${health}" ]]; then
        local ws pipeline_state
        ws="$(json_field "${health}" "workspace_dir" "unknown")"
        pipeline_state="$(json_field "${health}" "pipeline_status" "idle")"
        echo "running|http://127.0.0.1:${PORT}|${ws}|${pipeline_state}|${LOG_FILE}"
    else
        echo "stopped|http://127.0.0.1:${PORT}|$(expected_workspace)|idle|${LOG_FILE}"
    fi
}

logs_server() {
    local mode="tail"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow)
                mode="follow"
                shift
                ;;
            --path)
                mode="path"
                shift
                ;;
            *)
                echo "Unknown option for logs: $1" >&2
                exit 1
                ;;
        esac
    done

    if [[ "${mode}" == "path" ]]; then
        echo "${LOG_FILE}"
        return 0
    fi
    if [[ ! -f "${LOG_FILE}" ]]; then
        echo "No log file yet at ${LOG_FILE}"
        return 0
    fi
    echo "Log file: ${LOG_FILE}"
    if [[ "${mode}" == "follow" ]]; then
        tail -n 100 -f "${LOG_FILE}"
    else
        tail -n 100 "${LOG_FILE}"
    fi
}

build_app() {
    if [[ "$(uname)" != "Darwin" ]] || ! command -v osacompile >/dev/null 2>&1; then
        echo "Error: build-app requires macOS with osacompile." >&2
        exit 1
    fi
    if [[ $# -gt 1 ]]; then
        echo "Usage: ./manage.sh build-app [DIR]" >&2
        exit 1
    fi

    local target_dir="${1:-${SCRIPT_DIR}}"
    mkdir -p "${target_dir}"
    target_dir="$(realpath_safe "${target_dir}")"
    local app_path="${target_dir}/${APP_NAME}"
    local script_src="${SCRIPT_DIR}/scripts/launcher.applescript"
    local helper_src="${SCRIPT_DIR}/scripts/app_launcher.sh"

    if [[ ! -f "${script_src}" || ! -f "${helper_src}" ]]; then
        echo "Error: Missing scripts/launcher.applescript or scripts/app_launcher.sh" >&2
        exit 1
    fi

    local tmp_dir staged_app
    tmp_dir="$(mktemp -d)"
    staged_app="${tmp_dir}/${APP_NAME}"

    osacompile -s -o "${staged_app}" "${script_src}"

    local resources_dir="${staged_app}/Contents/Resources"
    mkdir -p "${resources_dir}"
    cp "${helper_src}" "${resources_dir}/app_launcher.sh"
    chmod +x "${resources_dir}/app_launcher.sh"

    local plist="${staged_app}/Contents/Info.plist"
    if [[ -x "/usr/libexec/PlistBuddy" && -f "${plist}" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleName CUT&RUN Control Center" "${plist}" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :CFBundleName string CUT&RUN Control Center" "${plist}"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier edu.umassmed.cutandrun.controlcenter" "${plist}" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string edu.umassmed.cutandrun.controlcenter" "${plist}"
    fi

    if command -v codesign >/dev/null 2>&1; then
        codesign --force --deep --sign - "${staged_app}"
    fi

    if [[ -d "${app_path}" ]]; then
        rm -rf "${app_path}"
    fi
    mv "${staged_app}" "${app_path}"
    rm -rf "${tmp_dir}"

    touch "${app_path}"
    echo "Built macOS app bundle: ${app_path}"
}

print_help() {
    cat <<EOF
Usage: ./manage.sh <command> [options]

Lifecycle commands:
  install            Install Python dependencies via uv and save PIPELINE_DIR config
  start [--no-open]  Start Control Center in the background and open browser
  stop               Gracefully stop the Control Center server
  restart [--no-open] Restart the Control Center server
  status             Show server status, PID, active workspace, and log path
  logs [-f|--path]   Show recent server logs (-f to follow, --path for file path)
  run                Start Control Center in the foreground (CLI debugging)
  dev                Start Control Center in foreground with --reload

Packaging & quality commands:
  build-app [DIR]    Build Cut_and_Run_Control_Center.app in DIR (default: repo root)
  test               Run backend pytest suite
  lint               Run ruff, mypy, and py_compile static checks
  clean              Remove Python/pytest/mypy/ruff cache directories
  help               Show this help message

Environment variables:
  PORT               Server port (default: 8000)
  ANALYSIS_DIR       Override initial Analysis_Run experiment directory
EOF
}

hydrate_path

if [[ $# -eq 0 ]]; then
    print_help
    exit 0
fi

case "$1" in
    -h|--help|help)
        print_help
        exit 0
        ;;
    install)
        uv_bin="$(resolve_uv)"
        echo "Installing dependencies via uv..."
        cd "${WEB_DIR}" && "${uv_bin}" sync
        save_user_pipeline_env
        ;;
    start)
        save_user_pipeline_env
        shift || true
        start_server "$@"
        ;;
    run)
        uv_bin="$(resolve_uv)"
        if [[ -n "$(fetch_health)" ]]; then
            echo "Control Center is already running at http://127.0.0.1:${PORT}."
            open_browser
            exit 0
        fi
        echo "Starting CUT&RUN Control Center (foreground)..."
        cd "${WEB_DIR}"
        open_when_ready
        exec "${uv_bin}" run uvicorn app:app --host 127.0.0.1 --port "${PORT}" --timeout-graceful-shutdown 2
        ;;
    dev)
        uv_bin="$(resolve_uv)"
        echo "Starting CUT&RUN Control Center (development reload mode)..."
        cd "${WEB_DIR}"
        open_when_ready
        exec "${uv_bin}" run uvicorn app:app --host 127.0.0.1 --port "${PORT}" --timeout-graceful-shutdown 2 --reload
        ;;
    stop)
        stop_server
        ;;
    restart)
        shift || true
        stop_server
        start_server "$@"
        ;;
    status)
        status_server
        ;;
    app-info)
        app_info
        ;;
    logs)
        shift || true
        logs_server "$@"
        ;;
    build-app)
        shift || true
        build_app "$@"
        ;;
    test)
        uv_bin="$(resolve_uv)"
        echo "Running test suite..."
        cd "${WEB_DIR}" && "${uv_bin}" run pytest -v
        ;;
    lint)
        uv_bin="$(resolve_uv)"
        echo "Running static checks (ruff, mypy, py_compile)..."
        cd "${WEB_DIR}"
        "${uv_bin}" run ruff check .
        "${uv_bin}" run mypy .
        "${uv_bin}" run python -m py_compile app.py config_parser.py dependencies.py models.py repositories.py settings.py test_app.py routes/*.py services/*.py
        ;;
    clean)
        echo "Cleaning cache files..."
        find "${SCRIPT_DIR}" -type d -name "__pycache__" -exec rm -rf {} +
        find "${SCRIPT_DIR}" -type d -name ".pytest_cache" -exec rm -rf {} +
        find "${SCRIPT_DIR}" -type d -name ".mypy_cache" -exec rm -rf {} +
        find "${SCRIPT_DIR}" -type d -name ".ruff_cache" -exec rm -rf {} +
        ;;
    *)
        echo "Error: Unknown command '$1'" >&2
        echo "" >&2
        print_help >&2
        exit 1
        ;;
esac
