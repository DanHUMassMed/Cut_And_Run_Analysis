# Architectural & SOLID Code Review: `web/` Directory

## 1. Executive Summary

The `web/` directory implements the **CUT&RUN Pipeline Control Center** (`v2.0.0`), a local FastAPI + vanilla HTML/JS application for editing Nextflow experiment configurations (`experiment.config` and `samplesheet.csv`), running environment pre-flight checks, launching/stopping Nextflow runs, streaming live progress/logs via Server-Sent Events (SSE) and Nextflow `nf-weblog` webhooks, and browsing pipeline output artifacts.

While the application is functional and all 9 existing unit tests pass (`./manage.sh test`), the codebase exhibits significant **SOLID violations**, tight coupling to global mutable state and local filesystem conventions, and several correctness/security bugs—most notably a **prefix-based path traversal vulnerability** in result file serving, **XSS vectors** in client-side `innerHTML` rendering, **shared mutable class attributes** on `ProcessState`, and **monolithic modules** (`web/app.py` at 733 lines and `web/static/index.html` at 2,491 lines).

---

## 2. Directory & Architecture Overview

### Inventory

| File | Lines | Purpose |
| :--- | ---: | :--- |
| `web/pyproject.toml` | 15 | `uv`-managed project metadata (`>=3.12`); dependencies: `fastapi`, `uvicorn`, `pydantic`, `pytest`. |
| `web/README.md` | 3 | Minimal title and one-line description. |
| `web/config_parser.py` | 251 | Pydantic domain models (`ContrastModel`, `ExperimentConfigModel`), Groovy `experiment.config` regex parser, and string-template serializer. |
| `web/app.py` | 733 | FastAPI app, global `ProcessState`, all REST/SSE endpoints, subprocess management, trace TSV reconciliation, and static file serving. |
| `web/test_app.py` | 402 | 9 pytest/anyio unit tests covering config roundtrip, webhook/task state, sentinel exit codes, launch command args, timing, and index caching headers. |
| `web/static/index.html` | 2,491 | Single-file frontend containing all CSS (lines 7–712), 5-tab UI + 3 modals (lines 714–1386), and inline JavaScript (lines 1388–2488). |

### Runtime Data Flow

```text
Browser (web/static/index.html)
  ├── GET/PUT /api/config             ──▶ config_parser.py ──▶ WORKSPACE_DIR/config/experiment.config (+ .bak)
  ├── GET/PUT /api/samplesheet        ──▶ csv DictReader/Writer ──▶ WORKSPACE_DIR/config/samplesheet.csv (+ .bak)
  ├── POST    /api/samplesheet/discover ──▶ glob *.bam in input_dir/06_index_bam
  ├── POST    /api/preflight          ──▶ filesystem checks + `which nextflow`
  ├── POST    /api/pipeline/start     ──▶ writes .nextflow/weblog.config ──▶ `bash run.sh` subprocess
  ├── POST    /api/pipeline/stop      ──▶ os.killpg(..., SIGINT)
  ├── GET     /api/pipeline/stream    ◀── SSE queue subscribers (from stdout regex + webhooks)
  ├── GET     /api/pipeline/status    ◀── 2s polling snapshot of global `state`
  └── GET     /api/results/*          ──▶ rglob results/{experiment} + macOS `open`
Nextflow (`nf-weblog`)
  └── POST    /api/pipeline/webhook   ──▶ updates global `state.tasks` + trace TSV reconciliation
```

### Verification Baseline

- `./manage.sh test`: **9 passed in 0.09s** (note: tests execute against an in-memory `state` object and mocked `create_subprocess_exec`).
- `./manage.sh lint`: runs `python -m py_compile` only; no static type checker (`mypy`/`pyright`), linter (`ruff`), or formatter is configured.

---

## 3. SOLID Principles Review

### S — Single Responsibility Principle (SRP)

Multiple files combine distinct architectural layers (routing, domain modeling, persistence, process orchestration, UI rendering) into single units.

