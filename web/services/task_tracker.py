"""Task state tracking, log broadcasting, and Nextflow trace reconciliation."""

from __future__ import annotations

import asyncio
import csv
import re
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from models import PipelineStats, TaskRecord

NEXTFLOW_SENTINEL_EXIT = 2147483647
DEFAULT_LOG_HISTORY_LIMIT = 5000
DEFAULT_SUBSCRIBER_QUEUE_SIZE = 1000

PROCESS_STREAM_RE = re.compile(
    r"\[([a-f0-9]{2}/[a-f0-9]{6})\]\s+(Cached|Submitted)\s+process\s*>\s*([^\s(]+)(?:\s*\(([^)]+)\))?"
)
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")


def _parse_cpu_percent(raw: Any) -> float:
    if raw is None:
        return 0.0
    if isinstance(raw, (int, float)):
        return float(raw)
    cleaned = str(raw).replace("%", "").strip()
    try:
        return float(cleaned)
    except ValueError:
        return 0.0


def _parse_exit_code(raw_exit: Any, status: str) -> int | None:
    if raw_exit is None or status in ("SUBMITTED", "RUNNING"):
        return None
    try:
        parsed = int(raw_exit)
    except (TypeError, ValueError):
        return None
    if parsed == NEXTFLOW_SENTINEL_EXIT:
        return None
    return parsed


def _split_process_name(process_full: str) -> str:
    return process_full.split(":")[-1] if ":" in process_full else process_full


