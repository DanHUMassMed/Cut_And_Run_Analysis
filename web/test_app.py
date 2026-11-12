"""Unit and integration tests for CUT&RUN Control Center."""

from __future__ import annotations

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from app import create_app
from config_parser import (
    ContrastModel,
    ExperimentConfigModel,
    parse_experiment_config,
    serialize_experiment_config,
)
from dependencies import AppContainer
from services.pipeline_runner import SubprocessHandle
from services.task_tracker import PROCESS_STREAM_RE, TaskTracker
from settings import WorkspaceSettings

SAMPLE_CONFIG = """
params {
    email                          = "test.user@umassmed.edu"
    experiment                     = "exp_test_01"
    input_dir                      = "/path/to/dropbox"
    bigwig_source                  = "deepTools"
    outdir                         = "${launchDir}/results/${params.experiment}"
    samplesheet                    = "${launchDir}/config/samplesheet.csv"

    run_macs2_callpeak             = true
    run_homer_findpeaks            = false
    run_merge_replicate_peaks      = true
    run_merge_master_peaks         = true
    run_homer_annotatepeaks        = true
    run_homer_diffpeaks            = true
    run_deeptools_metapeak         = false
    run_homer_findmotifs           = false
    run_meme_streme                = false
    run_summary_plots              = true

    active_peak_caller             = "macs2"
    min_replicate_overlap          = 3

    genome_name                    = "ce11"
    homer_dir                      = "${projectDir}/assets/homer_ce11"
    genome_fasta                   = "${projectDir}/assets/homer_ce11/data/genomes/ce11"
    chrom_sizes                    = "${projectDir}/assets/homer_ce11/data/genomes/ce11/chrom.sizes"

    macs2_gsize                    = "ce"
    macs2_format                   = "BAMPE"
    macs2_qvalue                   = 0.05
    macs2_broad                    = true
    macs2_broad_cutoff             = 0.15

    homer_peak_style               = "factor"
    annotatepeaks_size             = "given"

    diff_contrasts                 = [
        [ id: 'C1', treatment: 'T1', background: 'B1', target: 'H3K4me3' ],
        [ id: 'C2', treatment: 'T2', background: 'B2', target: 'H3K27me3' ]
    ]

    metapeak_upstream              = 1500
    metapeak_downstream            = 1500
    metapeak_reference_point       = "center"
    heatmap_colormap               = "viridis"
    heatmap_interpolation          = "bilinear"

    homer_motif_size               = "150"
    meme_slop_left                 = 60
    meme_slop_right                = 59
    meme_streme_nmotifs            = 15

    volcano_fdr_threshold          = 0.01
    volcano_log2fc_threshold       = 1.5
    volcano_top_n_labels           = 10
}
"""


class FakeRunner:
    """In-memory PipelineRunner stub for testing start/stop without spawning OS processes."""

    def __init__(self, return_code: int = 0) -> None:
        self.commands: list[list[str]] = []
        self.cwds: list[Path] = []
        self.interrupted: list[int] = []
        self.return_code = return_code
        self.release_event = asyncio.Event()

    async def spawn(self, cmd: list[str], cwd: Path) -> SubprocessHandle:
        self.commands.append(cmd)
        self.cwds.append(cwd)

        mock_proc = MagicMock()
        mock_proc.pid = 99999
        mock_proc.stdout = AsyncMock()
        mock_proc.stdout.readline = AsyncMock(return_value=b"")
        mock_proc.stderr = AsyncMock()
        mock_proc.stderr.readline = AsyncMock(return_value=b"")

        async def _wait() -> int:
            await self.release_event.wait()
            return self.return_code

        mock_proc.wait = _wait
        return mock_proc  # type: ignore[return-value]

    def interrupt(self, process: SubprocessHandle) -> None:
        self.interrupted.append(process.pid)
        self.release_event.set()