1. **`web/app.py` acts as router, state store, process manager, parser, and filesystem adapter:**
   - HTTP/SSE routing (`@app.get`/`@app.post`/`@app.put`, lines 187–732).
   - Process lifecycle & signal management (`start_pipeline` L415–466, `stop_pipeline` L469–484, `stream_subprocess_output` L321–408).
   - Nextflow output & trace reconciliation (`PROCESS_STREAM_RE` L67–69, `reconcile_from_trace_file` L72–131, `update_stats` L134–167).
   - File persistence and `.bak` rotation (`update_config` L208–217, `update_samplesheet` L236–249, `ensure_weblog_config` L170–184).
   - Environment diagnostics and OS shell actions (`run_preflight` L267–318, `open_in_finder` L704–717).
2. **`web/config_parser.py` couples domain schema with Groovy text I/O:**
   - `ExperimentConfigModel` (L16–71) and `ContrastModel` (L9–13) are clean Pydantic schemas, but live alongside regex-based Groovy parsing (`parse_experiment_config`, L74–129) and a 120-line hardcoded template (`serialize_experiment_config`, L132–250).
3. **`web/static/index.html` is a 2,491-line monolith:**
   - Mixes design tokens/CSS, 5 independent views (Configuration, Samplesheet, Contrasts, Monitor, Results & QC), 3 modal dialogs, API client logic, SSE/polling state synchronization, and raw DOM string builders in one file.

**Recommendation:** Split `web/app.py` into focused layers (`routes/`, `services/pipeline_runner.py`, `services/task_tracker.py`, `services/preflight.py`, `repositories/workspace_repo.py`) and separate `web/static/index.html` into modular CSS/JS assets (or a Vite + React/TypeScript frontend if UI complexity continues to grow).

---

### O — Open/Closed Principle (OCP)

Adding new configuration fields, pre-flight checks, or result artifact categories requires editing core control flow across multiple files rather than extending registered components.

1. **Config parameter proliferation:** Adding a single pipeline parameter requires modifying:
   - `ExperimentConfigModel` (`web/config_parser.py:16-71`)
   - `serialize_experiment_config` (`web/config_parser.py:132-250`)
   - HTML inputs (`web/static/index.html:739-1060`)
   - `loadConfig()` (`web/static/index.html:1401-1459`)
   - `saveConfig()` (`web/static/index.html:1522-1591`)
2. **Hardcoded pre-flight checks (`web/app.py:267-318`):** `run_preflight()` executes 6 inline `if/else` blocks. New checks (e.g., Java version, Docker/Conda availability, `samplesheet.csv` schema validity, genome asset existence) cannot be added without editing the endpoint handler.
3. **Hardcoded result categories (`web/app.py:685`, `web/static/index.html:2301-2464`):** Allowed extensions (`*.png`, `*.svg`, `*.tsv`, `*.txt`, `*.pdf`, `*.html`) and folder handlers (`15_summary_plots`, `13_metapeak_plots`, `14_motifs`) are hardcoded in `if/else` branches. Note also that `*.svg` and `*.tsv` are collected by `/api/results/files` (`app.py:685`) but never rendered anywhere in `loadResultsGallery()`.

**Recommendation:** Model pre-flight checks as a list of `PreflightCheck` strategy objects/callables; drive config form binding and serialization via field metadata or a structured schema mapping.

---

### L — Liskov Substitution Principle (LSP)

Because the backend uses concrete functions and a single un-inherited state class (`ProcessState`), there are no formal inheritance hierarchies—however, **implicit structural contracts** are violated in two places:

1. **Shared mutable class attributes on `ProcessState` (`web/app.py:43-62`):**
   ```python
   class ProcessState:
       log_history: list[str] = []
       subscribers: list[asyncio.Queue] = []
       tasks: dict[str, dict[str, Any]] = {}
       stats: dict[str, Any] = { ... }
   ```
   `ProcessState` defines mutable containers on the class rather than per-instance in `__init__` (or `@dataclass` with `field(default_factory=...)`). Instantiating a fresh `ProcessState()` for isolation or testing does not produce an independent instance—it shares `tasks`, `log_history`, `subscribers`, and `stats` with the global singleton.