class LogBroadcaster:
    """Bounded log buffer and non-blocking SSE subscriber fan-out."""

    def __init__(self, max_history: int = DEFAULT_LOG_HISTORY_LIMIT) -> None:
        self._history: deque[str] = deque(maxlen=max_history)
        self._subscribers: list[asyncio.Queue[dict[str, Any] | None]] = []
        self._closed: bool = False

    @property
    def closed(self) -> bool:
        return self._closed

    @property
    def history(self) -> list[str]:
        return list(self._history)

    @property
    def history_count(self) -> int:
        return len(self._history)

    def clear_history(self) -> None:
        self._history.clear()

    def append_log(self, line: str) -> None:
        self._history.append(line)

    def subscribe(self) -> asyncio.Queue[dict[str, Any] | None]:
        queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue(
            maxsize=DEFAULT_SUBSCRIBER_QUEUE_SIZE
        )
        if self._closed:
            queue.put_nowait(None)
            return queue
        self._subscribers.append(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue[dict[str, Any] | None]) -> None:
        if queue in self._subscribers:
            self._subscribers.remove(queue)

    def close(self) -> None:
        """Signal all active SSE subscribers to terminate immediately."""
        self._closed = True
        for queue in list(self._subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(None)
            except asyncio.QueueFull:
                pass

    async def publish(self, message: dict[str, Any]) -> None:
        """Broadcast message to all subscribers, dropping oldest item if a slow consumer fills."""
        if self._closed:
            return
        for queue in list(self._subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(message)
            except asyncio.QueueFull:
                pass


@dataclass
class TaskTracker:
    """Isolated per-instance execution state and task metrics."""

    status: str = "idle"
    return_code: int | None = None
    run_name: str | None = None
    start_time: float | None = None
    end_time: float | None = None
    cancel_requested: bool = False
    reported_total: int = 0
    reported_cached: int = 0
    tasks: dict[str, dict[str, Any]] = field(default_factory=dict)
    stats: dict[str, Any] = field(default_factory=lambda: PipelineStats().model_dump())

    def reset_for_run(self, start_time: float) -> None:
        self.tasks.clear()
        self.run_name = None
        self.start_time = start_time
        self.end_time = None
        self.return_code = None
        self.cancel_requested = False
        self.reported_total = 0
        self.reported_cached = 0
        self.status = "running"
        self.stats = PipelineStats().model_dump()

    def compute_stats(self) -> dict[str, Any]:
        total = max(len(self.tasks), self.reported_total)
        submitted = sum(1 for t in self.tasks.values() if t.get("status") == "SUBMITTED")
        running = sum(1 for t in self.tasks.values() if t.get("status") == "RUNNING")
        cached = max(sum(1 for t in self.tasks.values() if t.get("status") == "CACHED"), self.reported_cached)
        completed = max(
            sum(1 for t in self.tasks.values() if t.get("status") in ("COMPLETED", "CACHED")),
            cached if self.status == "completed" else 0,
        )
        failed = sum(
            1
            for t in self.tasks.values()
            if t.get("status") in ("FAILED", "ABORTED")
            or (
                t.get("status") not in ("SUBMITTED", "RUNNING", "CACHED")
                and t.get("exit") is not None
                and t.get("exit") not in (0, NEXTFLOW_SENTINEL_EXIT)
            )
        )
        percent = (completed / total * 100) if total > 0 else (100.0 if self.status == "completed" else 0.0)
        self.stats = PipelineStats(
            total=total,
            submitted=submitted,
            running=running,
            completed=completed,
            cached=cached,
            failed=failed,
            percent=round(percent, 1),
            run_name=self.run_name,
        ).model_dump()
        return self.stats

    def upsert_from_stream_line(self, line: str) -> dict[str, Any] | None:
        """Parse a Nextflow stdout/stderr process announcement and update task state."""
        match = PROCESS_STREAM_RE.search(line)
        if not match:
            return None
        task_hash, action, proc_full, tag = match.groups()
        tag = tag or ""
        status = "CACHED" if action == "Cached" else "SUBMITTED"

        if task_hash in self.tasks:
            self.tasks[task_hash]["status"] = status
            if status == "CACHED" and self.tasks[task_hash].get("exit") is None:
                self.tasks[task_hash]["exit"] = 0
        else:
            record = TaskRecord(
                task_id=task_hash,
                key=task_hash,
                name=f"{proc_full} ({tag})" if tag else proc_full,
                process=proc_full,
                process_short=_split_process_name(proc_full),
                tag=tag,
                hash=task_hash,
                status=status,
                exit=0 if status == "CACHED" else None,
                realtime=0 if status == "CACHED" else None,
                cpu_percent=0.0,
                peak_rss=0,
                workdir="",
            )
            self.tasks[task_hash] = record.model_dump()
        self.compute_stats()
        return self.tasks[task_hash]

    def upsert_from_webhook_trace(self, trace: dict[str, Any]) -> dict[str, Any]:
        """Normalize and store a task record from a Nextflow weblog trace payload."""
        task_hash = str(trace.get("hash") or "")
        task_id = trace.get("task_id")
        task_key = task_hash or f"task_{task_id}"
        process_full = str(trace.get("process") or "")
        status = str(trace.get("status") or "SUBMITTED")
        exit_code = _parse_exit_code(trace.get("exit"), status)

        record = TaskRecord(
            task_id=str(task_id if task_id is not None else task_key),
            key=task_key,
            name=str(trace.get("name") or f"Task {task_id}"),
            process=process_full,
            process_short=_split_process_name(process_full),
            tag=str(trace.get("tag") or ""),
            hash=task_hash,
            status=status,
            exit=exit_code,
            realtime=trace.get("realtime"),
            cpu_percent=_parse_cpu_percent(trace.get("%cpu")),
            peak_rss=trace.get("peak_rss") or "",
            workdir=str(trace.get("workdir") or ""),
        )
        task_dict = record.model_dump()
        self.tasks[task_key] = task_dict
        self.compute_stats()
        return task_dict

    def ingest_completed_workflow_stats(self, wf_stats: dict[str, Any]) -> None:
        """Backfill cached/missed processes reported on workflow completion."""
        for proc in wf_stats.get("processes", []):
            task_hash = proc.get("hash")
            if not task_hash or task_hash in self.tasks:
                continue
            proc_name = str(proc.get("name") or "")
            t_name = str(proc.get("taskName") or "")
            tag_match = re.search(r"\(([^)]+)\)", t_name)
            tag = tag_match.group(1) if tag_match else ""
            is_cached = int(proc.get("cached") or 0) > 0
            record = TaskRecord(
                task_id=str(task_hash),
                key=str(task_hash),
                name=t_name or proc_name,
                process=proc_name,
                process_short=_split_process_name(proc_name),
                tag=tag,
                hash=str(task_hash),
                status="CACHED" if is_cached else "COMPLETED",
                exit=0,
                realtime=0,
                cpu_percent=0.0,
                peak_rss=0,
                workdir=str(proc.get("workDir") or ""),
            )
            self.tasks[str(task_hash)] = record.model_dump()

    def reconcile_from_trace_file(self, pipeline_info_dir: Path) -> None:
        """Reconcile task metrics from the latest Nextflow execution_trace_*.txt file."""
        if self.start_time is None or not pipeline_info_dir.exists():
            return
        trace_files = sorted(
            pipeline_info_dir.glob("execution_trace_*.txt"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if not trace_files:
            return
        latest_trace = trace_files[0]
        if latest_trace.stat().st_mtime < (self.start_time - 15):
            return

        with open(latest_trace, encoding="utf-8") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            for row in reader:
                task_hash = row.get("hash", "")
                if not task_hash:
                    continue
                name = row.get("name", "")
                tag_match = re.search(r"\(([^)]+)\)", name)
                tag = tag_match.group(1) if tag_match else ""
                proc_full = name.split(" (")[0] if " (" in name else name
                status = row.get("status", "COMPLETED")
                if status not in ("CACHED", "COMPLETED", "FAILED"):
                    status = "COMPLETED"

                raw_exit = row.get("exit")
                if raw_exit and raw_exit.isdigit() and int(raw_exit) != NEXTFLOW_SENTINEL_EXIT:
                    exit_code: int | None = int(raw_exit)
                else:
                    exit_code = 0 if status in ("COMPLETED", "CACHED") else None

                record = TaskRecord(
                    task_id=row.get("task_id") or task_hash,
                    key=task_hash,
                    name=name,
                    process=proc_full,
                    process_short=_split_process_name(proc_full),
                    tag=tag,
                    hash=task_hash,
                    status=status,
                    exit=exit_code,
                    duration=row.get("duration") or "",
                    realtime_fmt=row.get("realtime") or "",
                    cpu_percent=_parse_cpu_percent(row.get("%cpu")),
                    peak_rss=row.get("peak_rss") or "",
                    workdir="",
                )
                self.tasks[task_hash] = record.model_dump()
        self.compute_stats()
