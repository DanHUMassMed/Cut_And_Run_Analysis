/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW: PEAK_ANNOTATION_AND_DIFF
    Step e (HOMER annotatePeaks with automatic IgG control inclusion when present)
    Step f (HOMER getDifferentialPeaksReplicates)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { HOMER_ANNOTATEPEAKS        } from '../../../modules/local/homer/annotatepeaks/main'
include { HOMER_GETDIFFERENTIALPEAKS } from '../../../modules/local/homer/getdifferentialpeaks/main'
include { isControlTarget            } from '../../../lib/utils'

workflow PEAK_ANNOTATION_AND_DIFF {

    take:
    ch_master_peaks             // channel: [ val(meta), path(master_bed) ]
    ch_tagdirs                  // channel: [ val(meta), path(tagdir) ]
    ch_existing_annotated_peaks // channel: [ val(meta), path(annotated_peaks_txt) ]
    ch_existing_diff_peaks      // channel: [ val(meta), path(diff_peaks_txt) ]

    main:
    def ch_master_by_target = ch_master_peaks.map { meta, bed ->
        [ meta.target, meta, bed ]
    }

    def ch_tagdir_split = ch_tagdirs.branch { meta, tagdir ->
        control: isControlTarget(meta)
        target:  true
    }

    def ch_control_tagdirs_singleton = ch_tagdir_split.control
        .map { meta, tagdir -> [ id: meta.id, sample_name: meta.sample_name, tagdir: tagdir ] }
        .toList()
        .map { ctrls -> [ controls: ctrls.sort { a, b -> a.tagdir.name <=> b.tagdir.name } ] }

    //
    // Step e: Peak-by-peak analysis using HOMER (annotatePeaks.pl)
    // Automatically includes matched IgG control tag directories whenever IgG controls exist.
    //
    def ch_annotated_peaks = ch_existing_annotated_peaks
    if (params.run_homer_annotatepeaks) {
        def ch_tagdirs_by_target = ch_tagdir_split.target
            .map { meta, tagdir ->
                [ meta.target, [ control_id: meta.control_id, tagdir: tagdir ] ]
            }
            .groupTuple(by: 0)

        def ch_annotate_input = ch_master_by_target
            .join(ch_tagdirs_by_target, by: 0)
            .combine(ch_control_tagdirs_singleton)
            .map { _target, meta, peaks_bed, target_entries, ctrl_wrap ->
                def target_tds    = target_entries.collect { it.tagdir }
                def ref_ctrl_ids  = target_entries.collect { it.control_id }.findAll { it } as Set
                def all_ctrls     = ctrl_wrap.controls
                def matched_ctrls = ref_ctrl_ids
                    ? all_ctrls.findAll { it.id in ref_ctrl_ids }
                    : all_ctrls
                def combined_tds  = target_tds + matched_ctrls.collect { it.tagdir }
                [ meta, peaks_bed, combined_tds ]
            }

        HOMER_ANNOTATEPEAKS(
            ch_annotate_input,
            params.genome_name
        )
        ch_annotated_peaks = HOMER_ANNOTATEPEAKS.out.txt
    }

    //
    // Step f: Calling differential peaks using HOMER (getDifferentialPeaksReplicates.pl)
    //
    def ch_diff_peaks = ch_existing_diff_peaks
    if (params.run_homer_diffpeaks && params.diff_contrasts) {
        def ch_contrasts = channel.fromList(params.diff_contrasts)

        def ch_tagdirs_by_condition = ch_tagdirs
            .map { meta, tagdir -> [ meta.condition, tagdir ] }
            .groupTuple(by: 0)

        def ch_diff_input = ch_contrasts
            .map { contrast -> [ contrast.treatment, contrast ] }
            .combine(ch_tagdirs_by_condition, by: 0)
            .map { _treat_cond, contrast, treat_tagdirs ->
                [ contrast.background, contrast, treat_tagdirs ]
            }
            .combine(ch_tagdirs_by_condition, by: 0)
            .map { _bg_cond, contrast, treat_tagdirs, bg_tagdirs ->
                [ contrast.target, contrast, treat_tagdirs, bg_tagdirs ]
            }
            .combine(ch_master_by_target, by: 0)
            .map { _target, contrast, treat_tagdirs, bg_tagdirs, _master_meta, master_bed ->
                [
                    [
                        id        : contrast.id,
                        treatment : contrast.treatment,
                        background: contrast.background,
                        target    : contrast.target
                    ],
                    treat_tagdirs,
                    bg_tagdirs,
                    master_bed
                ]
            }

        HOMER_GETDIFFERENTIALPEAKS(
            ch_diff_input,
            params.genome_name
        )
        ch_diff_peaks = HOMER_GETDIFFERENTIALPEAKS.out.txt
    }

    emit:
    annotated_peaks = ch_annotated_peaks
    diff_peaks      = ch_diff_peaks
}