2. **Inconsistent `task` dictionary schemas across producers:**
   Four different code paths populate `state.tasks[key]` with incompatible shapes:
   - `reconcile_from_trace_file` (`app.py:112-127`): sets `"duration"`, `"realtime_fmt"`, `float` `"cpu_percent"`, `str` `"peak_rss"`, and **omits `"realtime"`**.
   - `stream_subprocess_output` (`app.py:346-360`): sets `"realtime": 0`, `"peak_rss": 0`, and **omits `"duration"` / `"realtime_fmt"`**.
   - `receive_pipeline_webhook` trace branch (`app.py:514-528`): passes raw `trace.get("%cpu")` and `trace.get("peak_rss")`, and **omits `"duration"` / `"realtime_fmt"`**.
   - `receive_pipeline_webhook` completed fallback (`app.py:572-586`): sets `"realtime": 0`, `"cpu_percent": 0.0`, `"peak_rss": 0`.
   
   A unified `TaskRecord` Pydantic model/dataclass would guarantee every producer emits a substitutable contract.

---

### I — Interface Segregation Principle (ISP)

Interfaces are overly broad, forcing callers to depend on fields and methods they do not use:

1. **Monolithic `ExperimentConfigModel` (`web/config_parser.py:16-71`):** All 36 fields (general paths, 10 step toggles, genome references, MACS2, HOMER, deepTools, MEME, volcano thresholds, and `diff_contrasts`) are bundled into one payload.
   - As a result, the Contrasts tab (`saveContrasts()` in `web/static/index.html:1803-1824`) must `PUT` the entire `currentConfig` object back to `/api/config` just to save `diff_contrasts`. If the user has unsaved edits in the Configuration tab or if `currentConfig` wasn't fully loaded yet, partial/stale state can be overwritten or fail Pydantic validation.
2. **God-object `ProcessState` (`web/app.py:43-62`):** Functions that only need log broadcasting (`get_log_stream`), task metrics (`update_stats`), or subprocess control (`stop_pipeline`) all couple directly to the full `ProcessState` object.

**Recommendation:** Group config into logical sub-models (`PathSettings`, `StepToggles`, `Macs2Params`, `HomerParams`, `MetapeakParams`, `MotifParams`, `SummaryPlotParams`) composed inside `ExperimentConfigModel`, and expose focused endpoints (e.g., `PATCH /api/config/contrasts`) alongside full config updates. Separate `ProcessRunnerState` from `LogBroadcaster` and `TaskTracker`.

---

### D — Dependency Inversion Principle (DIP)

High-level HTTP handlers depend directly on concrete globals, filesystem paths, and OS primitives rather than injected abstractions:

1. **Hardcoded module-level globals (`web/app.py:29-34, 65`):**
   `WORKSPACE_DIR`, `CONFIG_PATH`, `SAMPLESHEET_PATH`, `RUN_SH_PATH`, and `state = ProcessState()` are evaluated at import time and referenced directly inside every route and helper function.
   - Consequence: `test_app.py` cannot test `/api/config`, `/api/samplesheet`, `/api/preflight`, or `/api/results/*` against isolated `tmp_path` fixtures without monkeypatching module globals, and tests that touch `state` risk cross-test pollution (e.g., `test_app.py:93-95, 157-158, 218-219` manually clear `state` fields).
2. **Direct coupling to `subprocess` and `asyncio.create_subprocess_exec` (`web/app.py:304, 451, 714`):**
   `start_pipeline` and `run_preflight` invoke OS binaries directly, requiring `monkeypatch.setattr("asyncio.create_subprocess_exec", ...)` in `test_app.py:332`.
3. **Unused FastAPI DI opportunities:** FastAPI natively supports `Depends(...)` for injecting a `WorkspaceConfig`, `ConfigRepository`, `PipelineManager`, and `ResultsRepository` bound to `app.state` during lifespan startup.

---

## 4. Security, Correctness & Reliability Findings

### Critical / High Priority

1. **Path Traversal in Result File Serving (`web/app.py:720-732`)**
   ```python
   results_dir = (WORKSPACE_DIR / "results" / cfg.experiment).resolve()
   target = (results_dir / file_path).resolve()

   # Sandboxing check
   if not str(target).startswith(str(results_dir)) or not target.exists() or not target.is_file():
       raise HTTPException(status_code=404, detail="File not found")
   ```
   `str(target).startswith(str(results_dir))` lacks a trailing path separator. If `results_dir` is `/.../results/exp1`, a request targeting `/api/results/file/../exp1_private/secret.txt` resolves to `/.../results/exp1_private/secret.txt`, which passes `startswith`!
   - **Fix:** Replace with `if not target.is_relative_to(results_dir) or not target.is_file():`.

