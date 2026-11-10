"""Domain models and config parser/serializer for Nextflow experiment.config."""

import re
from pathlib import Path
from typing import Any, Literal
from pydantic import BaseModel, EmailStr, Field


class ContrastModel(BaseModel):
    id: str
    treatment: str
    background: str
    target: str


class ExperimentConfigModel(BaseModel):
    # Experiment & Paths
    email: str = "daniel.higgins@umassmed.edu"
    experiment: str = "cut_run103026A"
    input_dir: str = ""
    bigwig_source: Literal["deepTools", "UCSC"] = "deepTools"
    outdir: str = "${launchDir}/results/${params.experiment}"
    samplesheet: str = "${launchDir}/config/samplesheet.csv"

    # Step Toggles
    run_macs2_callpeak: bool = True
    run_homer_findpeaks: bool = True
    run_merge_replicate_peaks: bool = True
    run_merge_master_peaks: bool = True
    run_homer_annotatepeaks: bool = True
    run_homer_diffpeaks: bool = True
    run_deeptools_metapeak: bool = True
    run_homer_findmotifs: bool = True
    run_meme_streme: bool = True
    run_summary_plots: bool = True

    # Peak Merging Settings
    active_peak_caller: Literal["macs2", "homer"] = "macs2"
    min_replicate_overlap: int = 2

    # Tool Parameters
    genome_name: str = "ce11"
    homer_dir: str = "${projectDir}/assets/homer_ce11"
    genome_fasta: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11"
    chrom_sizes: str = "${projectDir}/assets/homer_ce11/data/genomes/ce11/chrom.sizes"

    macs2_gsize: str = "ce"
    macs2_format: str = "BAMPE"
    macs2_qvalue: float = 0.01
    macs2_broad: bool = False
    macs2_broad_cutoff: float = 0.1

    homer_peak_style: Literal["factor", "histone"] = "factor"
    annotatepeaks_size: str = "given"

    diff_contrasts: list[ContrastModel] = Field(default_factory=list)

    metapeak_upstream: int = 2000
    metapeak_downstream: int = 2000
    metapeak_reference_point: str = "center"
    heatmap_colormap: str = "inferno"
    heatmap_interpolation: str = "nearest"

    homer_motif_size: str = "100"
    meme_slop_left: int = 50
    meme_slop_right: int = 49
    meme_streme_nmotifs: int = 20

    volcano_fdr_threshold: float = 0.05
    volcano_log2fc_threshold: float = 1.0
    volcano_top_n_labels: int = 12


