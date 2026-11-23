/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW: PEAK_CALLING
    Step c (MACS2 / HOMER peak calling with optional IgG control pairing)
    Step d (Replicate peak merging & master target peak set generation)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { MACS2_CALLPEAK            } from '../../../modules/local/macs2/callpeak/main'
include { HOMER_FINDPEAKS           } from '../../../modules/local/homer/findpeaks/main'
include { BEDTOOLS_MERGE_REPLICATES } from '../../../modules/local/bedtools/merge_replicates/main'
include { BEDTOOLS_MERGE_MASTER     } from '../../../modules/local/bedtools/merge_master/main'
include { isControlTarget           } from '../../../lib/utils'

workflow PEAK_CALLING {

    take:
    ch_bam_bai                   // channel: [ val(meta), path(bam), path(bai) ]
    ch_tagdirs                   // channel: [ val(meta), path(tagdir) ]
    ch_existing_sample_peaks     // channel: [ val(meta), path(peaks_bed) ]
    ch_existing_replicated_peaks // channel: [ val(meta), path(replicated_peaks_bed) ]
    ch_existing_master_peaks     // channel: [ val(meta), path(master_peaks_bed) ]

    main:
    //
    // Pair target samples with optional IgG controls (when params.use_igg_control = true)
    //
    def ch_bam_split = ch_bam_bai.branch { meta, bam, bai ->
        control: isControlTarget(meta)
        target:  true
    }

    def ch_control_bam_by_id = ch_bam_split.control
        .map { meta, bam, bai -> [ meta.id, bam, bai ] }

    def ch_macs2_input
    if (params.use_igg_control) {
        def ch_target_bam_branched = ch_bam_split.target.branch { meta, bam, bai ->
            with_ctrl: meta.control_id != null
                return [ meta.control_id, meta, bam, bai ]
            no_ctrl: true
                return [ meta, bam, bai, [], [] ]
        }

        def ch_paired_bam = ch_target_bam_branched.with_ctrl
            .combine(ch_control_bam_by_id, by: 0)
            .map { _ctrl_id, meta, bam, bai, ctrl_bam, ctrl_bai ->
                [ meta, bam, bai, ctrl_bam, ctrl_bai ]
            }

        ch_macs2_input = ch_paired_bam.mix(ch_target_bam_branched.no_ctrl)
    } else {
        ch_macs2_input = ch_bam_split.target
            .map { meta, bam, bai -> [ meta, bam, bai, [], [] ] }
    }

    def ch_tagdir_split = ch_tagdirs.branch { meta, tagdir ->
        control: isControlTarget(meta)
        target:  true
    }

    def ch_control_tagdir_by_id = ch_tagdir_split.control
        .map { meta, tagdir -> [ meta.id, tagdir ] }

    def ch_homer_input
    if (params.use_igg_control) {
        def ch_target_tagdir_branched = ch_tagdir_split.target.branch { meta, tagdir ->
            with_ctrl: meta.control_id != null
                return [ meta.control_id, meta, tagdir ]
            no_ctrl: true
                return [ meta, tagdir, [] ]
        }

        def ch_paired_tagdir = ch_target_tagdir_branched.with_ctrl
            .combine(ch_control_tagdir_by_id, by: 0)
            .map { _ctrl_id, meta, tagdir, ctrl_tagdir ->
                [ meta, tagdir, ctrl_tagdir ]
            }

        ch_homer_input = ch_paired_tagdir.mix(ch_target_tagdir_branched.no_ctrl)
    } else {
        ch_homer_input = ch_tagdir_split.target
            .map { meta, tagdir -> [ meta, tagdir, [] ] }
    }

    //
    // Step c (1): Calling peaks with MACS2
    //
    def ch_macs2_peaks = channel.empty()
    if (params.run_macs2_callpeak) {
        MACS2_CALLPEAK(ch_macs2_input)
        ch_macs2_peaks = MACS2_CALLPEAK.out.merge_ready_bed
    }

    //
    // Step c (2): Calling peaks with HOMER
    //
    def ch_homer_peaks = channel.empty()
    if (params.run_homer_findpeaks) {
        HOMER_FINDPEAKS(ch_homer_input)
        ch_homer_peaks = HOMER_FINDPEAKS.out.merge_ready_bed
    }

    //
    // Select active per-sample peaks for Step d (MACS2, HOMER, or pre-existing)
    //
    if (!(params.active_peak_caller in ['macs2', 'homer'])) {
        error("Invalid params.active_peak_caller='${params.active_peak_caller}'. Must be 'macs2' or 'homer'.")
    }

    def ch_active_sample_peaks = ch_existing_sample_peaks
    if (params.active_peak_caller == 'homer') {
        if (params.run_homer_findpeaks) {
            ch_active_sample_peaks = ch_homer_peaks
        } else if (params.run_macs2_callpeak) {
            error("params.active_peak_caller is 'homer', but params.run_homer_findpeaks is false while params.run_macs2_callpeak is true. Enable run_homer_findpeaks, set active_peak_caller = 'macs2', or disable both callers to use pre-existing peaks.")
        }
    } else if (params.active_peak_caller == 'macs2') {
        if (params.run_macs2_callpeak) {
            ch_active_sample_peaks = ch_macs2_peaks
        } else if (params.run_homer_findpeaks) {
            error("params.active_peak_caller is 'macs2', but params.run_macs2_callpeak is false while params.run_homer_findpeaks is true. Enable run_macs2_callpeak, set active_peak_caller = 'homer', or disable both callers to use pre-existing peaks.")
        }
    }

    //
    // Step d (1): Merging replicate peak files per condition using bedtools
    //
    def ch_replicated_peaks = ch_existing_replicated_peaks
    if (params.run_merge_replicate_peaks) {
        def ch_grouped_condition_peaks = ch_active_sample_peaks
            .filter { meta, _bed -> !isControlTarget(meta) }
            .map { meta, bed ->
                [ [ id: meta.condition, condition: meta.condition, target: meta.target, peak_mode: meta.peak_mode ], bed ]
            }
            .groupTuple(by: 0)

        BEDTOOLS_MERGE_REPLICATES(
            ch_grouped_condition_peaks,
            params.min_replicate_overlap
        )
        ch_replicated_peaks = BEDTOOLS_MERGE_REPLICATES.out.bed
    }

    //
    // Step d (2): Inclusive master peak set per target/histone mark across conditions
    //
    def ch_master_peaks = ch_existing_master_peaks
    if (params.run_merge_master_peaks) {
        def ch_source_for_master = params.run_merge_replicate_peaks
            ? ch_replicated_peaks
            : ch_replicated_peaks.mix(ch_active_sample_peaks)

        def ch_grouped_target_beds = ch_source_for_master
            .filter { meta, _bed -> !isControlTarget(meta) }
            .map { meta, bed ->
                [ [ id: meta.target, target: meta.target, peak_mode: meta.peak_mode ], bed ]
            }
            .groupTuple(by: 0)

        BEDTOOLS_MERGE_MASTER(ch_grouped_target_beds)
        ch_master_peaks = BEDTOOLS_MERGE_MASTER.out.bed
    }

    emit:
    macs2_peaks         = ch_macs2_peaks
    homer_peaks         = ch_homer_peaks
    active_sample_peaks = ch_active_sample_peaks
    replicated_peaks    = ch_replicated_peaks
    master_peaks        = ch_master_peaks
}