def make_test_settings(tmp_path: Path, port: int | None = 8000) -> WorkspaceSettings:
    workspace = tmp_path / "Analysis_Run"
    (workspace / "config").mkdir(parents=True)
    return WorkspaceSettings(
        pipeline_dir=Path(__file__).resolve().parent.parent,
        workspace_dir=workspace,
        static_dir=Path(__file__).resolve().parent / "static",
        port=port,
        user_config_dir=tmp_path / ".config",
    )


def test_parse_experiment_config() -> None:
    model = parse_experiment_config(SAMPLE_CONFIG)
    assert model.email == "test.user@umassmed.edu"
    assert model.experiment == "exp_test_01"
    assert model.run_homer_findpeaks is False
    assert model.run_macs2_callpeak is True
    assert model.macs2_broad is True
    assert model.min_replicate_overlap == 3
    assert model.resource_cpus == 8
    assert model.resource_memory == "16.GB"
    assert model.resource_time == "72.h"
    assert len(model.diff_contrasts) == 2
    assert model.diff_contrasts[0].id == "C1"
    assert model.diff_contrasts[1].target == "H3K27me3"


def test_parse_and_roundtrip_resource_limits() -> None:
    cfg_text = SAMPLE_CONFIG + """
process {
    resourceLimits = [
        cpus: 12, // max cores
        memory: '32 GB',
        time: 48.h
    ]
}
"""
    model = parse_experiment_config(cfg_text)
    assert model.resource_cpus == 12
    assert model.resource_memory == "32.GB"
    assert model.resource_time == "48.h"

    serialized = serialize_experiment_config(model)
    assert "process {" in serialized
    assert "cpus: 12," in serialized
    assert "memory: 32.GB," in serialized
    assert "time: 48.h" in serialized

    reparsed = parse_experiment_config(serialized)
    assert reparsed.resource_cpus == 12
    assert reparsed.resource_memory == "32.GB"
    assert reparsed.resource_time == "48.h"


def test_resource_limits_validation_rejects_injection_and_zero() -> None:
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="exp_ok", resource_cpus=0)
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="exp_ok", resource_memory="16.GB; System.exit(0)")
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="exp_ok", resource_memory="0.GB")
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="exp_ok", resource_time="72.h\nprintln 'hi'")
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="exp_ok", resource_time="0.h")


def test_roundtrip_serialization() -> None:
    model = parse_experiment_config(SAMPLE_CONFIG)
    serialized = serialize_experiment_config(model)
    reparsed = parse_experiment_config(serialized)
    assert reparsed.email == model.email
    assert reparsed.experiment == model.experiment
    assert reparsed.diff_contrasts == model.diff_contrasts
    assert reparsed.macs2_qvalue == model.macs2_qvalue


def test_parser_handles_double_slash_in_strings_scientific_float_and_reordered_contrasts() -> None:
    cfg_text = """
    params {
        experiment = "exp_edge_01"
        input_dir = "/mnt/dropbox//run_1" // trailing comment
        macs2_qvalue = 1e-4
        diff_contrasts = [
            [ target: 'H3K27ac', background: 'WT', id: 'Mut_vs_WT', treatment: 'Mut' ]
        ]
    }
    """
    model = parse_experiment_config(cfg_text)
    assert model.input_dir == "/mnt/dropbox//run_1"
    assert model.macs2_qvalue == 1e-4
    assert len(model.diff_contrasts) == 1
    assert model.diff_contrasts[0].id == "Mut_vs_WT"
    assert model.diff_contrasts[0].target == "H3K27ac"


def test_serializer_escapes_groovy_injection_and_validates_experiment() -> None:
    with pytest.raises(ValueError):
        ExperimentConfigModel(experiment="../escape")

    model = ExperimentConfigModel(
        experiment="safe_exp_01",
        input_dir='/data/"quoted"/${System.exit(0)}',
        diff_contrasts=[ContrastModel(id="A'B", treatment="T1", background="B1", target="H3K4me3")],
    )
    serialized = serialize_experiment_config(model)
    assert '\\"quoted\\"' in serialized
    assert "\\${System.exit(0)}" in serialized
    assert "id: 'A\\'B'" in serialized
    # Whitelisted Nextflow variables remain unescaped
    assert "${launchDir}/results/${params.experiment}" in serialized


