/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { MACS2_CALLPEAK               } from '../modules/local/macs2_callpeak/main'
include { HOMER_FINDPEAKS              } from '../modules/local/homer_findpeaks/main'
include { BEDTOOLS_MERGE_REPLICATES    } from '../modules/local/bedtools_merge_replicates/main'
include { BEDTOOLS_MERGE_MASTER        } from '../modules/local/bedtools_merge_master/main'
include { HOMER_ANNOTATEPEAKS          } from '../modules/local/homer_annotatepeaks/main'
include { HOMER_GETDIFFERENTIALPEAKS   } from '../modules/local/homer_getdifferentialpeaks/main'
include { DEEPTOOLS_METAPEAK           } from '../modules/local/deeptools_metapeak/main'
include { HOMER_FINDMOTIFSGENOME       } from '../modules/local/homer_findmotifsgenome/main'
include { MEME_STREME                  } from '../modules/local/meme_streme/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow CUTANDRUN {

    take:
    ch_bam_bai                   // channel: [ val(meta), path(bam), path(bai) ]
    ch_tagdirs                   // channel: [ val(meta), path(tagdir) ]
    ch_bigwig                    // channel: [ val(meta), path(bw) ]
    ch_existing_sample_peaks     // channel: [ val(meta), path(peaks_bed) ]
    ch_existing_replicated_peaks // channel: [ val(meta), path(replicated_peaks_bed) ]
    ch_existing_master_peaks     // channel: [ val(meta), path(master_peaks_bed) ]

    main:

    //
    // Filter out negative control (IgG) samples before peak calling & merging
    //
    def ch_target_bam_bai = ch_bam_bai.filter { meta, _bam, _bai ->
        meta.target?.toLowerCase() != 'igg'
    }
    def ch_target_tagdirs = ch_tagdirs.filter { meta, _tagdir ->
        meta.target?.toLowerCase() != 'igg'
    }

    //
    // Step c (1): Calling peaks with MACS2
    //
    def ch_macs2_peaks = channel.empty()
    if (params.run_macs2_callpeak) {
        MACS2_CALLPEAK(ch_target_bam_bai)
        ch_macs2_peaks = MACS2_CALLPEAK.out.peak
    }

    //
    // Step c (2): Calling peaks with HOMER
    //
    def ch_homer_peaks = channel.empty()
    if (params.run_homer_findpeaks) {
        HOMER_FINDPEAKS(ch_target_tagdirs)
        ch_homer_peaks = HOMER_FINDPEAKS.out.bed
    }

    //
    // Select active per-sample peaks for Step d (MACS2, HOMER, or pre-existing)
    //
    def ch_active_sample_peaks = ch_existing_sample_peaks
    if (params.active_peak_caller == 'homer' && params.run_homer_findpeaks) {
        ch_active_sample_peaks = ch_homer_peaks
    } else if (params.active_peak_caller == 'macs2' && params.run_macs2_callpeak) {
        ch_active_sample_peaks = ch_macs2_peaks
    } else if (params.run_macs2_callpeak) {
        ch_active_sample_peaks = ch_macs2_peaks
    } else if (params.run_homer_findpeaks) {
        ch_active_sample_peaks = ch_homer_peaks
    }

    //
    // Step d (1): Merging replicate peak files per condition using bedtools
    //
    def ch_replicated_peaks = ch_existing_replicated_peaks
    if (params.run_merge_replicate_peaks) {
        def ch_grouped_condition_peaks = ch_active_sample_peaks
            .filter { meta, _bed -> meta.target?.toLowerCase() != 'igg' }
            .map { meta, bed ->
                [ [ id: meta.condition, condition: meta.condition, target: meta.target ?: 'default' ], bed ]
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
            .filter { meta, _bed -> meta.target?.toLowerCase() != 'igg' }
            .map { meta, bed ->
                def target_name = meta.target ?: 'default'
                [ [ id: target_name, target: target_name ], bed ]
            }
            .groupTuple(by: 0)

        BEDTOOLS_MERGE_MASTER(ch_grouped_target_beds)
        ch_master_peaks = BEDTOOLS_MERGE_MASTER.out.bed
    }

    //
    // Key master peaks by target_name: [ val(target_name), val(meta), path(master_bed) ]
    //
    def ch_master_by_target = ch_master_peaks.map { meta, bed ->
        [ meta.target ?: meta.id, meta, bed ]
    }

    //
    // Step e: Peak-by-peak analysis using HOMER (annotatePeaks.pl)
    //
    def ch_annotated_peaks = channel.empty()
    if (params.run_homer_annotatepeaks) {
        def ch_tagdirs_by_target = ch_tagdirs
            .filter { meta, _tagdir -> meta.target?.toLowerCase() != 'igg' }
            .map { meta, tagdir -> [ meta.target ?: 'default', tagdir ] }
            .groupTuple(by: 0)

        def ch_annotate_input = ch_master_by_target
            .join(ch_tagdirs_by_target, by: 0)
            .map { _target, meta, peaks_bed, tagdirs ->
                [ meta, peaks_bed, tagdirs ]
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
    def ch_diff_peaks = channel.empty()
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
                [ contrast.target ?: 'default', contrast, treat_tagdirs, bg_tagdirs ]
            }
            .combine(ch_master_by_target, by: 0)
            .map { _target, contrast, treat_tagdirs, bg_tagdirs, _master_meta, master_bed ->
                [
                    [
                        id        : contrast.id,
                        treatment : contrast.treatment,
                        background: contrast.background,
                        target    : contrast.target ?: 'default'
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

    //
    // Step g: Making metapeak plots (tornado plots) using deepTools
    //
    def ch_metapeak_pdf = channel.empty()
    def ch_metapeak_matrix = channel.empty()
    if (params.run_deeptools_metapeak) {
        def ch_bigwigs_by_target = ch_bigwig
            .filter { meta, _bw -> meta.target?.toLowerCase() != 'igg' }
            .map { meta, bw ->
                [ meta.target ?: 'default', [ meta.sample_name ?: meta.id, bw ] ]
            }
            .groupTuple(by: 0)
            .map { target, sample_bw_pairs ->
                def sorted_pairs = sample_bw_pairs.sort { a, b -> a[1].name <=> b[1].name }
                [
                    target,
                    sorted_pairs.collect { pair -> pair[0] },
                    sorted_pairs.collect { pair -> pair[1] }
                ]
            }

        def ch_metapeak_input = ch_master_by_target
            .join(ch_bigwigs_by_target, by: 0)
            .map { _target, meta, peaks_bed, sample_names, bigwigs ->
                [ meta + [ sample_names: sample_names ], peaks_bed, bigwigs ]
            }

        DEEPTOOLS_METAPEAK(ch_metapeak_input)
        ch_metapeak_matrix = DEEPTOOLS_METAPEAK.out.matrix
        ch_metapeak_pdf    = DEEPTOOLS_METAPEAK.out.pdf
    }

    //
    // Step h (1): Looking for enriched motifs in peaks using HOMER (findMotifsGenome.pl)
    //
    def ch_homer_motifs = channel.empty()
    if (params.run_homer_findmotifs) {
        HOMER_FINDMOTIFSGENOME(
            ch_master_peaks,
            params.genome_name
        )
        ch_homer_motifs = HOMER_FINDMOTIFSGENOME.out.motifs_dir
    }

    //
    // Step h (2): Looking for enriched motifs in peaks using MEME Suite (STREME)
    //
    def ch_meme_motifs = channel.empty()
    if (params.run_meme_streme) {
        if (!params.chrom_sizes || !params.genome_fasta) {
            error("params.chrom_sizes and params.genome_fasta must be provided when params.run_meme_streme = true")
        }
        def chrom_sizes_file  = file(params.chrom_sizes, checkIfExists: true)
        def genome_fasta_file = file(params.genome_fasta, checkIfExists: true)

        MEME_STREME(
            ch_master_peaks,
            chrom_sizes_file,
            genome_fasta_file,
            params.meme_slop_left,
            params.meme_slop_right
        )
        ch_meme_motifs = MEME_STREME.out.motifs_dir
    }

    //
    // Collate software versions from Nextflow topic channel
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':') + 1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by: 0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = topic_versions_string
        .mix(topic_versions.versions_file.map { version_file -> version_file.text })
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'software_mqc_versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    bam_bai          = ch_bam_bai
    tagdirs          = ch_tagdirs
    bigwig           = ch_bigwig
    macs2_peaks      = ch_macs2_peaks
    homer_peaks      = ch_homer_peaks
    replicated_peaks = ch_replicated_peaks
    master_peaks     = ch_master_peaks
    annotated_peaks  = ch_annotated_peaks
    diff_peaks       = ch_diff_peaks
    metapeak_matrix  = ch_metapeak_matrix
    metapeak_pdf     = ch_metapeak_pdf
    homer_motifs     = ch_homer_motifs
    meme_motifs      = ch_meme_motifs
    versions         = ch_collated_versions
}
