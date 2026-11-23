#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CUT&RUN Downstream Peak Analysis Pipeline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CUTANDRUN } from './workflows/cutandrun'
include {
    loadAndValidateSamplesheet
    validateDiffContrasts
} from './lib/samplesheet'
include {
    resolveInputFiles
    resolveConditionFiles
    resolveTargetFiles
    resolveContrastFiles
} from './lib/resolvefiles'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MAIN WORKFLOW Entrypoint
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {

    main:
    if (!params.experiment || !params.input_dir) {
        error("params.experiment and params.input_dir do not have defaults and must be set in config/experiment.config.")
    }

    log.info """\
    ========================================================================
     C U T & R U N   P E A K   A N A L Y S I S   P I P E L I N E
    ========================================================================
     experiment                 : ${params.experiment}
     input_dir                  : ${params.input_dir}
     input_bam                  : ${params.input_bam}
     input_tagdirs              : ${params.input_tagdirs}
     input_bigwig               : ${params.input_bigwig}
     outdir                     : ${params.outdir}
     samplesheet                : ${params.samplesheet}
     ----------------------------------------------------------------------
     Active Step Toggles:
       macs2_callpeak           : ${params.run_macs2_callpeak}
       homer_findpeaks          : ${params.run_homer_findpeaks}
       merge_replicate_peaks    : ${params.run_merge_replicate_peaks}
       merge_master_peaks       : ${params.run_merge_master_peaks}
       homer_annotatepeaks      : ${params.run_homer_annotatepeaks}
       homer_diffpeaks          : ${params.run_homer_diffpeaks}
       deeptools_metapeak       : ${params.run_deeptools_metapeak}
       homer_findmotifs         : ${params.run_homer_findmotifs}
       meme_streme              : ${params.run_meme_streme}
       summary_plots            : ${params.run_summary_plots}
    ========================================================================
    """.stripIndent()

    //
    // Validate samplesheet.csv and differential contrasts upfront
    //
    def experiment_config = "${launchDir}/config/experiment.config"
    def sheet_ctx         = loadAndValidateSamplesheet(params.samplesheet)
    def contrast_map      = validateDiffContrasts(params.diff_contrasts, sheet_ctx, experiment_config)

    // Warn when IgG control subtraction is enabled on a sheet with mixed controlled/uncontrolled samples
    if (params.use_igg_control && sheet_ctx.referenced_control_ids && sheet_ctx.samples_without_control) {
        log.warn "params.use_igg_control is true, but ${sheet_ctx.samples_without_control.size()} experimental sample(s) have no control_id and will run control-free: ${sheet_ctx.samples_without_control.sort().join(', ')}"
    }

    // Resolve all samples listed in samplesheet.csv (including IgG controls if present)
    // so QC and reporting are independent of peak-calling config toggles like use_igg_control.
    def expected_all_ids = sheet_ctx.all_sample_ids

    //
    // Resolve indexed BAMs from Dropbox
    //
    def ch_bam_bai = resolveInputFiles(
        params.input_bam,
        sheet_ctx,
        ['.bam'],
        [
            skipEmpty           : true,
            label               : 'BAM file',
            requireBai          : true,
            errorOnUnrecognized : true,
            expectedIds         : expected_all_ids
        ]
    )

    //
    // Resolve HOMER Tag Directories from Dropbox
    //
    def ch_tagdirs = resolveInputFiles(
        params.input_tagdirs,
        sheet_ctx,
        ['_tagdir'],
        [
            type                : 'dir',
            label               : 'HOMER tag directory',
            errorOnUnrecognized : true,
            expectedIds         : expected_all_ids
        ]
    )

    //
    // Resolve BigWig files from Dropbox
    //
    def ch_bigwig = resolveInputFiles(
        params.input_bigwig,
        sheet_ctx,
        ['.bw', '.bigWig'],
        [
            skipEmpty           : true,
            label               : 'BigWig file',
            errorOnUnrecognized : true,
            expectedIds         : expected_all_ids
        ]
    )

    //
    // Resolve optional upstream QC logs (graceful fallback if absent on older upstream runs)
    //
    def upstream_trimmomatic_logs = files(params.input_trimmomatic_logs, checkIfExists: false)
    def upstream_bowtie2_logs     = files(params.input_bowtie2_logs, checkIfExists: false)
    def upstream_picard_dups      = files(params.input_picard_dup, checkIfExists: false)
    def upstream_bam_stats        = files(params.input_bam_stats, checkIfExists: false)

    //
    // Resolve pre-existing per-sample peak files
    //
    def ch_existing_sample_peaks = resolveInputFiles(
        params.input_sample_peaks,
        sheet_ctx,
        [
            '_macs2_merge_ready_peaks.bed',
            '_homer_merge_ready_peaks.bed',
            '_merge_ready_peaks.bed',
            '_peaks.narrowPeak',
            '_peaks.broadPeak',
            '_peaks.bed',
            '.narrowPeak',
            '.broadPeak',
            '.bed'
        ],
        [label: 'pre-existing sample peak file']
    )

    //
    // Resolve pre-existing condition-merged replicate peaks
    //
    def ch_existing_replicated_peaks = resolveConditionFiles(
        params.input_replicated_peaks,
        sheet_ctx,
        ['_replicated_peaks.bed', '.bed'],
        [label: 'pre-existing replicated peak file']
    )

    //
    // Resolve pre-existing master peak files per target
    //
    def ch_existing_master_peaks = resolveTargetFiles(
        params.input_peaks_bed,
        sheet_ctx,
        ['_master_peaks.bed', '.bed'],
        [label: 'pre-existing master peak file']
    )

    //
    // Resolve pre-existing annotated peak tables
    //
    def ch_existing_annotated_peaks = resolveTargetFiles(
        params.input_annotated_peaks,
        sheet_ctx,
        ['_annotated_peaks.txt', '.txt'],
        [label: 'pre-existing annotated peak table']
    )

    //
    // Resolve pre-existing differential peak tables
    //
    def ch_existing_diff_peaks = resolveContrastFiles(
        params.input_diff_peaks,
        contrast_map,
        sheet_ctx,
        ['_differential_peaks.txt', '.txt'],
        [label: 'pre-existing differential peak table']
    )

    //
    // WORKFLOW: Run CUTANDRUN
    //
    CUTANDRUN(
        ch_bam_bai,
        ch_tagdirs,
        ch_bigwig,
        ch_existing_sample_peaks,
        ch_existing_replicated_peaks,
        ch_existing_master_peaks,
        ch_existing_annotated_peaks,
        ch_existing_diff_peaks,
        upstream_trimmomatic_logs,
        upstream_bowtie2_logs,
        upstream_picard_dups,
        upstream_bam_stats
    )

    onComplete:
    if (workflow.success) {
        log.info "\nPipeline execution completed successfully! Results available in: ${params.outdir}\n"
    } else {
        log.warn "\nPipeline execution completed with errors. Check the logs for details.\n"
    }
}
