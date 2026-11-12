# CUT&RUN Control Center

FastAPI + vanilla ES-module web interface for configuring, validating, launching, and monitoring the CUT&RUN downstream Nextflow pipeline.

## Structure
- `app.py`: FastAPI application factory, security headers middleware, static asset mounting, and router wiring.
- `settings.py` / `dependencies.py`: Workspace path configuration and dependency-injection container.
- `models.py` / `config_parser.py`: Pydantic schemas and safe Groovy `experiment.config` parser/serializer.
- `repositories.py`: Protocol-backed file repositories for config, samplesheet, and sandboxed result files.
- `services/`: Pipeline subprocess runner, task/log tracker, and extensible pre-flight checks.
- `routes/`: Modular FastAPI routers (`config`, `samplesheet`, `pipeline`, `results`).
- `static/`: Semantic HTML5 UI (`index.html`), stylesheet (`css/styles.css`), and ES modules (`js/*.js`).

## Commands (from project root)
- `./manage.sh install` — Sync dependencies via `uv`
- `./manage.sh start` — Start background server, wait for `/api/health`, and open browser
- `./manage.sh stop` — Gracefully stop server (and any active Nextflow pipeline)
- `./manage.sh restart` — Stop and restart background server
- `./manage.sh status` — Report server health, PID, workspace, and log location
- `./manage.sh logs` — Print recent server logs (`-f` to follow)
- `./manage.sh build-app [DIR]` — Build `Cut & Run Control Center.app` macOS launcher
- `./manage.sh run` — Run FastAPI server in foreground
- `./manage.sh dev` — Run FastAPI server with reload
- `./manage.sh test` — Run `pytest` suite
- `./manage.sh lint` — Run `ruff`, `mypy`, and `py_compile`
