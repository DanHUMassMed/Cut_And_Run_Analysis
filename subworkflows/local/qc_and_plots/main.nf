/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW: QC_AND_PLOTS
    Step g: Peak-centered & gene-level deepTools metaplots (auto-including IgG if present)
    Step i: Summary & Task 1 QC plots (peak counts, features, correlation/PCA, signal,
            volcano/MA, deepTools fingerprint & BigWig QC, FRiP & read-retention depth)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { DEEPTOOLS_METAPEAK           } from '../../../modules/local/deeptools/metapeak/main'
include { DEEPTOOLS_PLOTFINGERPRINT    } from '../../../modules/local/deeptools/plotfingerprint/main'
include { DEEPTOOLS_BIGWIG_QC          } from '../../../modules/local/deeptools/bigwig_qc/main'
include { DEEPTOOLS_GENE_METAPLOT      } from '../../../modules/local/deeptools/gene_metaplot/main'
include { UTIL_PREPARE_GENE_BED        } from '../../../modules/local/python/util_prepare_gene_bed/main'
include { PLOT_PEAK_COUNTS             } from '../../../modules/local/python/plot_peak_counts/main'
include { PLOT_ANNOTATED_SUMMARY       } from '../../../modules/local/python/plot_annotated_summary/main'
include { PLOT_DIFFERENTIAL_VOLCANO_MA } from '../../../modules/local/python/plot_differential_volcano_ma/main'
include { PLOT_FRIP_AND_DEPTH          } from '../../../modules/local/python/plot_frip_and_depth/main'
include { isControlTarget              } from '../../../lib/utils'

