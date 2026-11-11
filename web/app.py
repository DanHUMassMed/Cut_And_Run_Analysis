"""FastAPI Application for CUT&RUN Pipeline Control Center."""

import asyncio
import csv
import glob
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, AsyncGenerator, Optional

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.responses import FileResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from config_parser import (
    ExperimentConfigModel,
    parse_experiment_config,
    serialize_experiment_config,
)

PIPELINE_DIR = Path(__file__).resolve().parent.parent

# Default workspace points to the experiment Analysis_Run directory, or can be overridden via ANALYSIS_DIR env var
DEFAULT_ANALYSIS_RUN = PIPELINE_DIR.parent / "Experiment_Cut_Run_103026" / "Analysis_Run"
WORKSPACE_DIR = Path(os.environ.get("ANALYSIS_DIR", str(DEFAULT_ANALYSIS_RUN))).resolve()

CONFIG_PATH = WORKSPACE_DIR / "config" / "experiment.config"
SAMPLESHEET_PATH = WORKSPACE_DIR / "config" / "samplesheet.csv"
RUN_SH_PATH = WORKSPACE_DIR / "run.sh"

app = FastAPI(title="CUT&RUN Control Center", version="2.0.0")

# Mount static files
STATIC_DIR = Path(__file__).resolve().parent / "static"
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


class ProcessState:
    process: Optional[asyncio.subprocess.Process] = None
    status: str = "idle"  # idle, running, completed, failed, cancelled
    return_code: Optional[int] = None
    log_history: list[str] = []
    subscribers: list[asyncio.Queue] = []
    task: Optional[asyncio.Task] = None
    run_name: Optional[str] = None
    start_time: Optional[float] = None
    end_time: Optional[float] = None
    tasks: dict[str, dict[str, Any]] = {}
    stats: dict[str, Any] = {
        "total": 0,
        "submitted": 0,
        "running": 0,
        "completed": 0,
        "cached": 0,
        "failed": 0,
        "percent": 0.0,
    }


state = ProcessState()

PROCESS_STREAM_RE = re.compile(
    r"\[([a-f0-9]{2}/[a-f0-9]{6})\]\s+(Cached|Submitted)\s+process\s*>\s*([^\s(]+)(?:\s*\(([^)]+)\))?"
)