def test_task_tracker_instances_do_not_share_state() -> None:
    t1 = TaskTracker()
    t2 = TaskTracker()
    t1.upsert_from_stream_line("[ab/123456] Submitted process > CUTANDRUN:FASTQC (s1)")
    assert len(t1.tasks) == 1
    assert len(t2.tasks) == 0


@pytest.mark.anyio
async def test_pipeline_webhook_and_status(tmp_path: Path) -> None:
    app = create_app(settings=make_test_settings(tmp_path), runner=FakeRunner())
    service = app.state.container.pipeline_service

    await service.handle_webhook({"event": "started", "runName": "clever_curie"})
    assert service.tracker.run_name == "clever_curie"

    await service.handle_webhook(
        {
            "event": "process_submitted",
            "runName": "clever_curie",
            "trace": {
                "task_id": 1,
                "name": "CUTANDRUN:PLOT_PEAK_COUNTS (summary)",
                "process": "CUTANDRUN:PLOT_PEAK_COUNTS",
                "tag": "summary",
                "hash": "ab/123456",
                "status": "SUBMITTED",
            },
        }
    )
    assert "ab/123456" in service.tracker.tasks
    assert service.tracker.tasks["ab/123456"]["process_short"] == "PLOT_PEAK_COUNTS"
    assert service.tracker.stats["total"] == 1
    assert service.tracker.stats["submitted"] == 1
    assert service.tracker.stats["completed"] == 0

    await service.handle_webhook(
        {
            "event": "process_completed",
            "runName": "clever_curie",
            "trace": {
                "task_id": 1,
                "name": "CUTANDRUN:PLOT_PEAK_COUNTS (summary)",
                "process": "CUTANDRUN:PLOT_PEAK_COUNTS",
                "tag": "summary",
                "hash": "ab/123456",
                "status": "COMPLETED",
                "exit": 0,
                "realtime": 1500,
            },
        }
    )
    status_resp = service.get_status()
    assert status_resp["run_name"] == "clever_curie"
    assert len(status_resp["tasks"]) == 1
    assert status_resp["stats"]["completed"] == 1
    assert status_resp["stats"]["percent"] == 100.0


@pytest.mark.anyio
async def test_cached_tasks_handling(tmp_path: Path) -> None:
    app = create_app(settings=make_test_settings(tmp_path), runner=FakeRunner())
    service = app.state.container.pipeline_service

    log_line = "[d0/96014c] Cached process > CUTANDRUN:PLOT_PEAK_COUNTS (peak_counts_summary)"
    m = PROCESS_STREAM_RE.search(log_line)
    assert m is not None
    task_hash, action, proc_full, tag = m.groups()
    assert task_hash == "d0/96014c"
    assert action == "Cached"
    assert proc_full == "CUTANDRUN:PLOT_PEAK_COUNTS"
    assert tag == "peak_counts_summary"

    completed_payload = {
        "event": "completed",
        "runName": "wise_perlman",
        "metadata": {
            "workflow": {
                "success": True,
                "stats": {
                    "totalCount": 8,
                    "cachedCount": 8,
                    "succeededCount": 0,
                    "failedCount": 0,
                    "processes": [
                        {
                            "name": "CUTANDRUN:PLOT_PEAK_COUNTS",
                            "taskName": "CUTANDRUN:PLOT_PEAK_COUNTS (peak_counts_summary)",
                            "hash": "d0/96014c",
                            "cached": 1,
                            "workDir": "/path/to/work/d0/...",
                        },
                        {
                            "name": "CUTANDRUN:PLOT_ANNOTATED_SUMMARY",
                            "taskName": "CUTANDRUN:PLOT_ANNOTATED_SUMMARY (H3K4me3)",
                            "hash": "38/8e17bc",
                            "cached": 2,
                            "workDir": "/path/to/work/38/...",
                        },
                    ],
                },
            }
        },
    }

    await service.handle_webhook(completed_payload)
    status = service.get_status()
    assert status["stats"]["cached"] >= 2
    assert status["stats"]["total"] == 8
    assert status["stats"]["percent"] == 100.0
    assert len(status["tasks"]) >= 2
    assert status["tasks"][0]["status"] == "CACHED"


