#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CUT&RUN Downstream Peak Analysis Pipeline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CUTANDRUN } from './workflows/cutandrun'
include {
    loadSamplesheetMap
    extractSampleId
    resolveInputFiles
} from './lib/utils'
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


    def resolved_bam_glob       = "${params.input_dir}/08_deeptools/bam_index/*.bam"
    def resolved_tagdirs_glob   = "${params.input_dir}/07_homer/tag_dir/*"
    def resolved_bigwig_glob    = "${params.input_dir}/08_deeptools/bw/*.bw"
    def resolved_annotated_glob = "${params.outdir}/11_peak_quantification/*_annotated_peaks.txt"
    def resolved_diff_glob      = "${params.outdir}/12_differential_peaks/*_differential_peaks.txt"


    log.info """\
    ========================================================================
     C U T & R U N   P E A K   A N A L Y S I S   P I P E L I N E
    ========================================================================
     experiment                 : ${params.experiment}
     input_dir                  : ${params.input_dir}
     bigwig_source              : ${params.bigwig_source}
     input_bam                  : ${resolved_bam_glob}
     input_tagdirs              : ${resolved_tagdirs_glob}
     input_bigwig               : ${resolved_bigwig_glob}
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
    // Load sample metadata from samplesheet.csv if present
    //
    def samplesheet_map = loadSamplesheetMap(params.samplesheet)
    def condition_to_target = [:]
    samplesheet_map.each { _sample_id, meta ->
        condition_to_target[meta.condition] = meta.target
    }

    //
    // Resolve indexed BAMs from Dropbox 
    //
    def ch_bam_bai = resolveInputFiles(
            resolved_bam_glob,
            samplesheet_map,
            ['.bam'],
            [skipEmpty: true, label: 'BAM file']
        )
        .map { meta, bam_file ->
            def bai_file = file("${bam_file}.bai", checkIfExists: true)
            [ meta, bam_file, bai_file ]
        }

    //
    // Resolve HOMER Tag Directories from Dropbox 
    //
    def ch_tagdirs = resolveInputFiles(
        resolved_tagdirs_glob,
        samplesheet_map,
        ['_tagdir'],
        [type: 'dir']
    )

    //
    // Resolve BigWig files from Dropbox 
    //
    def ch_bigwig = resolveInputFiles(
        resolved_bigwig_glob,
        samplesheet_map,
        ['.bw', '.bigWig'],
        [skipEmpty: true, label: 'BigWig file']
    )

    //
    // Resolve pre-existing per-sample peak files
    //
    def ch_existing_sample_peaks = resolveInputFiles(
        params.input_sample_peaks,
        samplesheet_map,
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
        ]
    )

    //
    // Resolve pre-existing condition-merged replicate peaks
    //
    def ch_existing_replicated_peaks = channel
        .fromPath(params.input_replicated_peaks, checkIfExists: false)
        .map { rep_bed ->
            def condition_id = extractSampleId(rep_bed, ['_replicated_peaks.bed', '.bed'])
            def target_name = condition_to_target[condition_id] ?: 'default'
            [ [ id: condition_id, condition: condition_id, target: target_name ], rep_bed ]
        }

    //
    // Resolve pre-existing master peak files per target
    //
    def ch_existing_master_peaks = channel
        .fromPath(params.input_peaks_bed, checkIfExists: false)
        .map { master_bed ->
            def target_name = extractSampleId(master_bed, ['_master_peaks.bed', '.bed'])
            [ [ id: target_name, target: target_name ], master_bed ]
        }

    //
    // Resolve pre-existing annotated peak tables
    //
    def ch_existing_annotated_peaks = channel
        .fromPath(resolved_annotated_glob, checkIfExists: false)
        .map { annot_txt ->
            def target_name = extractSampleId(annot_txt, ['_annotated_peaks.txt', '.txt'])
            [ [ id: target_name, target: target_name ], annot_txt ]
        }

    //
    // Resolve pre-existing differential peak tables
    //
    def contrast_map = [:]
    if (params.diff_contrasts) {
        params.diff_contrasts.each { c ->
            contrast_map[c.id] = c
        }
    }
    def ch_existing_diff_peaks = channel
        .fromPath(resolved_diff_glob, checkIfExists: false)
        .map { diff_txt ->
            def contrast_id = extractSampleId(diff_txt, ['_differential_peaks.txt', '.txt'])
            def c_info = contrast_map[contrast_id] ?: [:]
            [
                [
                    id        : contrast_id,
                    treatment : c_info.treatment  ?: 'Treatment',
                    background: c_info.background ?: 'Background',
                    target    : c_info.target     ?: ''
                ],
                diff_txt
            ]
        }

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
        ch_existing_diff_peaks
    )

    onComplete:
    if (workflow.success) {
        log.info "\nPipeline execution completed successfully! Results available in: ${params.outdir}\n"
    } else {
        log.warn "\nPipeline execution completed with errors. Check the logs for details.\n"
    }
}