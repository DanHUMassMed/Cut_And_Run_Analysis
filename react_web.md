# Migrating `web/` to a React Frontend: Architecture Assessment & Phased Plan

## 1. Current State Summary

Based on inspection of [web/](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web) and [manage.sh](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/manage.sh):

- **Backend (`web/`)**: FastAPI + Pydantic v2 managed via `uv` (~1,650 lines of Python across [app.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/app.py), [models.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/models.py), [config_parser.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/config_parser.py), [repositories.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/repositories.py), `routes/*.py`, `services/*.py`, plus 701 lines in [test_app.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/test_app.py)).
- **Frontend (`web/static/`)**: Zero-build vanilla ES modules, semantic HTML5, and CSS (~3,816 lines total):
  - [index.html](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/index.html): 765 lines
  - [styles.css](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/css/styles.css): 1,192 lines
  - `web/static/js/*.js`: 10 modules totaling 1,859 lines (largest: [monitor.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/monitor.js) at 593 lines)
- **Deployment Model**: Single local `uvicorn` process bound to `127.0.0.1:${PORT}` (default `8000`), managed by [manage.sh](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/manage.sh), [launch_gui.command](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/launch_gui.command), and the macOS `Cut_and_Run_Control_Center.app` bundle ([scripts/app_launcher.sh](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/scripts/app_launcher.sh)). FastAPI serves `/` and `/static` directly—no Node.js, reverse proxy, or CORS configuration is needed at runtime.

---

## 2. Can We Keep Deployment Simple with React?

**Yes.** Moving to React does **not** require running two servers in production or introducing nginx/Docker.

The simple deployment pattern is **static-bundle embedding**:
1. Build the Vite + React + TypeScript app (`web/frontend/`) into static assets (`dist/`).
2. Have FastAPI (`web/app.py`) mount the compiled assets and serve `dist/index.html` on `/` (just as it currently serves `web/static/index.html`).
3. Keep `./manage.sh start`, `./manage.sh stop`, `launch_gui.command`, and `Cut_and_Run_Control_Center.app` launching **one** `uvicorn` process on `127.0.0.1:8000`.

### The One Deployment Trade-off to Decide Up Front
End-users running the pipeline on a lab workstation should not need Node.js installed just to start the GUI. You have two ways to handle `dist/`:
- **Option A (Simplest for end-users):** Commit the built `dist/` (or build it in a release step) so `./manage.sh install` and `./manage.sh start` remain **100% Python/`uv`-only** at runtime. Only developers editing the UI need Node.js.
- **Option B (Cleaner git history):** Require Node.js/npm during `./manage.sh install` to run `npm ci && npm run build`. Simpler git diffs, but adds a Node.js prerequisite to every machine that installs from source.

---

## 3. Honest Architecture Decision

### Verdict: **Do NOT migrate to React right now — unless you have major interactive UI features planned.**

For the current scope of the CUT&RUN Control Center, migrating ~1,860 lines of clean, working vanilla ES modules to React + Vite is **over-engineering**. The deployment *can* stay simple for end-users, but the **developer and repository complexity** increases immediately for marginal gain.