def reconcile_from_trace_file() -> None:
    if not CONFIG_PATH.exists() or state.start_time is None:
        return
    try:
        cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
        pipeline_info_dir = WORKSPACE_DIR / "results" / cfg.experiment / "pipeline_info"
        if not pipeline_info_dir.exists():
            return
        trace_files = sorted(
            pipeline_info_dir.glob("execution_trace_*.txt"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not trace_files:
            return
        latest_trace = trace_files[0]
        # Ignore trace files created before the current run started
        if latest_trace.stat().st_mtime < (state.start_time - 15):
            return
        with open(latest_trace, "r", encoding="utf-8") as f:
            reader = csv.DictReader(f, delimiter="\t")
            for r in reader:
                task_hash = r.get("hash", "")
                if not task_hash:
                    continue
                name = r.get("name", "")
                tag_match = re.search(r"\(([^)]+)\)", name)
                tag = tag_match.group(1) if tag_match else ""
                proc_full = name.split(" (")[0] if " (" in name else name
                proc_short = proc_full.split(":")[-1] if ":" in proc_full else proc_full
                status = r.get("status", "COMPLETED")
                if status not in ("CACHED", "COMPLETED", "FAILED"):
                    status = "COMPLETED"

                raw_exit = r.get("exit")
                if raw_exit and raw_exit.isdigit() and int(raw_exit) != 2147483647:
                    exit_code = int(raw_exit)
                else:
                    exit_code = 0 if status in ("COMPLETED", "CACHED") else None

                task_data = {
                    "task_id": r.get("task_id") or task_hash,
                    "key": task_hash,
                    "name": name,
                    "process": proc_full,
                    "process_short": proc_short,
                    "tag": tag,
                    "hash": task_hash,
                    "status": status,
                    "exit": exit_code,
                    "duration": r.get("duration") or "",
                    "realtime_fmt": r.get("realtime") or "",
                    "cpu_percent": float(r["%cpu"].replace("%", "")) if r.get("%cpu") and r["%cpu"].replace("%", "").replace(".", "", 1).isdigit() else 0.0,
                    "peak_rss": r.get("peak_rss") or "",
                    "workdir": "",
                }
                state.tasks[task_hash] = task_data
        update_stats()
    except Exception as e:
        print(f"Notice: reconcile_from_trace_file skipped: {e}")


def update_stats() -> dict[str, Any]:
    total = len(state.tasks)
    submitted = sum(1 for t in state.tasks.values() if t["status"] == "SUBMITTED")
    running = sum(1 for t in state.tasks.values() if t["status"] == "RUNNING")
    cached = sum(1 for t in state.tasks.values() if t["status"] == "CACHED")
    completed = sum(
        1 for t in state.tasks.values() if t["status"] in ("COMPLETED", "CACHED")
    )
    failed = sum(
        1
        for t in state.tasks.values()
        if t["status"] in ("FAILED", "ABORTED")
        or (
            t["status"] not in ("SUBMITTED", "RUNNING", "CACHED")
            and t.get("exit") is not None
            and t.get("exit") not in (0, 2147483647)
        )
    )
    percent = (
        (completed / total * 100)
        if total > 0
        else (100.0 if state.status == "completed" else 0.0)
    )
    state.stats = {
        "total": total,
        "submitted": submitted,
        "running": running,
        "completed": completed,
        "cached": cached,
        "failed": failed,
        "percent": round(percent, 1),
        "run_name": state.run_name,
    }
    return state.stats


def ensure_weblog_config(port: int = 8000) -> Path:
    config_dir = WORKSPACE_DIR / ".nextflow"
    config_dir.mkdir(parents=True, exist_ok=True)
    weblog_cfg = config_dir / "weblog.config"
    content = f"""// Auto-generated by CUT&RUN Control Center for real-time progress monitoring
plugins {{
    id 'nf-weblog'
}}
weblog {{
    enabled = true
    url = 'http://127.0.0.1:{port}/api/pipeline/webhook'
}}
"""
    weblog_cfg.write_text(content, encoding="utf-8")
    return weblog_cfg


@app.get("/")
async def get_index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/config")
async def get_config() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        raise HTTPException(status_code=404, detail="experiment.config not found")
    content = CONFIG_PATH.read_text(encoding="utf-8")
    model = parse_experiment_config(content)
    return {"config": model.model_dump(), "raw": content}


@app.put("/api/config")
async def update_config(model: ExperimentConfigModel) -> dict[str, Any]:
    # Make backup
    if CONFIG_PATH.exists():
        bak_path = CONFIG_PATH.with_suffix(".config.bak")
        bak_path.write_text(CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")

    serialized = serialize_experiment_config(model)
    CONFIG_PATH.write_text(serialized, encoding="utf-8")
    return {"status": "ok", "config": model.model_dump()}


@app.get("/api/samplesheet")
async def get_samplesheet() -> dict[str, Any]:
    if not SAMPLESHEET_PATH.exists():
        return {"rows": []}
    rows = []
    with open(SAMPLESHEET_PATH, mode="r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)
    return {"rows": rows}


class SamplesheetPayload(BaseModel):
    rows: list[dict[str, Any]]


@app.put("/api/samplesheet")
async def update_samplesheet(payload: SamplesheetPayload) -> dict[str, Any]:
    fieldnames = ["sample_id", "sample_name", "condition", "target", "replicate", "control_id"]
    if SAMPLESHEET_PATH.exists():
        bak_path = SAMPLESHEET_PATH.with_suffix(".csv.bak")
        bak_path.write_text(SAMPLESHEET_PATH.read_text(encoding="utf-8"), encoding="utf-8")

    with open(SAMPLESHEET_PATH, mode="w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in payload.rows:
            cleaned = {k: row.get(k, "") for k in fieldnames}
            writer.writerow(cleaned)
    return {"status": "ok", "count": len(payload.rows)}


@app.post("/api/samplesheet/discover")
async def discover_samples() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        raise HTTPException(status_code=400, detail="Config file missing")
    cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
    input_dir = Path(cfg.input_dir)
    bam_dir = input_dir / "06_index_bam"
    if not bam_dir.exists():
        return {"discovered": [], "error": f"Path not found: {bam_dir}"}

    bams = sorted(bam_dir.glob("*.bam"))
    sample_ids = [p.stem for p in bams]
    return {"discovered": sample_ids}


@app.post("/api/preflight")
async def run_preflight() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        return {"ready": False, "checks": [{"name": "Config file exists", "status": "failed", "detail": "experiment.config missing"}]}

    cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
    checks = []

    # 1. Input dir exists
    input_dir = Path(cfg.input_dir)
    if input_dir.exists():
        checks.append({"name": "Input Directory", "status": "ok", "detail": str(input_dir)})
    else:
        checks.append({"name": "Input Directory", "status": "failed", "detail": f"Path does not exist: {input_dir}"})

    # 2. Check bam files
    bam_files = list(input_dir.glob("06_index_bam/*.bam")) if input_dir.exists() else []
    if bam_files:
        checks.append({"name": "Input BAMs (06_index_bam)", "status": "ok", "detail": f"Found {len(bam_files)} BAM file(s)"})
    else:
        checks.append({"name": "Input BAMs (06_index_bam)", "status": "warning", "detail": "No BAM files found in 06_index_bam/"})

    # 3. Check BigWig files
    bw_files = list(input_dir.glob(f"08_bigwig/{cfg.bigwig_source}/*.bw")) if input_dir.exists() else []
    if bw_files:
        checks.append({"name": f"BigWigs (08_bigwig/{cfg.bigwig_source})", "status": "ok", "detail": f"Found {len(bw_files)} BigWig file(s)"})
    else:
        checks.append({"name": f"BigWigs (08_bigwig/{cfg.bigwig_source})", "status": "warning", "detail": f"No BigWig files found in 08_bigwig/{cfg.bigwig_source}"})

    # 4. Check HOMER tag directories
    tag_dirs = [p for p in (input_dir / "07_homer" / "tag_dir").glob("*") if p.is_dir()] if input_dir.exists() else []
    if tag_dirs:
        checks.append({"name": "HOMER Tag Dirs (07_homer/tag_dir)", "status": "ok", "detail": f"Found {len(tag_dirs)} tag directory(ies)"})
    else:
        checks.append({"name": "HOMER Tag Dirs (07_homer/tag_dir)", "status": "warning", "detail": "No tag directories found in 07_homer/tag_dir"})

    # 5. Check Nextflow binary
    has_nextflow = bool(subprocess.run(["which", "nextflow"], capture_output=True).returncode == 0)
    if has_nextflow:
        checks.append({"name": "Nextflow Engine", "status": "ok", "detail": "Nextflow is installed and executable"})
    else:
        checks.append({"name": "Nextflow Engine", "status": "failed", "detail": "Nextflow not found in PATH"})

    # 6. Check Nextflow lock
    locks = list((WORKSPACE_DIR / ".nextflow" / "cache").glob("*/db/LOCK")) if (WORKSPACE_DIR / ".nextflow" / "cache").exists() else []
    if locks:
        checks.append({"name": "Nextflow Session Lock", "status": "warning", "detail": f"{len(locks)} active/stale lock file(s) in .nextflow/cache/"})
    else:
        checks.append({"name": "Nextflow Session Lock", "status": "ok", "detail": "No active locks found"})

    ready = all(c["status"] != "failed" for c in checks)
    return {"ready": ready, "checks": checks, "workspace": str(WORKSPACE_DIR)}


async def stream_subprocess_output(proc: asyncio.subprocess.Process) -> None:
    state.status = "running"
    state.return_code = None

    async def read_stream(stream: asyncio.StreamReader) -> None:
        while True:
            line = await stream.readline()
            if not line:
                break
            text = line.decode("utf-8", errors="replace")
            # Strip ANSI escape sequences if any remain
            clean_text = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)
            state.log_history.append(clean_text)

            # Check for process announcements (Cached or Submitted) from Nextflow stdout/stderr
            m_proc = PROCESS_STREAM_RE.search(clean_text)
            if m_proc:
                task_hash, action, proc_full, tag = m_proc.groups()
                tag = tag or ""
                proc_short = proc_full.split(":")[-1] if ":" in proc_full else proc_full
                status = "CACHED" if action == "Cached" else "SUBMITTED"

                if task_hash in state.tasks:
                    state.tasks[task_hash]["status"] = status
                else:
                    state.tasks[task_hash] = {
                        "task_id": task_hash,
                        "key": task_hash,
                        "name": f"{proc_full} ({tag})" if tag else proc_full,
                        "process": proc_full,
                        "process_short": proc_short,
                        "tag": tag,
                        "hash": task_hash,
                        "status": status,
                        "exit": 0 if status == "CACHED" else None,
                        "realtime": 0 if status == "CACHED" else None,
                        "cpu_percent": 0.0,
                        "peak_rss": 0,
                        "workdir": "",
                    }

                update_stats()
                for q in list(state.subscribers):
                    await q.put({
                        "type": "task_update",
                        "task": state.tasks[task_hash],
                        "stats": state.stats,
                        "run_name": state.run_name,
                    })

            # Dispatch to subscribers
            for q in list(state.subscribers):
                await q.put({"type": "log", "line": clean_text})

    if proc.stdout and proc.stderr:
        await asyncio.gather(
            read_stream(proc.stdout),
            read_stream(proc.stderr),
        )

    rc = await proc.wait()

    # Wait 1.0s to allow any final in-flight HTTP webhooks, process buffers, and trace files to settle
    await asyncio.sleep(1.0)

    # Reconcile from Nextflow's execution trace file for 100% complete metrics
    reconcile_from_trace_file()

    state.return_code = rc
    state.status = "completed" if rc == 0 else "failed"
    state.process = None
    update_stats()

    exit_msg = f"\n[Process exited with code {rc}]\n"
    state.log_history.append(exit_msg)
    for q in list(state.subscribers):
        await q.put({"type": "log", "line": exit_msg})
        await q.put({
            "type": "process_exit",
            "return_code": rc,
            "status": state.status,
            "stats": state.stats,
            "tasks": list(state.tasks.values()),
        })


class PipelineStartPayload(BaseModel):
    resume: bool = True


@app.post("/api/pipeline/start")
async def start_pipeline(payload: PipelineStartPayload, background_tasks: BackgroundTasks) -> dict[str, Any]:
    if state.status == "running" and state.process:
        raise HTTPException(status_code=400, detail="Pipeline is already running")

    # Reset progress tracking state
    state.tasks.clear()
    state.run_name = None
    state.start_time = time.time()
    state.end_time = None
    state.stats = {
        "total": 0,
        "submitted": 0,
        "running": 0,
        "completed": 0,
        "cached": 0,
        "failed": 0,
        "percent": 0.0,
    }
    state.log_history.clear()

    port = int(os.environ.get("PORT", "8000"))
    weblog_cfg = ensure_weblog_config(port)

    # Prepare command with -ansi-log false and weblog config
    cmd = [
        "bash",
        str(RUN_SH_PATH),
        "true" if payload.resume else "false",
        "-ansi-log",
        "false",
        "-c",
        str(weblog_cfg),
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=str(WORKSPACE_DIR),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            preexec_fn=os.setsid,
        )
        state.process = proc
        state.task = asyncio.create_task(stream_subprocess_output(proc))
        return {"status": "started", "pid": proc.pid}
    except Exception as e:
        state.status = "failed"
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/pipeline/stop")
async def stop_pipeline() -> dict[str, Any]:
    if not state.process or state.status != "running":
        return {"status": "not_running"}

    try:
        os.killpg(os.getpgid(state.process.pid), signal.SIGINT)
        state.status = "cancelled"
        update_stats()
        return {"status": "stopping"}
    except ProcessLookupError:
        return {"status": "process_already_exited"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/pipeline/webhook")
async def receive_pipeline_webhook(payload: dict[str, Any]) -> dict[str, str]:
    event = payload.get("event")
    run_name = payload.get("runName")
    if run_name and not state.run_name:
        state.run_name = run_name

    trace = payload.get("trace")
    if trace:
        task_hash = trace.get("hash")
        task_id = trace.get("task_id")
        task_key = task_hash or f"task_{task_id}"
        process_full = trace.get("process", "")
        proc_short = process_full.split(":")[-1] if ":" in process_full else process_full
        status = trace.get("status", "SUBMITTED")

        raw_exit = trace.get("exit")
        exit_code: Optional[int] = None
        if raw_exit is not None:
            try:
                parsed_exit = int(raw_exit)
                # Nextflow initializes uncompleted tasks to Integer.MAX_VALUE (2147483647)
                if parsed_exit != 2147483647 and status not in ("SUBMITTED", "RUNNING"):
                    exit_code = parsed_exit
            except (ValueError, TypeError):
                exit_code = None

        task_data = {
            "task_id": task_id or task_key,
            "key": task_key,
            "name": trace.get("name", f"Task {task_id}"),
            "process": process_full,
            "process_short": proc_short,
            "tag": trace.get("tag") or "",
            "hash": task_hash or "",
            "status": status,
            "exit": exit_code,
            "realtime": trace.get("realtime"),
            "cpu_percent": trace.get("%cpu"),
            "peak_rss": trace.get("peak_rss"),
            "workdir": trace.get("workdir"),
        }
        state.tasks[task_key] = task_data
        update_stats()

        broadcast_msg = {
            "type": "task_update",
            "task": task_data,
            "stats": state.stats,
            "run_name": state.run_name,
        }
        for q in list(state.subscribers):
            await q.put(broadcast_msg)

    elif event == "started":
        state.run_name = run_name
        if state.start_time is None:
            state.start_time = time.time()
        update_stats()
        broadcast_msg = {
            "type": "run_started",
            "run_name": run_name,
            "stats": state.stats,
        }
        for q in list(state.subscribers):
            await q.put(broadcast_msg)

    elif event == "completed":
        wf = payload.get("metadata", {}).get("workflow", {})
        success = wf.get("success", True)
        wf_stats = wf.get("stats", {})
        state.end_time = asyncio.get_event_loop().time()

        # Ingest any processes from Nextflow workflow stats that were cached or missed
        for proc in wf_stats.get("processes", []):
            task_hash = proc.get("hash")
            if task_hash and task_hash not in state.tasks:
                proc_name = proc.get("name", "")
                proc_short = proc_name.split(":")[-1] if ":" in proc_name else proc_name
                t_name = proc.get("taskName", "")
                tag_match = re.search(r"\(([^)]+)\)", t_name)
                tag = tag_match.group(1) if tag_match else ""
                is_cached = proc.get("cached", 0) > 0
                state.tasks[task_hash] = {
                    "task_id": task_hash,
                    "key": task_hash,
                    "name": t_name or proc_name,
                    "process": proc_name,
                    "process_short": proc_short,
                    "tag": tag,
                    "hash": task_hash,
                    "status": "CACHED" if is_cached else "COMPLETED",
                    "exit": 0,
                    "realtime": 0,
                    "cpu_percent": 0.0,
                    "peak_rss": 0,
                    "workdir": proc.get("workDir") or "",
                }

        reconcile_from_trace_file()
        update_stats()

        # Fallback sync if Nextflow reports counts directly
        nf_cached = wf_stats.get("cachedCount", 0)
        nf_total = wf_stats.get("totalCount", len(state.tasks))
        if nf_cached > state.stats["cached"]:
            state.stats["cached"] = nf_cached
        if nf_total > state.stats["total"]:
            state.stats["total"] = nf_total
        if success and state.stats["total"] > 0:
            state.stats["completed"] = state.stats["total"]
            state.stats["percent"] = 100.0

        broadcast_msg = {
            "type": "run_completed",
            "success": success,
            "stats": state.stats,
            "tasks": list(state.tasks.values()),
        }
        for q in list(state.subscribers):
            await q.put(broadcast_msg)

    return {"status": "ok"}

    return {"status": "ok"}


@app.get("/api/pipeline/status")
async def get_pipeline_status() -> dict[str, Any]:
    update_stats()
    return {
        "status": state.status,
        "pid": state.process.pid if state.process else None,
        "return_code": state.return_code,
        "log_lines_count": len(state.log_history),
        "run_name": state.run_name,
        "stats": state.stats,
        "tasks": list(state.tasks.values()),
    }


@app.get("/api/pipeline/stream")
async def get_log_stream() -> StreamingResponse:
    queue: asyncio.Queue = asyncio.Queue()
    state.subscribers.append(queue)

    async def event_generator() -> AsyncGenerator[str, None]:
        try:
            # First send initial snapshot
            init_payload = {
                "type": "init_state",
                "status": state.status,
                "run_name": state.run_name,
                "stats": state.stats,
                "tasks": list(state.tasks.values()),
            }
            yield f"data: {json.dumps(init_payload)}\n\n"

            # Then send existing logs
            for line in state.log_history:
                yield f"data: {json.dumps({'type': 'log', 'line': line})}\n\n"

            while True:
                msg = await queue.get()
                if isinstance(msg, dict):
                    yield f"data: {json.dumps(msg)}\n\n"
                else:
                    yield f"data: {json.dumps({'type': 'log', 'line': str(msg)})}\n\n"
        except asyncio.CancelledError:
            pass
        finally:
            if queue in state.subscribers:
                state.subscribers.remove(queue)

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@app.get("/api/results/files")
async def get_results_files() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        return {"files": [], "results_dir": ""}
    cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
    results_dir = (WORKSPACE_DIR / "results" / cfg.experiment).resolve()
    if not results_dir.exists():
        return {
            "files": [],
            "experiment": cfg.experiment,
            "results_dir": str(results_dir),
            "exists": False
        }

    matched_files = []
    for ext in ("*.png", "*.svg", "*.tsv", "*.txt", "*.pdf", "*.html"):
        for f in results_dir.rglob(ext):
            rel = f.relative_to(results_dir)
            matched_files.append({
                "path": str(rel),
                "name": f.name,
                "category": rel.parts[0] if len(rel.parts) > 1 else "general",
                "subfolder": str(rel.parent) if str(rel.parent) != "." else "",
                "size": f.stat().st_size,
            })

    return {
        "files": matched_files,
        "experiment": cfg.experiment,
        "results_dir": str(results_dir),
        "exists": True
    }


@app.post("/api/results/open-finder")
async def open_in_finder() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        raise HTTPException(status_code=404, detail="Config not found")
    cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
    results_dir = (WORKSPACE_DIR / "results" / cfg.experiment).resolve()
    if not results_dir.exists():
        results_dir = (WORKSPACE_DIR / "results").resolve()
    
    try:
        subprocess.run(["open", str(results_dir)], check=True)
        return {"status": "ok", "path": str(results_dir)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/results/file/{file_path:path}")
async def serve_result_file(file_path: str):
    if not CONFIG_PATH.exists():
        raise HTTPException(status_code=404, detail="Config not found")
    cfg = parse_experiment_config(CONFIG_PATH.read_text(encoding="utf-8"))
    results_dir = (WORKSPACE_DIR / "results" / cfg.experiment).resolve()
    target = (results_dir / file_path).resolve()

    # Sandboxing check
    if not str(target).startswith(str(results_dir)) or not target.exists() or not target.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    return FileResponse(target)