workflow QC_AND_PLOTS {

    take:
    ch_bam_bai                // channel: [ val(meta), path(bam), path(bai) ]
    ch_tagdirs                // channel: [ val(meta), path(tagdir) ]
    ch_bigwig                 // channel: [ val(meta), path(bw) ]
    ch_macs2_peaks            // channel: [ val(meta), path(bed) ]
    ch_homer_peaks            // channel: [ val(meta), path(bed) ]
    ch_active_sample_peaks    // channel: [ val(meta), path(bed) ]
    ch_replicated_peaks       // channel: [ val(meta), path(bed) ]
    ch_master_peaks           // channel: [ val(meta), path(bed) ]
    ch_annotated_peaks        // channel: [ val(meta), path(txt) ]
    ch_diff_peaks             // channel: [ val(meta), path(txt) ]
    upstream_trimmomatic_logs // list: [ path(log), ... ]
    upstream_bowtie2_logs     // list: [ path(log), ... ]
    upstream_picard_dups      // list: [ path(dup_txt), ... ]
    upstream_bam_stats        // list: [ path(stat_file), ... ]

    main:
    def ch_master_by_target = ch_master_peaks.map { meta, bed ->
        [ meta.target, meta, bed ]
    }

    //
    // Split BigWigs into IgG controls vs. targets and group per target with matched IgG controls
    // appended at the end (always emits even when no IgG controls exist).
    //
    def ch_bigwig_split = ch_bigwig.branch { meta, bw ->
        control: isControlTarget(meta)
        target:  true
    }

    def ch_control_bigwigs_singleton = ch_bigwig_split.control
        .map { meta, bw -> [ id: meta.id, sample_name: meta.sample_name, bw: bw ] }
        .toList()
        .map { ctrls -> [ controls: ctrls.sort { a, b -> a.bw.name <=> b.bw.name } ] }

    def ch_bigwigs_by_target_with_ctrl = ch_bigwig_split.target
        .map { meta, bw ->
            [ meta.target, [ sample_name: meta.sample_name, control_id: meta.control_id, bw: bw ] ]
        }
        .groupTuple(by: 0)
        .combine(ch_control_bigwigs_singleton)
        .map { target, target_entries, ctrl_wrap ->
            def sorted_targets = target_entries.sort { a, b -> a.bw.name <=> b.bw.name }
            def ref_ctrl_ids   = sorted_targets.collect { it.control_id }.findAll { it } as Set
            def all_ctrls      = ctrl_wrap.controls
            def matched_ctrls  = ref_ctrl_ids
                ? all_ctrls.findAll { it.id in ref_ctrl_ids }
                : all_ctrls
            def combined       = sorted_targets + matched_ctrls
            [
                target,
                combined.collect { it.sample_name },
                combined.collect { it.bw }
            ]
        }

    //
    // Step g (1): Making peak-centered metapeak plots (tornado plots) using deepTools
    //
    def ch_metapeak_pdf    = channel.empty()
    def ch_metapeak_matrix = channel.empty()
    if (params.run_deeptools_metapeak) {
        def ch_metapeak_input = ch_master_by_target
            .join(ch_bigwigs_by_target_with_ctrl, by: 0)
            .map { _target, meta, peaks_bed, sample_names, bigwigs ->
                [ meta + [ sample_names: sample_names ], peaks_bed, bigwigs ]
            }

        DEEPTOOLS_METAPEAK(ch_metapeak_input)
        ch_metapeak_matrix = DEEPTOOLS_METAPEAK.out.matrix
        ch_metapeak_pdf    = DEEPTOOLS_METAPEAK.out.pdf
    }

    //
    // Step i: Automated QC & summary plots (all driven by params.run_summary_plots)
    //
    def ch_peak_counts_svg       = channel.empty()
    def ch_features_svg          = channel.empty()
    def ch_corr_pca_svg          = channel.empty()
    def ch_signal_svg            = channel.empty()
    def ch_volcano_ma_svg        = channel.empty()
    def ch_fingerprint_pdf       = channel.empty()
    def ch_bw_corr_pdf           = channel.empty()
    def ch_frip_tsv              = channel.empty()
    def ch_depth_tsv             = channel.empty()
    def ch_gene_tss_profile      = channel.empty()
    def ch_gene_genebody_profile = channel.empty()

    if (params.run_summary_plots) {
        def samplesheet_file = file(params.samplesheet, checkIfExists: true)

        // Plot 1: Peak Count & Replicate Overlap Bar Chart
        def ch_all_peak_files = ch_macs2_peaks
            .mix(ch_homer_peaks)
            .mix(ch_active_sample_peaks)
            .mix(ch_replicated_peaks)
            .mix(ch_master_peaks)
            .map { _meta, bed -> bed }
            .unique()
            .collect()

        PLOT_PEAK_COUNTS(
            samplesheet_file,
            ch_all_peak_files
        )
        ch_peak_counts_svg = PLOT_PEAK_COUNTS.out.svg

        // Plots 2, 3, & 4: Genomic Feature Breakdown, Sample Correlation/PCA, & Signal/Width Distributions
        PLOT_ANNOTATED_SUMMARY(
            ch_annotated_peaks,
            samplesheet_file
        )
        ch_features_svg = PLOT_ANNOTATED_SUMMARY.out.features_svg
        ch_corr_pca_svg = PLOT_ANNOTATED_SUMMARY.out.corr_pca_svg
        ch_signal_svg   = PLOT_ANNOTATED_SUMMARY.out.signal_svg

        // Plot 5: Volcano & MA Plots for Condition Comparisons
        PLOT_DIFFERENTIAL_VOLCANO_MA(
            ch_diff_peaks
        )
        ch_volcano_ma_svg = PLOT_DIFFERENTIAL_VOLCANO_MA.out.svg

        // Plot 6: Peak-independent deepTools QC (plotFingerprint, multiBigwigSummary, plotCorrelation, plotPCA)
        def ch_fingerprint_input = ch_bam_bai
            .toList()
            .filter { entries -> entries.size() > 0 }
            .map { entries ->
                def sorted_entries = entries.sort { a, b ->
                    def a_ctrl = isControlTarget(a[0]) ? 1 : 0
                    def b_ctrl = isControlTarget(b[0]) ? 1 : 0
                    a_ctrl <=> b_ctrl ?: a[0].target.toLowerCase() <=> b[0].target.toLowerCase() ?: a[0].sample_name.toLowerCase() <=> b[0].sample_name.toLowerCase()
                }
                [
                    [ id: 'all_samples', sample_names: sorted_entries.collect { it[0].sample_name } ],
                    sorted_entries.collect { it[1] },
                    sorted_entries.collect { it[2] }
                ]
            }

        DEEPTOOLS_PLOTFINGERPRINT(ch_fingerprint_input)
        ch_fingerprint_pdf = DEEPTOOLS_PLOTFINGERPRINT.out.pdf

        def ch_bw_qc_input = ch_bigwig
            .toList()
            .filter { entries -> entries.size() > 0 }
            .map { entries ->
                def sorted_entries = entries.sort { a, b ->
                    def a_ctrl = isControlTarget(a[0]) ? 1 : 0
                    def b_ctrl = isControlTarget(b[0]) ? 1 : 0
                    a_ctrl <=> b_ctrl ?: a[0].target.toLowerCase() <=> b[0].target.toLowerCase() ?: a[0].sample_name.toLowerCase() <=> b[0].sample_name.toLowerCase()
                }
                [
                    [ id: 'all_samples', sample_names: sorted_entries.collect { it[0].sample_name } ],
                    sorted_entries.collect { it[1] }
                ]
            }

        DEEPTOOLS_BIGWIG_QC(ch_bw_qc_input)
        ch_bw_corr_pdf = DEEPTOOLS_BIGWIG_QC.out.corr_pdf

        // Plot 7: FRiP (Target vs. IgG) & Read-Retention / Sequencing Depth Summary
        def chrom_sizes_opt = (params.chrom_sizes && file(params.chrom_sizes).exists())
            ? file(params.chrom_sizes)
            : []

        def ch_all_bams         = ch_bam_bai.map { _meta, bam, _bai -> bam }.collect().ifEmpty([])
        def ch_all_bais         = ch_bam_bai.map { _meta, _bam, bai -> bai }.collect().ifEmpty([])
        def ch_all_sample_peaks = ch_active_sample_peaks.map { _meta, bed -> bed }.collect().ifEmpty([])
        def ch_all_master_peaks = ch_master_peaks.map { _meta, bed -> bed }.collect().ifEmpty([])
        def ch_all_tagdirs      = ch_tagdirs.map { _meta, td -> td }.collect().ifEmpty([])

        PLOT_FRIP_AND_DEPTH(
            samplesheet_file,
            ch_all_bams,
            ch_all_bais,
            ch_all_sample_peaks,
            ch_all_master_peaks,
            ch_all_tagdirs,
            upstream_trimmomatic_logs ?: [],
            upstream_bowtie2_logs ?: [],
            upstream_picard_dups ?: [],
            upstream_bam_stats ?: [],
            chrom_sizes_opt
        )
        ch_frip_tsv  = PLOT_FRIP_AND_DEPTH.out.frip_tsv
        ch_depth_tsv = PLOT_FRIP_AND_DEPTH.out.depth_tsv

        // Gene-level TSS & Gene-Body Metaplots
        def ch_gene_bed
        if (params.gene_bed) {
            ch_gene_bed = channel.value(file(params.gene_bed, checkIfExists: true))
        } else {
            def homer_rna_file   = file("${params.homer_dir}/data/genomes/${params.genome_name}/${params.genome_name}.rna", checkIfExists: true)
            def chrom_sizes_file = file(params.chrom_sizes, checkIfExists: true)
            UTIL_PREPARE_GENE_BED(
                params.genome_name,
                homer_rna_file,
                chrom_sizes_file
            )
            ch_gene_bed = UTIL_PREPARE_GENE_BED.out.bed
        }

        def ch_gene_metaplot_input = ch_bigwigs_by_target_with_ctrl
            .combine(ch_gene_bed)
            .map { target, sample_names, bigwigs, gene_bed ->
                [ [ id: target, target: target, sample_names: sample_names ], gene_bed, bigwigs ]
            }

        DEEPTOOLS_GENE_METAPLOT(ch_gene_metaplot_input)
        ch_gene_tss_profile      = DEEPTOOLS_GENE_METAPLOT.out.tss_profile
        ch_gene_genebody_profile = DEEPTOOLS_GENE_METAPLOT.out.genebody_profile
    }

    emit:
    metapeak_matrix       = ch_metapeak_matrix
    metapeak_pdf          = ch_metapeak_pdf
    gene_tss_profile      = ch_gene_tss_profile
    gene_genebody_profile = ch_gene_genebody_profile
    peak_counts_svg       = ch_peak_counts_svg
    features_svg          = ch_features_svg
    corr_pca_svg          = ch_corr_pca_svg
    signal_svg            = ch_signal_svg
    volcano_ma_svg        = ch_volcano_ma_svg
    fingerprint_pdf       = ch_fingerprint_pdf
    bw_corr_pdf           = ch_bw_corr_pdf
    frip_tsv              = ch_frip_tsv
    depth_tsv             = ch_depth_tsv
}