2. **Stored/Reflected XSS in `web/static/index.html`**
   While `showToast`, `checkPreflight`, and `renderTaskRow` sanitize values via `escapeHtml()`, several `innerHTML` templates interpolate raw data without escaping:
   - `renderSamples()` (lines 1638–1650): `cid`, `r.sample_id`, `r.sample_name`, `r.condition`, `r.target`, `r.replicate`.
   - `renderContrasts()` (lines 1735–1767): `c.target`, `c.treatment`, `c.background`, `c.id`.
   - `loadResultsGallery()` (lines 2383–2461): `f.path`, `f.name`, `f.subfolder`.
   - **Fix:** Escape all dynamic text/attribute interpolations or build elements using `document.createElement` + `.textContent` / `.value` assignment.

3. **Unescaped Groovy String Interpolation (`web/config_parser.py:132-250`)**
   `serialize_experiment_config()` embeds user strings (`model.email`, `model.experiment`, `model.input_dir`, contrast fields, etc.) directly into Groovy double-quoted (`"..."`) and single-quoted (`'...'`) strings. Quotes, backslashes, newlines, or `${...}` in user input can corrupt `experiment.config` or inject arbitrary Groovy expressions evaluated by Nextflow.
   - Note also: `EmailStr` is imported on `web/config_parser.py:6` but never used (`email: str` on line 18), and `experiment` has no path-safe validation (e.g., preventing `../` in `results/{cfg.experiment}`).

### Medium Priority

4. **Groovy Parser Fragility (`web/config_parser.py:74-130`)**
   - Line 85 regex `r"^([a-zA-Z0-9_]+)\s*=\s*(.+?)(?:\s*//.*)?$"` uses non-greedy `.+?` before `(?:\s*//.*)?$`. Any quoted value containing `//` (for example a path or URL) will be truncated at `//`, causing quote stripping (`val.startswith('"') and val.endswith('"')`) to fail silently and drop the field back to its default.
   - Float regex `r"^-?\d+\.\d+$"` (line 97) misses scientific notation (`1e-4`) or integer-like floats (`1`).
   - `diff_contrasts` regex (lines 121–124) requires exact key ordering (`id`, `treatment`, `background`, `target`), single-line map syntax, and non-empty values (`[^'"]+` skips contrasts with blank fields).
   - `serialize_experiment_config()` overwrites the entire `experiment.config` file using a hardcoded template, discarding any user-customized globs (`input_bam`, `input_bigwig`, etc.) or comments present in the original file.

5. **Port Mismatch in Webhook Generation (`web/app.py:436-437`)**
   `start_pipeline` reads `os.environ.get("PORT", "8000")` to write `weblog.url = 'http://127.0.0.1:{port}/api/pipeline/webhook'`. If `uvicorn` is started directly with `--port <other>` without setting `PORT`, Nextflow webhooks silently fail to reach the backend.

6. **Blocking Synchronous I/O in `async def` Handlers (`web/app.py`)**
   - `run_preflight()` (line 304) calls synchronous `subprocess.run(["which", "nextflow"])` (and `shutil.which("nextflow")` would avoid spawning a subprocess entirely).
   - `open_in_finder()` (line 714) calls synchronous `subprocess.run(["open", ...])`, which also hardcodes macOS `open` without checking `sys.platform == "darwin"`.
   - `get_results_files()` (lines 686–694) runs recursive `rglob()` + `stat()` synchronously on the asyncio event loop.