@pytest.mark.anyio
async def test_mixed_cached_and_submitted_no_collision(tmp_path: Path) -> None:
    app = create_app(settings=make_test_settings(tmp_path), runner=FakeRunner())
    service = app.state.container.pipeline_service

    cached_lines = [
        "[38/8e17bc] Cached process > CUTANDRUN:PLOT_ANNOTATED_SUMMARY (H3K4me3)",
        "[b2/2102b3] Cached process > CUTANDRUN:DEEPTOOLS_METAPEAK (H3K27me3)",
        "[d0/96014c] Cached process > CUTANDRUN:PLOT_PEAK_COUNTS (peak_counts_summary)",
        "[db/38aae7] Cached process > CUTANDRUN:DEEPTOOLS_METAPEAK (H3K4me3)",
        "[c0/1a91a2] Cached process > CUTANDRUN:PLOT_ANNOTATED_SUMMARY (H3K27me3)",
    ]
    for line in cached_lines:
        service.tracker.upsert_from_stream_line(line)

    submitted_traces = [
        {"task_id": 1, "hash": "26/f6a79c", "name": "VOLCANO_1", "status": "COMPLETED"},
        {"task_id": 2, "hash": "4c/9471dd", "name": "VOLCANO_2", "status": "COMPLETED"},
        {"task_id": 3, "hash": "28/25c816", "name": "VOLCANO_3", "status": "COMPLETED"},
    ]
    for tr in submitted_traces:
        await service.handle_webhook({"event": "process_completed", "trace": tr})

    status = service.get_status()
    assert len(status["tasks"]) == 8
    assert service.tracker.tasks["b2/2102b3"]["status"] == "CACHED"
    assert "26/f6a79c" in service.tracker.tasks
    assert status["stats"]["total"] == 8
    assert status["stats"]["cached"] == 5
    assert status["stats"]["completed"] == 8


@pytest.mark.anyio
async def test_running_tasks_with_sentinel_exit_not_failed(tmp_path: Path) -> None:
    app = create_app(settings=make_test_settings(tmp_path), runner=FakeRunner())
    service = app.state.container.pipeline_service

    await service.handle_webhook(
        {
            "event": "process_started",
            "runName": "test_sentinel_run",
            "trace": {
                "task_id": 4,
                "name": "CUTANDRUN:HOMER_FINDPEAKS (sample_1)",
                "process": "CUTANDRUN:HOMER_FINDPEAKS",
                "tag": "sample_1",
                "hash": "b4/d49d17",
                "status": "RUNNING",
                "exit": 2147483647,
            },
        }
    )
    status = service.get_status()
    assert status["stats"]["total"] == 1
    assert status["stats"]["running"] == 1
    assert status["stats"]["failed"] == 0
    assert service.tracker.tasks["b4/d49d17"]["exit"] is None

    await service.handle_webhook(
        {
            "event": "process_completed",
            "runName": "test_sentinel_run",
            "trace": {
                "task_id": 4,
                "name": "CUTANDRUN:HOMER_FINDPEAKS (sample_1)",
                "process": "CUTANDRUN:HOMER_FINDPEAKS",
                "tag": "sample_1",
                "hash": "b4/d49d17",
                "status": "COMPLETED",
                "exit": 0,
            },
        }
    )
    status = service.get_status()
    assert status["stats"]["running"] == 0
    assert status["stats"]["completed"] == 1
    assert status["stats"]["failed"] == 0
    assert service.tracker.tasks["b4/d49d17"]["exit"] == 0


