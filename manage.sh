#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="${SCRIPT_DIR}/web"
PORT="${PORT:-8000}"

# Find uv binary (check PATH or common user installation locations)
UV_BIN=""
if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
elif [[ -x "${HOME}/.local/bin/uv" ]]; then
    UV_BIN="${HOME}/.local/bin/uv"
elif [[ -x "${HOME}/.cargo/bin/uv" ]]; then
    UV_BIN="${HOME}/.cargo/bin/uv"
fi

if [[ -z "${UV_BIN}" ]]; then
    echo "Error: 'uv' is not installed or not in PATH."
    echo "Please install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

stop_server() {
    echo "Checking for running control center server on port ${PORT}..."
    local pids
    pids="$(lsof -ti :"${PORT}" 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
        echo "Stopping process(es): ${pids}"
        kill ${pids} 2>/dev/null || true
        sleep 0.5
        # Force kill if still lingering
        local remaining
        remaining="$(lsof -ti :"${PORT}" 2>/dev/null || true)"
        if [[ -n "${remaining}" ]]; then
            kill -9 ${remaining} 2>/dev/null || true
        fi
        echo "Server on port ${PORT} stopped."
    else
        echo "No server running on port ${PORT}."
    fi
}

case "${1:-run}" in
    install)
        echo "Installing dependencies via uv..."
        cd "${WEB_DIR}" && "${UV_BIN}" sync
        ;;
    run)
        echo "Starting CUT&RUN Control Center..."
        cd "${WEB_DIR}"
        # Auto-open browser in background if running on macOS
        if [[ "$(uname)" == "Darwin" ]]; then
            (sleep 1.2 && open "http://127.0.0.1:${PORT}") &
        fi
        "${UV_BIN}" run uvicorn app:app --host 127.0.0.1 --port "${PORT}"
        ;;
    dev)
        echo "Starting CUT&RUN Control Center (development reload mode)..."
        cd "${WEB_DIR}"
        if [[ "$(uname)" == "Darwin" ]]; then
            (sleep 1.2 && open "http://127.0.0.1:${PORT}") &
        fi
        "${UV_BIN}" run uvicorn app:app --host 127.0.0.1 --port "${PORT}" --reload
        ;;
    stop)
        stop_server
        ;;
    test)
        echo "Running test suite..."
        cd "${WEB_DIR}" && "${UV_BIN}" run pytest test_app.py -v
        ;;
    lint)
        echo "Running static checks..."
        cd "${WEB_DIR}" && "${UV_BIN}" run python -m py_compile app.py config_parser.py test_app.py
        ;;
    clean)
        echo "Cleaning cache files..."
        find "${SCRIPT_DIR}" -type d -name "__pycache__" -exec rm -rf {} +
        find "${SCRIPT_DIR}" -type d -name ".pytest_cache" -exec rm -rf {} +
        ;;
    *)
        echo "Usage: ./manage.sh [install|run|dev|stop|test|lint|clean]"
        exit 1
        ;;
esac