7. **Unbounded Log Memory & SSE/Polling Sync Bugs**
   - **Backend (`web/app.py:333`):** `state.log_history` appends every stdout/stderr line forever with no cap (e.g., `collections.deque(maxlen=...)`), and `stream_subprocess_output` awaits `q.put(...)` sequentially on subscriber queues—a stalled SSE client can block log reading.
   - **Frontend (`web/static/index.html:2212`):** `box.textContent += data.line` triggers full string reallocation and DOM re-layout on every log line.
   - **Frontend polling stale-status bug (`web/static/index.html:2242`):**
     ```javascript
     if (activeTasksMap.size === 0 || activeTasksMap.size < data.tasks.length) { ... }
     ```
     If an SSE connection drops or misses a `task_update` while the total number of tasks stays the same, `pollStatus()` never updates existing task statuses (`RUNNING` -> `COMPLETED` / `FAILED`).
   - **Frontend `NaN` serialization (`web/static/index.html:1532, 1552-1572`):** Empty numeric inputs parse via `parseInt`/`parseFloat` to `NaN`, which `JSON.stringify` converts to `null`, causing a `422 Unprocessable Entity` from FastAPI while the UI only shows a generic `"Failed to save configuration"` toast.
   - **Frontend focus loss (`web/static/index.html:1644`):** Editing `sample_id` calls `renderSamples()`, destroying and recreating the entire `<tbody>` DOM.

### Low Priority / Code Hygiene

- **Dead code & unused imports:**
  - `web/app.py:5`: unused `import glob`
  - `web/app.py:416`: unused `background_tasks: BackgroundTasks` parameter in `start_pipeline`
  - `web/config_parser.py:6`: unused `EmailStr` import
  - `web/test_app.py:4, 155, 356`: unused `Path`, `update_stats`, `time` imports
  - `web/app.py:389-390` vs `476`: if `stop_pipeline()` sets `state.status = "cancelled"`, `stream_subprocess_output()` later overwrites `state.status = "completed" if rc == 0 else "failed"` when `proc.wait()` finishes.
- **Test coverage gaps (`web/test_app.py`):** No tests exist for `GET/PUT /api/config`, `GET/PUT /api/samplesheet`, `/api/samplesheet/discover`, `/api/preflight`, `/api/pipeline/stop`, `/api/pipeline/stream`, `/api/results/files`, `/api/results/file/{file_path}` (including traversal protection), `reconcile_from_trace_file`, or `parse_experiment_config` edge cases.
- **Static typing & linting:** `manage.sh lint` only runs `py_compile`; adding `ruff` and `mypy`/`pyright` would catch unused imports, broad `except Exception:` blocks (`app.py:130, 462, 483, 716`), and dict schema mismatches automatically.

---

## 5. Prioritized Action Plan

1. **Immediate Security & Correctness Fixes**
   - Change `web/app.py:729` to `target.is_relative_to(results_dir)`.
   - Escape all dynamic values with `escapeHtml()` (or DOM `.textContent`/`.value` APIs) in `renderSamples()`, `renderContrasts()`, and `loadResultsGallery()` in `web/static/index.html`.
   - Convert `ProcessState` (`web/app.py:43-62`) to a `@dataclass` using `field(default_factory=...)` so instances do not share mutable state, and preserve `"cancelled"` status when `stop_pipeline()` triggers termination.
   - Validate `experiment` (slug/filename-safe pattern) and escape serialized Groovy strings in `web/config_parser.py`.
2. **Refactor for SOLID & Testability**
   - Introduce `WorkspaceSettings`, `ConfigRepository`, `SamplesheetRepository`, `PipelineService`, and `TaskRegistry` (using `typing.Protocol` / FastAPI `Depends`) to decouple HTTP routing from filesystem I/O and subprocess management.
   - Standardize a `TaskRecord` Pydantic model across stream parsing, webhooks, and trace TSV reconciliation.
   - Split `ExperimentConfigModel` into cohesive sub-models and add partial contrast/config update endpoints.
   - Extract CSS and JS out of `web/static/index.html` into separate static modules (or a typed frontend build), fix `pollStatus()` task status updates, and cap log buffer sizes on both client and server.
3. **Expand Automated Quality Gates**
   - Add FastAPI `TestClient` / `httpx.AsyncClient` integration tests using `tmp_path`-injected dependencies covering config, samplesheet, preflight, stop, SSE streaming, trace reconciliation, and results sandboxing.
   - Add `ruff` and `mypy` (or `pyright`) to `web/pyproject.toml` dev dependencies and wire them into `manage.sh lint`.