def parse_experiment_config(content: str) -> ExperimentConfigModel:
    """Extract parameters from experiment.config params block."""
    data: dict[str, Any] = {}

    # Extract simple assignments: key = value
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("//") or line.startswith("/*") or line.startswith("*"):
            continue

        # Match scalar parameters: key = val
        m = re.match(r"^([a-zA-Z0-9_]+)\s*=\s*(.+?)(?:\s*//.*)?$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            # String literals
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                data[key] = val[1:-1]
            elif val.lower() == "true":
                data[key] = True
            elif val.lower() == "false":
                data[key] = False
            elif re.match(r"^-?\d+$", val):
                data[key] = int(val)
            elif re.match(r"^-?\d+\.\d+$", val):
                data[key] = float(val)

    # Extract diff_contrasts array of maps:
    # diff_contrasts = [ [ id: '...', treatment: '...', background: '...', target: '...' ], ... ]
    contrasts: list[ContrastModel] = []
    # Match items between diff_contrasts = [ and the closing ]
    start_idx = content.find("diff_contrasts")
    if start_idx != -1:
        bracket_start = content.find("[", start_idx)
        if bracket_start != -1:
            # find matching closing bracket for diff_contrasts
            depth = 0
            bracket_end = -1
            for i in range(bracket_start, len(content)):
                if content[i] == "[":
                    depth += 1
                elif content[i] == "]":
                    depth -= 1
                    if depth == 0:
                        bracket_end = i
                        break
            if bracket_end != -1:
                block = content[bracket_start:bracket_end + 1]
                items = re.findall(
                    r"\[\s*id:\s*['\"]([^'\"]+)['\"]\s*,\s*treatment:\s*['\"]([^'\"]+)['\"]\s*,\s*background:\s*['\"]([^'\"]+)['\"]\s*,\s*target:\s*['\"]([^'\"]+)['\"]\s*\]",
                    block,
                )
                for cid, treat, bg, tgt in items:
                    contrasts.append(ContrastModel(id=cid, treatment=treat, background=bg, target=tgt))

    data["diff_contrasts"] = contrasts
    return ExperimentConfigModel(**data)


def serialize_experiment_config(model: ExperimentConfigModel) -> str:
    """Format ExperimentConfigModel into valid Nextflow experiment.config file."""
    contrasts_lines = []
    for c in model.diff_contrasts:
        contrasts_lines.append(
            f"        [ id: '{c.id}', treatment: '{c.treatment}', background: '{c.background}', target: '{c.target}' ]"
        )
    contrasts_formatted = ",\n".join(contrasts_lines)

    return f"""/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Experiment Configuration for CUT&RUN Downstream Peak Analysis
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Run from Analysis_Run/:
      ./run.sh
    or:
      nextflow -c config/experiment.config run ../Cut_And_Run_Analysis -resume
----------------------------------------------------------------------------------------
*/

params {{
    // =========================================================================
    // Experiment & Input / Output Paths
    // =========================================================================
    email                          = "{model.email}"
    experiment                     = "{model.experiment}"
    input_dir                      = "{model.input_dir}"
    bigwig_source                  = "{model.bigwig_source}"             // 'deepTools' (bamCoverage RPKM) or 'UCSC' (bedGraphToBigWig)
    outdir                         = "{model.outdir}"
    samplesheet                    = "{model.samplesheet}"

    // =========================================================================
    // Step Toggles (Turn individual downstream peak analysis outputs on/off)
    // =========================================================================
    // Step c: Calling peaks (MACS2 and/or HOMER)
    run_macs2_callpeak             = {str(model.run_macs2_callpeak).lower()}
    run_homer_findpeaks            = {str(model.run_homer_findpeaks).lower()}

    // Step d: Merging peak files using bedtools
    run_merge_replicate_peaks      = {str(model.run_merge_replicate_peaks).lower()}
    run_merge_master_peaks         = {str(model.run_merge_master_peaks).lower()}

    // Step e: Peak-by-peak analysis using HOMER
    run_homer_annotatepeaks        = {str(model.run_homer_annotatepeaks).lower()}

    // Step f: Calling differential peaks using HOMER
    run_homer_diffpeaks            = {str(model.run_homer_diffpeaks).lower()}

    // Step g: Making metapeak plots (tornado plots) with deepTools
    run_deeptools_metapeak         = {str(model.run_deeptools_metapeak).lower()}

    // Step h: Looking for enriched motifs in peaks
    run_homer_findmotifs           = {str(model.run_homer_findmotifs).lower()}
    run_meme_streme                = {str(model.run_meme_streme).lower()}

    // Step i: Automated QC & summary plots (15_summary_plots)
    run_summary_plots              = {str(model.run_summary_plots).lower()}

    // Step d: bedtools replicate & condition peak merging
    active_peak_caller             = "{model.active_peak_caller}"                 // 'macs2' or 'homer'
    min_replicate_overlap          = {model.min_replicate_overlap}

    // =========================================================================
    // Input Globs (Dropbox inputs & local peak fallbacks when toggles are false)
    // =========================================================================
    input_bam                      = "${{params.input_dir}}/06_index_bam/*.bam"
    input_tagdirs                  = "${{params.input_dir}}/07_homer/tag_dir/*"
    input_bigwig                   = "${{params.input_dir}}/08_bigwig/${{params.bigwig_source}}/*.bw"
    input_sample_peaks             = "${{params.outdir}}/09_peaks/${{params.active_peak_caller}}/*_peaks.{{narrowPeak,broadPeak,bed}}"
    input_replicated_peaks         = "${{params.outdir}}/10_merged_peaks/replicates/*_replicated_peaks.bed"
    input_peaks_bed                = "${{params.outdir}}/10_merged_peaks/master/*_master_peaks.bed"
    input_annotated_peaks          = "${{params.outdir}}/11_peak_quantification/*_annotated_peaks.txt"
    input_diff_peaks               = "${{params.outdir}}/12_differential_peaks/*_differential_peaks.txt"

    // =========================================================================
    // Tool-Specific Parameters
    // =========================================================================
    // Genome Reference Settings (C. elegans defaults; change to mm10/hg38/dm6 if needed)
    genome_name                    = "{model.genome_name}"
    homer_dir                      = "{model.homer_dir}"
    genome_fasta                   = "{model.genome_fasta}"
    chrom_sizes                    = "{model.chrom_sizes}"

    // Step c: MACS2 parameters
    macs2_gsize                    = "{model.macs2_gsize}"                    // hs, mm, ce, dm, or numeric size
    macs2_format                   = "{model.macs2_format}"
    macs2_qvalue                   = {model.macs2_qvalue}
    macs2_broad                    = {str(model.macs2_broad).lower()}
    macs2_broad_cutoff             = {model.macs2_broad_cutoff}

    // Step c: HOMER findPeaks parameters
    homer_peak_style               = "{model.homer_peak_style}"                // 'factor' or 'histone'

    // Step e: HOMER annotatePeaks
    annotatepeaks_size             = "{model.annotatepeaks_size}"

    // Step f: HOMER getDifferentialPeaksReplicates contrasts
    diff_contrasts                 = [
{contrasts_formatted}
    ]

    // Step g: deepTools computeMatrix & plotHeatmap
    metapeak_upstream              = {model.metapeak_upstream}
    metapeak_downstream            = {model.metapeak_downstream}
    metapeak_reference_point       = "{model.metapeak_reference_point}"
    heatmap_colormap               = "{model.heatmap_colormap}"
    heatmap_interpolation          = "{model.heatmap_interpolation}"

    // Step h: Motif discovery (HOMER & MEME STREME)
    homer_motif_size               = "{model.homer_motif_size}"
    meme_slop_left                 = {model.meme_slop_left}
    meme_slop_right                = {model.meme_slop_right}
    meme_streme_nmotifs            = {model.meme_streme_nmotifs}

    // Step i: Automated QC & Summary Plots (15_summary_plots)
    volcano_fdr_threshold          = {model.volcano_fdr_threshold}
    volcano_log2fc_threshold       = {model.volcano_log2fc_threshold}
    volcano_top_n_labels           = {model.volcano_top_n_labels}
}}
"""
