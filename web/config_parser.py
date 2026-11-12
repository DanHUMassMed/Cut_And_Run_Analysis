"""Parser and serializer for Nextflow experiment.config."""

from __future__ import annotations

import re
from typing import Any

from models import ContrastModel, ExperimentConfigModel

__all__ = [
    "ContrastModel",
    "ExperimentConfigModel",
    "parse_experiment_config",
    "serialize_experiment_config",
]

_ALLOWED_NF_INTERPOLATIONS = frozenset(
    {
        "${launchDir}",
        "${projectDir}",
        "${params.experiment}",
        "${params.input_dir}",
        "${params.bigwig_source}",
        "${params.active_peak_caller}",
        "${params.outdir}",
    }
)
_INTERPOLATION_RE = re.compile(r"\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*")
_ASSIGNMENT_RE = re.compile(r"^([a-zA-Z0-9_]+)\s*=\s*(.+)$")
_INT_RE = re.compile(r"^-?\d+$")
_FLOAT_RE = re.compile(r"^-?(?:\d+\.\d+|\d+(?:\.\d+)?[eE][+-]?\d+)$")
_CONTRAST_KV_RE = re.compile(r"(id|treatment|background|target)\s*:\s*(['\"])((?:\\.|(?!\2).)*)\2")
_RESOURCE_CPUS_RE = re.compile(r"\bcpus\s*:\s*(\d+)")
_RESOURCE_MEMORY_RE = re.compile(
    r"\bmemory\s*:\s*(?:(['\"])([^'\"]+)\1|(\d+(?:\.\d+)?\s*\.?\s*(?:B|KB|MB|GB|TB)))",
    re.IGNORECASE,
)
_RESOURCE_TIME_RE = re.compile(
    r"\btime\s*:\s*(?:(['\"])([^'\"]+)\1|(\d+(?:\.\d+)?\s*\.?\s*(?:ms|s|m|h|d)))",
    re.IGNORECASE,
)


def _strip_inline_comment(line: str) -> str:
    """Remove trailing // comments outside quoted Groovy string literals."""
    in_quote: str | None = None
    escaped = False
    i = 0
    while i < len(line):
        ch = line[i]
        if escaped:
            escaped = False
            i += 1
            continue
        if ch == "\\" and in_quote is not None:
            escaped = True
            i += 1
            continue
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
        elif ch == "/" and in_quote is None and i + 1 < len(line) and line[i + 1] == "/":
            return line[:i].strip()
        i += 1
    return line.strip()


def _unescape_groovy_string(raw: str, quote_char: str) -> str:
    """Unescape common Groovy escape sequences within a parsed string literal."""
    out = raw.replace("\\\\", "\\").replace(f"\\{quote_char}", quote_char)
    if quote_char == '"':
        out = out.replace("\\$", "$")
    return out


def _escape_groovy_double_quoted(value: str) -> str:
    """Escape a string for Groovy double-quoted literals while preserving whitelisted Nextflow vars."""
    cleaned = value.replace("\r", " ").replace("\n", " ").replace("\x00", "")
    escaped = cleaned.replace("\\", "\\\\").replace('"', '\\"')

    def _replace_dollar(match: re.Match[str]) -> str:
        token = match.group(0)
        if token in _ALLOWED_NF_INTERPOLATIONS:
            return token
        return "\\" + token

    return _INTERPOLATION_RE.sub(_replace_dollar, escaped).replace("$(", "\\$(")


def _escape_groovy_single_quoted(value: str) -> str:
    """Escape a string for Groovy single-quoted literals."""
    cleaned = value.replace("\r", " ").replace("\n", " ").replace("\x00", "")
    return cleaned.replace("\\", "\\\\").replace("'", "\\'")