### Pros of Moving to React (Vite + TypeScript)
1. **Declarative state vs. imperative DOM sync:** Eliminates manual DOM reconciliation in [samplesheet.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/samplesheet.js) (e.g., `refreshAllControlSelects()`), [contrasts.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/contrasts.js), and [monitor.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/monitor.js) (593 lines of manual element creation, timers, and `appState.activeTasksMap` mutations). Contrast dropdowns naturally derive from `sampleRows` state.
2. **End-to-end type safety:** TypeScript interfaces (or types generated from FastAPI's OpenAPI schema via `openapi-typescript`) catch payload mismatches against [models.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/models.py) at compile time instead of runtime.
3. **Ecosystem for future rich UI:** If you later add an interactive Nextflow DAG viewer, interactive QC plots (Plotly/Recharts), IGV.js track previews, or complex multi-step wizards, React makes those dramatically easier to build and maintain.
4. **Component-level testing:** Enables fast UI unit/integration tests (Vitest + React Testing Library), whereas today only the Python backend is tested in [test_app.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/test_app.py).

### Cons of Moving to React (Vite + TypeScript)
1. **Toolchain & dependency overhead:** Introduces Node.js, `package.json`, `package-lock.json`, `node_modules` (hundreds of MB), Vite, ESLint/TypeScript configs, and ongoing npm dependency/security maintenance—where today there are **zero** frontend dependencies.
2. **Two-process dev workflow:** `./manage.sh dev` currently runs a single `uvicorn --reload` command. With Vite, local UI development requires running both FastAPI (`8000`) and Vite (`5173` with `/api` proxy), or running `vite build --watch`.
3. **Build artifact friction:** Either `dist/` is committed to git (creating noisy minified bundle diffs on every UI change) or every user installing from source must have Node.js installed.
4. **Migration cost with zero immediate user-facing value:** Rewriting 5 tabs, 4 modals, SSE streaming, and 1,192 lines of CSS into React components takes meaningful effort and risks regressions in working features (`monitor.js` SSE/polling fallback, workspace switching, native `<dialog>` behavior) without adding new scientific or pipeline capabilities.

### Recommendation
- **If the UI is mostly feature-complete** (forms, samplesheet/contrasts tables, SSE log/task monitor, results gallery): **Stay on vanilla ES modules.** If you want better type safety without React, you can add JSDoc type annotations + `tsc --noEmit --checkJs` as an optional dev check with zero runtime or build changes.
- **If you are actively expanding the UI** into a richer bioinformatics workbench (interactive plots, DAG visualization, drag-and-drop experiment builders): **Proceed with the phased React + Vite + TypeScript migration below**, using **Option A** (serving prebuilt `dist/` from FastAPI) to preserve single-process deployment.

---

## 4. Phased Migration Plan (FastAPI Backend Unchanged)

### Phase 0: Backend API & Build-Strategy Prep (No UI changes)
- **Audit OpenAPI schemas:** Ensure every FastAPI endpoint (including `/api/health` and `/api/server/shutdown` in [app.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/app.py)) has explicit Pydantic `response_model` definitions so OpenAPI type generation is complete.
- **Keep `/api/*` contract frozen:** No breaking changes to `routes/config.py`, `routes/samplesheet.py`, `routes/pipeline.py`, `routes/results.py`, or `routes/workspace.py`.
- **Choose artifact strategy:** Decide between committing `web/frontend/dist` (zero-Node runtime/install) vs. building in `./manage.sh install`.

### Phase 1: Scaffold Vite + React + TS & Single-Origin Serving
- Initialize `web/frontend/` with Vite (`react-ts` template), strict TypeScript (`"strict": true`, no `any`).
- Configure `vite.config.ts`:
  - `server.proxy` forwarding `/api` to `http://127.0.0.1:8000` (ensure SSE `/api/pipeline/stream` is not buffered).
  - `build.outDir` pointing to `../static_dist` (or `web/frontend/dist`).
- Update [settings.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/settings.py) and [app.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/app.py) to serve the React build (`StaticFiles` for `/assets`, `FileResponse` for `index.html`), keeping a toggle/fallback to `web/static` until Phase 5 cutover.
- Generate typed API client from `/openapi.json` (`openapi-typescript`) + a small typed `apiFetch` wrapper matching [api.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/api.js) error formatting.

### Phase 2: App Shell, Workspace Switcher & Configuration Tab
- Port layout shell: `<Header />` (workspace pill, status badge, Pre-Flight / Launch / Stop / Quit buttons), tab bar, toast provider, and reusable `<Dialog />` wrapper.
- Port `WorkspaceModal` (`/api/workspace`, `/api/workspace/select`, `/api/workspace/list-dirs`) and the workspace-switch reload flow.
- Port `ConfigurationTab` (`configForm` state, HTML5/Pydantic validation feedback, `/api/config` `GET`/`PUT`).

### Phase 3: Samplesheet & Contrasts (Unified React State)
- Lift `sampleRows` and `contrastRows` into shared React state/context so `ContrastsTab` derives its condition/target options directly from `sampleRows` (replacing manual `refreshAllControlSelects()` and `renderContrasts()` calls).
- Port `SamplesheetTab` (`/api/samplesheet` `GET`/`PUT`, `/api/samplesheet/discover`) and `ContrastsTab` (`/api/config/contrasts` `PATCH`).

### Phase 4: Pipeline Monitor, SSE Stream & Action Modals
- Extract focused custom hooks:
  - `usePipelineStream`: manages `EventSource('/api/pipeline/stream')` lifecycle, `init_state`, `task_update`, `run_started`, `run_completed`, `process_exit`, `log` buffer, and clean teardown on workspace switch.
  - `usePipelineStatus`: 2s fallback polling of `/api/pipeline/status` and server-stopped detection.
  - `useElapsedTimer`: `start_time` / `end_time` synchronization.
- Port `MonitorTab` (stats cards, task table, log viewer with copy/clear) and `PreflightModal`, `LaunchModal`, `StopModal`, `QuitServerModal`.

### Phase 5: Results & QC Gallery, Tooling & Cutover
- Port `ResultsTab` (`/api/results/files`, `/api/results/open-finder`, `/api/results/file/{path}`, category filtering).
- Update [manage.sh](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/manage.sh) (and add a root `Makefile` if desired) with `frontend-build`, `frontend-dev`, `lint`, and `test` targets.
- Remove legacy `web/static/index.html` and `web/static/js/*.js`, switch `app.py` unconditionally to the built React bundle, and verify `./manage.sh start`, `launch_gui.command`, and `Cut_and_Run_Control_Center.app` end-to-end.