@pytest.mark.anyio
async def test_start_pipeline_command_args_and_stop_preserves_cancelled(tmp_path: Path) -> None:
    settings = make_test_settings(tmp_path, port=8123)
    runner = FakeRunner(return_code=130)
    app = create_app(settings=settings, runner=runner)
    container: AppContainer = app.state.container

    # 1. Start with resume=True
    res = await container.pipeline_service.start(resume=True)
    assert res["status"] == "started"
    assert res["start_time"] is not None
    assert runner.commands[-1][:3] == ["bash", str(settings.run_sh_path), "true"]
    assert "127.0.0.1:8123/api/pipeline/webhook" in settings.weblog_config_path.read_text(encoding="utf-8")

    # 2. Stop preserves "cancelled" even after process exits with non-zero rc
    stop_res = await container.pipeline_service.stop()
    assert stop_res["status"] == "stopping"
    assert runner.interrupted == [99999]
    assert container.pipeline_service.stream_task is not None
    await container.pipeline_service.stream_task
    assert container.tracker.status == "cancelled"

    # 3. Start with resume=False
    runner.release_event.set()
    res2 = await container.pipeline_service.start(resume=False)
    assert res2["status"] == "started"
    assert runner.commands[-1][:3] == ["bash", str(settings.run_sh_path), "false"]
    assert container.pipeline_service.stream_task is not None
    await container.pipeline_service.stream_task
    assert container.tracker.status == "failed"


@pytest.mark.anyio
async def test_pipeline_timing_lifecycle(tmp_path: Path) -> None:
    app = create_app(settings=make_test_settings(tmp_path), runner=FakeRunner())
    service = app.state.container.pipeline_service

    await service.handle_webhook({"event": "started", "runName": "timing_test_run"})
    assert service.tracker.start_time is not None
    assert service.tracker.end_time is None

    status = service.get_status()
    assert status["start_time"] == service.tracker.start_time
    assert status["end_time"] is None

    await service.handle_webhook(
        {
            "event": "completed",
            "runName": "timing_test_run",
            "metadata": {"workflow": {"success": True, "stats": {}}},
        }
    )
    assert service.tracker.end_time is not None
    assert service.tracker.end_time >= service.tracker.start_time

    status_done = service.get_status()
    assert status_done["end_time"] == service.tracker.end_time