def _extract_bracket_block(content: str, key: str) -> str | None:
    """Return the bracketed [...] block assigned to `key`, or None if absent."""
    match = re.search(rf"\b{re.escape(key)}\s*=\s*\[", content)
    if not match:
        return None
    bracket_start = content.find("[", match.start())
    if bracket_start == -1:
        return None

    depth = 0
    in_quote: str | None = None
    escaped = False
    for idx in range(bracket_start, len(content)):
        ch = content[idx]
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_quote is not None:
            escaped = True
            continue
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            continue
        if in_quote is not None:
            continue
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return content[bracket_start : idx + 1]
    return None


def _parse_contrasts_block(block: str) -> list[ContrastModel]:
    """Parse Groovy list-of-maps `[ id: '...', treatment: '...', ... ]` regardless of field order."""
    contrasts: list[ContrastModel] = []
    # Find inner [...] entries at depth 2 inside the outer [...] list
    depth = 0
    in_quote: str | None = None
    escaped = False
    item_start = -1
    for idx, ch in enumerate(block):
        if escaped:
            escaped = False
            continue
        if ch == "\\" and in_quote is not None:
            escaped = True
            continue
        if ch in ('"', "'"):
            if in_quote is None:
                in_quote = ch
            elif in_quote == ch:
                in_quote = None
            continue
        if in_quote is not None:
            continue
        if ch == "[":
            depth += 1
            if depth == 2:
                item_start = idx + 1
        elif ch == "]":
            if depth == 2 and item_start != -1:
                entry_text = block[item_start:idx]
                fields: dict[str, str] = {}
                for k_match in _CONTRAST_KV_RE.finditer(entry_text):
                    k_name, q_char, raw_val = k_match.groups()
                    fields[k_name] = _unescape_groovy_string(raw_val, q_char)
                if {"id", "treatment", "background", "target"}.issubset(fields):
                    contrasts.append(
                        ContrastModel(
                            id=fields["id"],
                            treatment=fields["treatment"],
                            background=fields["background"],
                            target=fields["target"],
                        )
                    )
                item_start = -1
            depth -= 1
    return contrasts


def _parse_resource_limits_block(block: str) -> dict[str, Any]:
    """Parse Groovy `resourceLimits = [ cpus: ..., memory: ..., time: ... ]` map."""
    cleaned_lines = [
        _strip_inline_comment(line.strip())
        for line in block.splitlines()
        if line.strip() and not line.strip().startswith(("//", "/*", "*"))
    ]
    cleaned_block = "\n".join(cleaned_lines)

    parsed: dict[str, Any] = {}
    cpus_match = _RESOURCE_CPUS_RE.search(cleaned_block)
    if cpus_match:
        parsed["resource_cpus"] = int(cpus_match.group(1))

    mem_match = _RESOURCE_MEMORY_RE.search(cleaned_block)
    if mem_match:
        parsed["resource_memory"] = (mem_match.group(2) or mem_match.group(3)).strip()

    time_match = _RESOURCE_TIME_RE.search(cleaned_block)
    if time_match:
        parsed["resource_time"] = (time_match.group(2) or time_match.group(3)).strip()

    return parsed


