"""Unit tests for CUT&RUN Control Center config parser and API."""

import pytest
from pathlib import Path
from config_parser import parse_experiment_config, serialize_experiment_config, ExperimentConfigModel, ContrastModel

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

def test_parse_experiment_config():
    model = parse_experiment_config(SAMPLE_CONFIG)
    assert model.email == "test.user@umassmed.edu"
    assert model.experiment == "exp_test_01"
    assert model.run_homer_findpeaks is False
    assert model.run_macs2_callpeak is True
    assert model.macs2_broad is True
    assert model.min_replicate_overlap == 3
    assert len(model.diff_contrasts) == 2
    assert model.diff_contrasts[0].id == "C1"
    assert model.diff_contrasts[1].target == "H3K27me3"


def test_roundtrip_serialization():
    model = parse_experiment_config(SAMPLE_CONFIG)
    serialized = serialize_experiment_config(model)
    reparsed = parse_experiment_config(serialized)
    assert reparsed.email == model.email
    assert reparsed.experiment == model.experiment
    assert reparsed.diff_contrasts == model.diff_contrasts
    assert reparsed.macs2_qvalue == model.macs2_qvalue


@pytest.mark.anyio
async def test_pipeline_webhook_and_status():
    from app import receive_pipeline_webhook, get_pipeline_status, state

    # Reset state
    state.tasks.clear()
    state.run_name = None

    # 1. Pipeline started event
    start_payload = {
        "event": "started",
        "runName": "clever_curie",
        "utcTime": "2026-11-10T12:00:00Z",
    }
    await receive_pipeline_webhook(start_payload)
    assert state.run_name == "clever_curie"

    # 2. Task submitted
    sub_payload = {
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
    await receive_pipeline_webhook(sub_payload)
    assert "ab/123456" in state.tasks
    assert state.tasks["ab/123456"]["process_short"] == "PLOT_PEAK_COUNTS"
    assert state.stats["total"] == 1
    assert state.stats["submitted"] == 1
    assert state.stats["completed"] == 0

    # 3. Task completed
    comp_payload = {
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
    await receive_pipeline_webhook(comp_payload)
    assert state.tasks["ab/123456"]["status"] == "COMPLETED"
    assert state.stats["completed"] == 1
    assert state.stats["percent"] == 100.0

    # 4. Status endpoint
    status_resp = await get_pipeline_status()
    assert status_resp["run_name"] == "clever_curie"
    assert len(status_resp["tasks"]) == 1
    assert status_resp["stats"]["completed"] == 1


@pytest.mark.anyio
async def test_cached_tasks_handling():
    from app import receive_pipeline_webhook, get_pipeline_status, state, PROCESS_STREAM_RE, update_stats

    state.tasks.clear()
    state.run_name = None

    # Test regex matching for cached lines
    log_line = "[d0/96014c] Cached process > CUTANDRUN:PLOT_PEAK_COUNTS (peak_counts_summary)"
    m = PROCESS_STREAM_RE.search(log_line)
    assert m is not None
    task_hash, action, proc_full, tag = m.groups()
    assert task_hash == "d0/96014c"
    assert action == "Cached"
    assert proc_full == "CUTANDRUN:PLOT_PEAK_COUNTS"
    assert tag == "peak_counts_summary"

    # Simulate completed event with cachedCount from Nextflow
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

    await receive_pipeline_webhook(completed_payload)
    assert state.stats["cached"] >= 2
    assert state.stats["total"] == 8
    assert state.stats["percent"] == 100.0

    status = await get_pipeline_status()
    assert status["stats"]["cached"] >= 2
    assert len(status["tasks"]) >= 2
    assert status["tasks"][0]["status"] == "CACHED"


@pytest.mark.anyio
async def test_mixed_cached_and_submitted_no_collision():
    from app import receive_pipeline_webhook, get_pipeline_status, state, PROCESS_STREAM_RE

    state.tasks.clear()
    state.run_name = None

    # 1. Five cached processes stream in
    cached_lines = [
        "[38/8e17bc] Cached process > CUTANDRUN:PLOT_ANNOTATED_SUMMARY (H3K4me3)",
        "[b2/2102b3] Cached process > CUTANDRUN:DEEPTOOLS_METAPEAK (H3K27me3)",
        "[d0/96014c] Cached process > CUTANDRUN:PLOT_PEAK_COUNTS (peak_counts_summary)",
        "[db/38aae7] Cached process > CUTANDRUN:DEEPTOOLS_METAPEAK (H3K4me3)",
        "[c0/1a91a2] Cached process > CUTANDRUN:PLOT_ANNOTATED_SUMMARY (H3K27me3)",
    ]
    for line in cached_lines:
        m = PROCESS_STREAM_RE.search(line)
        assert m is not None
        h, act, p, tag = m.groups()
        state.tasks[h] = {
            "task_id": h,
            "key": h,
            "name": f"{p} ({tag})",
            "process": p,
            "tag": tag,
            "hash": h,
            "status": "CACHED",
        }

    # 2. Three new tasks are submitted by Nextflow with task_id 1, 2, 3
    submitted_traces = [
        {"task_id": 1, "hash": "26/f6a79c", "name": "VOLCANO_1", "status": "COMPLETED"},
        {"task_id": 2, "hash": "4c/9471dd", "name": "VOLCANO_2", "status": "COMPLETED"},
        {"task_id": 3, "hash": "28/25c816", "name": "VOLCANO_3", "status": "COMPLETED"},
    ]
    for tr in submitted_traces:
        await receive_pipeline_webhook({"event": "process_completed", "trace": tr})

    # Verify all 8 tasks are present and b2/2102b3 was NOT overwritten
    status = await get_pipeline_status()
    assert len(status["tasks"]) == 8
    assert "b2/2102b3" in state.tasks
    assert state.tasks["b2/2102b3"]["status"] == "CACHED"
    assert "26/f6a79c" in state.tasks
    assert state.stats["total"] == 8
    assert state.stats["cached"] == 5
    assert state.stats["completed"] == 8