def test_http_endpoints_config_samplesheet_preflight_and_results_sandbox(tmp_path: Path) -> None:
    settings = make_test_settings(tmp_path)
    settings.config_path.write_text(SAMPLE_CONFIG, encoding="utf-8")

    # Create input_dir with 1 BAM for discover & preflight
    input_dir = tmp_path / "dropbox_input"
    bam_dir = input_dir / "06_index_bam"
    bam_dir.mkdir(parents=True)
    (bam_dir / "sample_A.bam").write_text("bam", encoding="utf-8")

    # Create results dir AND sibling prefix-collision dir to test traversal protection
    exp_results = settings.results_base_dir / "exp_test_01" / "15_summary_plots"
    exp_results.mkdir(parents=True)
    (exp_results / "01_peak_counts.png").write_bytes(b"\x89PNG\r\n")

    sibling_secret_dir = settings.results_base_dir / "exp_test_01_secret"
    sibling_secret_dir.mkdir(parents=True)
    (sibling_secret_dir / "leak.txt").write_text("secret", encoding="utf-8")

    app = create_app(settings=settings, runner=FakeRunner())
    client = TestClient(app)

    # Index & static assets + security headers
    idx = client.get("/")
    assert idx.status_code == 200
    assert "no-store" in idx.headers.get("cache-control", "")
    assert idx.headers.get("x-content-type-options") == "nosniff"
    assert 'id="monitorElapsedTimer"' in idx.text
    assert 'id="monitorElapsedTime"' in idx.text
    assert 'id="cfg_resource_cpus"' in idx.text
    assert 'id="cfg_resource_memory_value"' in idx.text
    assert 'id="cfg_resource_memory_unit"' in idx.text
    assert 'id="cfg_resource_time_value"' in idx.text
    assert 'id="cfg_resource_time_unit"' in idx.text
    assert client.get("/static/css/styles.css").status_code == 200
    assert client.get("/static/js/main.js").status_code == 200

    # Config GET/PUT + .bak backup + PATCH contrasts
    cfg_resp = client.get("/api/config")
    assert cfg_resp.status_code == 200
    cfg = cfg_resp.json()["config"]
    cfg["input_dir"] = str(input_dir)
    cfg["resource_cpus"] = 16
    cfg["resource_memory"] = "64.GB"
    cfg["resource_time"] = "24.h"
    put_resp = client.put("/api/config", json=cfg)
    assert put_resp.status_code == 200
    assert put_resp.json()["config"]["resource_cpus"] == 16
    assert put_resp.json()["config"]["resource_memory"] == "64.GB"
    assert put_resp.json()["config"]["resource_time"] == "24.h"
    assert settings.config_path.with_suffix(".config.bak").exists()
    saved_text = settings.config_path.read_text(encoding="utf-8")
    assert "cpus: 16" in saved_text
    assert "memory: 64.GB" in saved_text
    assert "time: 24.h" in saved_text

    patch_resp = client.patch(
        "/api/config/contrasts",
        json={"diff_contrasts": [{"id": "C_new", "treatment": "T", "background": "B", "target": "H3K4me3"}]},
    )
    assert patch_resp.status_code == 200
    assert len(patch_resp.json()["diff_contrasts"]) == 1

    # Samplesheet GET/PUT/discover
    disc_resp = client.post("/api/samplesheet/discover")
    assert disc_resp.status_code == 200
    assert disc_resp.json()["discovered"] == ["sample_A"]

    ss_put = client.put(
        "/api/samplesheet",
        json={"rows": [{"sample_id": "sample_A", "condition": "WT", "target": "H3K4me3", "replicate": "1"}]},
    )
    assert ss_put.status_code == 200
    assert client.get("/api/samplesheet").json()["rows"][0]["sample_id"] == "sample_A"

    # Preflight
    pf_resp = client.post("/api/preflight")
    assert pf_resp.status_code == 200
    assert any(c["name"] == "Input Directory" and c["status"] == "ok" for c in pf_resp.json()["checks"])

    # Results listing & strict path traversal sandboxing
    files_resp = client.get("/api/results/files")
    assert files_resp.status_code == 200
    assert files_resp.json()["exists"] is True
    assert files_resp.json()["files"][0]["name"] == "01_peak_counts.png"

    ok_file = client.get("/api/results/file/15_summary_plots/01_peak_counts.png")
    assert ok_file.status_code == 200

    traversal_attempt = client.get("/api/results/file/../exp_test_01_secret/leak.txt")
    assert traversal_attempt.status_code == 404


def test_trace_file_reconciliation_and_sse_stream(tmp_path: Path) -> None:
    settings = make_test_settings(tmp_path)
    settings.config_path.write_text(SAMPLE_CONFIG, encoding="utf-8")
    pipeline_info = settings.results_base_dir / "exp_test_01" / "pipeline_info"
    pipeline_info.mkdir(parents=True)
    trace_file = pipeline_info / "execution_trace_2026-11-11.txt"
    trace_file.write_text(
        "task_id\thash\tname\tstatus\texit\tduration\trealtime\t%cpu\tpeak_rss\n"
        "7\tcc/998877\tCUTANDRUN:MACS2 (s1)\tCOMPLETED\t0\t12s\t10s\t98.5%\t512 MB\n",
        encoding="utf-8",
    )

    app = create_app(settings=settings, runner=FakeRunner())
    service = app.state.container.pipeline_service
    service.tracker.start_time = trace_file.stat().st_mtime - 1
    service.broadcaster.append_log("hello log\n")
    service.reconcile_from_trace_file()

    assert "cc/998877" in service.tracker.tasks
    assert service.tracker.tasks["cc/998877"]["cpu_percent"] == 98.5
    assert service.tracker.tasks["cc/998877"]["duration"] == "12s"
    assert service.tracker.tasks["cc/998877"]["exit"] == 0