def parse_experiment_config(content: str) -> ExperimentConfigModel:
    """Extract parameters from an experiment.config params block."""
    data: dict[str, Any] = {}

    for raw_line in content.splitlines():
        line = _strip_inline_comment(raw_line.strip())
        if not line or line.startswith("//") or line.startswith("/*") or line.startswith("*"):
            continue

        m = _ASSIGNMENT_RE.match(line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            data[key] = _unescape_groovy_string(val[1:-1], val[0])
        elif val.lower() == "true":
            data[key] = True
        elif val.lower() == "false":
            data[key] = False
        elif _INT_RE.match(val):
            data[key] = int(val)
        elif _FLOAT_RE.match(val):
            data[key] = float(val)

    block = _extract_bracket_block(content, "diff_contrasts")
    data["diff_contrasts"] = _parse_contrasts_block(block) if block else []

    limits_block = _extract_bracket_block(content, "resourceLimits")
    if limits_block:
        data.update(_parse_resource_limits_block(limits_block))

    return ExperimentConfigModel(**data)


def serialize_experiment_config(model: ExperimentConfigModel) -> str:
    """Format an ExperimentConfigModel into a safe Nextflow experiment.config file."""
    contrasts_lines = [
        (
            f"        [ id: '{_escape_groovy_single_quoted(c.id)}', "
            f"treatment: '{_escape_groovy_single_quoted(c.treatment)}', "
            f"background: '{_escape_groovy_single_quoted(c.background)}', "
            f"target: '{_escape_groovy_single_quoted(c.target)}' ]"
        )
        for c in model.diff_contrasts
    ]
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
    email                          = "{_escape_groovy_double_quoted(model.email)}"
    experiment                     = "{_escape_groovy_double_quoted(model.experiment)}"
    input_dir                      = "{_escape_groovy_double_quoted(model.input_dir)}"
    bigwig_source                  = "{_escape_groovy_double_quoted(model.bigwig_source)}"             // 'deepTools' (bamCoverage RPKM) or 'UCSC' (bedGraphToBigWig)
    outdir                         = "{_escape_groovy_double_quoted(model.outdir)}"
    samplesheet                    = "{_escape_groovy_double_quoted(model.samplesheet)}"

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
    active_peak_caller             = "{_escape_groovy_double_quoted(model.active_peak_caller)}"                 // 'macs2' or 'homer'
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
    genome_name                    = "{_escape_groovy_double_quoted(model.genome_name)}"
    homer_dir                      = "{_escape_groovy_double_quoted(model.homer_dir)}"
    genome_fasta                   = "{_escape_groovy_double_quoted(model.genome_fasta)}"
    chrom_sizes                    = "{_escape_groovy_double_quoted(model.chrom_sizes)}"

    // Step c: MACS2 parameters
    macs2_gsize                    = "{_escape_groovy_double_quoted(model.macs2_gsize)}"                    // hs, mm, ce, dm, or numeric size
    macs2_format                   = "{_escape_groovy_double_quoted(model.macs2_format)}"
    macs2_qvalue                   = {model.macs2_qvalue}
    macs2_broad                    = {str(model.macs2_broad).lower()}
    macs2_broad_cutoff             = {model.macs2_broad_cutoff}

    // Step c: HOMER findPeaks parameters
    homer_peak_style               = "{_escape_groovy_double_quoted(model.homer_peak_style)}"                // 'factor' or 'histone'

    // Step e: HOMER annotatePeaks
    annotatepeaks_size             = "{_escape_groovy_double_quoted(model.annotatepeaks_size)}"

    // Step f: HOMER getDifferentialPeaksReplicates contrasts
    diff_contrasts                 = [
{contrasts_formatted}
    ]

    // Step g: deepTools computeMatrix & plotHeatmap
    metapeak_upstream              = {model.metapeak_upstream}
    metapeak_downstream            = {model.metapeak_downstream}
    metapeak_reference_point       = "{_escape_groovy_double_quoted(model.metapeak_reference_point)}"
    heatmap_colormap               = "{_escape_groovy_double_quoted(model.heatmap_colormap)}"
    heatmap_interpolation          = "{_escape_groovy_double_quoted(model.heatmap_interpolation)}"

    // Step h: Motif discovery (HOMER & MEME STREME)
    homer_motif_size               = "{_escape_groovy_double_quoted(model.homer_motif_size)}"
    meme_slop_left                 = {model.meme_slop_left}
    meme_slop_right                = {model.meme_slop_right}
    meme_streme_nmotifs            = {model.meme_streme_nmotifs}

    // Step i: Automated QC & Summary Plots (15_summary_plots)
    volcano_fdr_threshold          = {model.volcano_fdr_threshold}
    volcano_log2fc_threshold       = {model.volcano_log2fc_threshold}
    volcano_top_n_labels           = {model.volcano_top_n_labels}
}}

process {{
    resourceLimits = [
        cpus: {model.resource_cpus},
        memory: {model.resource_memory},
        time: {model.resource_time}
    ]
}}
"""
