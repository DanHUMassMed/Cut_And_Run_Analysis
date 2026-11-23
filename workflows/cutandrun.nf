/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { PEAK_CALLING             } from '../subworkflows/local/peak_calling/main'
include { PEAK_ANNOTATION_AND_DIFF } from '../subworkflows/local/peak_annotation_and_diff/main'
include { MOTIF_DISCOVERY          } from '../subworkflows/local/motif_discovery/main'
include { QC_AND_PLOTS             } from '../subworkflows/local/qc_and_plots/main'

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
    ch_existing_annotated_peaks  // channel: [ val(meta), path(annotated_peaks_txt) ]
    ch_existing_diff_peaks       // channel: [ val(meta), path(diff_peaks_txt) ]
    upstream_trimmomatic_logs    // list: [ path(trimmomatic_log), ... ]
    upstream_bowtie2_logs        // list: [ path(bowtie2_log), ... ]
    upstream_picard_dups         // list: [ path(picard_dup_txt), ... ]
    upstream_bam_stats           // list: [ path(bam_stat_file), ... ]

    main:
    //
    // Steps c & d: Peak calling (MACS2 / HOMER) & merging (replicates + master peaks)
    //
    PEAK_CALLING(
        ch_bam_bai,
        ch_tagdirs,
        ch_existing_sample_peaks,
        ch_existing_replicated_peaks,
        ch_existing_master_peaks
    )

    //
    // Steps e & f: Peak annotation (HOMER) & differential peak analysis
    //
    PEAK_ANNOTATION_AND_DIFF(
        PEAK_CALLING.out.master_peaks,
        ch_tagdirs,
        ch_existing_annotated_peaks,
        ch_existing_diff_peaks
    )

    //
    // Step h: Motif discovery (HOMER & MEME STREME)
    //
    MOTIF_DISCOVERY(
        PEAK_CALLING.out.master_peaks
    )

    //
    // Steps g & i: Metapeak/gene-level plots & automated QC / summary plots
    //
    QC_AND_PLOTS(
        ch_bam_bai,
        ch_tagdirs,
        ch_bigwig,
        PEAK_CALLING.out.macs2_peaks,
        PEAK_CALLING.out.homer_peaks,
        PEAK_CALLING.out.active_sample_peaks,
        PEAK_CALLING.out.replicated_peaks,
        PEAK_CALLING.out.master_peaks,
        PEAK_ANNOTATION_AND_DIFF.out.annotated_peaks,
        PEAK_ANNOTATION_AND_DIFF.out.diff_peaks,
        upstream_trimmomatic_logs,
        upstream_bowtie2_logs,
        upstream_picard_dups,
        upstream_bam_stats
    )

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
    bam_bai               = ch_bam_bai
    tagdirs               = ch_tagdirs
    bigwig                = ch_bigwig
    macs2_peaks           = PEAK_CALLING.out.macs2_peaks
    homer_peaks           = PEAK_CALLING.out.homer_peaks
    replicated_peaks      = PEAK_CALLING.out.replicated_peaks
    master_peaks          = PEAK_CALLING.out.master_peaks
    annotated_peaks       = PEAK_ANNOTATION_AND_DIFF.out.annotated_peaks
    diff_peaks            = PEAK_ANNOTATION_AND_DIFF.out.diff_peaks
    metapeak_matrix       = QC_AND_PLOTS.out.metapeak_matrix
    metapeak_pdf          = QC_AND_PLOTS.out.metapeak_pdf
    gene_tss_profile      = QC_AND_PLOTS.out.gene_tss_profile
    gene_genebody_profile = QC_AND_PLOTS.out.gene_genebody_profile
    homer_motifs          = MOTIF_DISCOVERY.out.homer_motifs
    meme_motifs           = MOTIF_DISCOVERY.out.meme_motifs
    peak_counts_svg       = QC_AND_PLOTS.out.peak_counts_svg
    features_svg          = QC_AND_PLOTS.out.features_svg
    corr_pca_svg          = QC_AND_PLOTS.out.corr_pca_svg
    signal_svg            = QC_AND_PLOTS.out.signal_svg
    volcano_ma_svg        = QC_AND_PLOTS.out.volcano_ma_svg
    fingerprint_pdf       = QC_AND_PLOTS.out.fingerprint_pdf
    bw_corr_pdf           = QC_AND_PLOTS.out.bw_corr_pdf
    frip_tsv              = QC_AND_PLOTS.out.frip_tsv
    depth_tsv             = QC_AND_PLOTS.out.depth_tsv
    versions              = ch_collated_versions
}