def test_health_lifespan_and_shutdown_endpoints(tmp_path: Path) -> None:
    import time

    settings = make_test_settings(tmp_path)
    runner = FakeRunner()
    shutdown_calls: list[str] = []
    app = create_app(
        settings=settings,
        runner=runner,
        shutdown_callback=lambda: shutdown_calls.append("shutdown"),
    )

    with TestClient(app) as client:
        health = client.get("/api/health")
        assert health.status_code == 200
        health_data = health.json()
        assert health_data["status"] == "ok"
        assert health_data["workspace_dir"] == str(settings.workspace_dir)
        assert health_data["pipeline_status"] == "idle"

        # Start pipeline and verify shutdown without force is rejected (409)
        start_resp = client.post("/api/pipeline/start", json={"resume": True})
        assert start_resp.status_code == 200

        blocked = client.post("/api/server/shutdown")
        assert blocked.status_code == 409
        assert shutdown_calls == []

    # Exiting TestClient triggers lifespan shutdown, interrupting active pipeline
    assert runner.interrupted == [99999]

    # Force shutdown stops active pipeline and triggers shutdown callback
    runner2 = FakeRunner()
    shutdown_calls2: list[str] = []
    app2 = create_app(
        settings=settings,
        runner=runner2,
        shutdown_callback=lambda: shutdown_calls2.append("shutdown"),
    )
    with TestClient(app2) as client2:
        assert client2.post("/api/pipeline/start", json={"resume": False}).status_code == 200
        forced = client2.post("/api/server/shutdown", json={"force": True})
        assert forced.status_code == 200
        assert forced.json() == {"status": "shutting_down"}
        time.sleep(0.25)

    assert runner2.interrupted == [99999]
    assert shutdown_calls2 == ["shutdown"]


def test_workspace_switcher_initialization_and_active_run_guard(tmp_path: Path) -> None:
    settings = make_test_settings(tmp_path)
    settings.config_path.write_text(SAMPLE_CONFIG, encoding="utf-8")
    runner = FakeRunner()
    app = create_app(settings=settings, runner=runner)

    new_exp = tmp_path / "Exp_New_02" / "Analysis_Run"

    with TestClient(app) as client:
        initial = client.get("/api/workspace")
        assert initial.status_code == 200
        init_data = initial.json()
        assert init_data["current"]["path"] == str(settings.workspace_dir)
        assert init_data["current"]["has_config"] is True

        # Selecting a non-existent folder without initialize=True returns 404
        missing = client.post("/api/workspace/select", json={"path": str(new_exp), "initialize": False})
        assert missing.status_code == 404

        # Initialize and switch into a brand-new Analysis_Run folder
        switched = client.post(
            "/api/workspace/select",
            json={"path": str(new_exp), "initialize": True, "experiment_name": "exp_new_02"},
        )
        assert switched.status_code == 200
        sw_data = switched.json()
        assert sw_data["current"]["path"] == str(new_exp.resolve())
        assert sw_data["current"]["has_config"] is True
        assert sw_data["current"]["has_samplesheet"] is True
        assert sw_data["current"]["has_run_sh"] is True
        assert len(sw_data["recent"]) == 2

        # /api/health and /api/config reflect the newly switched workspace
        assert client.get("/api/health").json()["workspace_dir"] == str(new_exp.resolve())
        cfg_resp = client.get("/api/config")
        assert cfg_resp.status_code == 200
        assert cfg_resp.json()["config"]["experiment"] == "exp_new_02"

        # Switching is blocked while a pipeline run is active
        assert client.post("/api/pipeline/start", json={"resume": True}).status_code == 200
        blocked = client.post("/api/workspace/select", json={"path": str(settings.workspace_dir)})
        assert blocked.status_code == 409

        # Directory browsing lists subdirectories and detects ready experiments
        browse = client.get("/api/workspace/list-dirs", params={"path": str(tmp_path)})
        assert browse.status_code == 200
        dirs = {d["name"]: d for d in browse.json()["directories"]}
        assert "Exp_New_02" in dirs
        assert dirs["Analysis_Run"]["has_config"] is True

    assert runner.interrupted == [99999]
