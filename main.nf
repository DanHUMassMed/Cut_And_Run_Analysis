#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CUT&RUN Downstream Peak Analysis Pipeline
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CUTANDRUN } from './workflows/cutandrun'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HELP MESSAGE & METADATA HELPERS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def helpMessage() {
    log.info """
    ========================================================================
     CUT&RUN Downstream Peak Analysis Pipeline
    ========================================================================
    Usage:
      nextflow -c config/experiment.config run ../nf-cutandrun -resume

    Core Paths & Inputs:
      --experiment                  Experiment name (default: ${params.experiment})
      --input_dir                   Upstream Dropbox directory (default: ${params.input_dir})
      --bigwig_source               Dropbox 08_bigwig subfolder: 'deepTools' or 'UCSC' (default: ${params.bigwig_source})
      --outdir                      Output directory for results (default: ${params.outdir})
      --samplesheet                 Sample metadata CSV (default: ${params.samplesheet})

    Step Toggles:
      --run_macs2_callpeak          Step c: MACS2 callpeak (default: ${params.run_macs2_callpeak})
      --run_homer_findpeaks         Step c: HOMER findPeaks (default: ${params.run_homer_findpeaks})
      --run_merge_replicate_peaks   Step d: Merge replicate peaks (default: ${params.run_merge_replicate_peaks})
      --run_merge_master_peaks      Step d: Merge master peaks per target (default: ${params.run_merge_master_peaks})
      --run_homer_annotatepeaks     Step e: HOMER annotatePeaks.pl (default: ${params.run_homer_annotatepeaks})
      --run_homer_diffpeaks         Step f: HOMER getDifferentialPeaksReplicates.pl (default: ${params.run_homer_diffpeaks})
      --run_deeptools_metapeak      Step g: deepTools computeMatrix + plotHeatmap (default: ${params.run_deeptools_metapeak})
      --run_homer_findmotifs        Step h: HOMER findMotifsGenome.pl (default: ${params.run_homer_findmotifs})
      --run_meme_streme             Step h: MEME Suite STREME motif discovery (default: ${params.run_meme_streme})
      --run_summary_plots           Step i: Automated QC & summary plots (default: ${params.run_summary_plots})
    ========================================================================
    """.stripIndent()
}

def loadSamplesheetMap(samplesheet_path) {
    def meta_map = [:]
    if (!samplesheet_path) {
        return meta_map
    }
    def sheet_file = file(samplesheet_path)
    if (!sheet_file.exists()) {
        return meta_map
    }
    sheet_file.splitCsv(header: true, strip: true).each { row ->
        if (row.sample_id) {
            meta_map[row.sample_id] = [
                id         : row.sample_id,
                sample_name: row.sample_name ?: row.sample_id,
                condition  : row.condition ?: (row.sample_name ?: 'default'),
                target     : row.target ?: 'default',
                replicate  : row.replicate ? row.replicate.toInteger() : 1,
                control_id : row.control_id ?: null
            ]
        }
    }
    return meta_map
}

def extractSampleId(filepath, suffixes = []) {
    def name = filepath.getName()
    def matched_suffix = suffixes.find { suffix -> name.endsWith(suffix) }
    if (matched_suffix) {
        return name.substring(0, name.length() - matched_suffix.length())
    }
    return filepath.getBaseName()
}

def buildMeta(sample_id, samplesheet_map) {
    return samplesheet_map.containsKey(sample_id)
        ? samplesheet_map[sample_id]
        : [
            id         : sample_id,
            sample_name: sample_id,
            condition  : 'default',
            target     : 'default',
            replicate  : 1,
            control_id : null
        ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MAIN WORKFLOW Entrypoint
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {

    main:
    if (params.help) {
        helpMessage()
        exit 0
    }

    if (!params.experiment || !params.input_dir) {
        error("params.experiment and params.input_dir do not have defaults and must be set in config/experiment.config.")
    }

    def resolved_bam_glob     = params.input_bam ?: "${params.input_dir}/06_index_bam/*.bam"
    def resolved_tagdirs_glob = params.input_tagdirs ?: "${params.input_dir}/07_homer/tag_dir/*"
    def resolved_bigwig_glob  = params.input_bigwig ?: "${params.input_dir}/08_bigwig/${params.bigwig_source}/*.bw"

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
    // Resolve indexed BAMs from Dropbox (06_index_bam/*.bam) when MACS2 peak calling is enabled
    //
    def ch_bam_bai = params.run_macs2_callpeak
        ? channel
            .fromPath(resolved_bam_glob, checkIfExists: true)
            .filter { bam_file ->
                if (bam_file.size() == 0) {
                    log.warn "Skipping 0-byte BAM file (Dropbox online-only placeholder?): ${bam_file}"
                    return false
                }
                return true
            }
            .map { bam_file ->
                def sample_id = extractSampleId(bam_file, ['.bam'])
                def bai_file = file("${bam_file}.bai", checkIfExists: true)
                [ buildMeta(sample_id, samplesheet_map), bam_file, bai_file ]
            }
        : channel.empty()

    //
    // Resolve HOMER Tag Directories from Dropbox (07_homer/tag_dir/*) when HOMER steps are enabled
    //
    def needs_tagdirs = (
        params.run_homer_findpeaks ||
        params.run_homer_annotatepeaks ||
        params.run_homer_diffpeaks
    )
    def ch_tagdirs = needs_tagdirs
        ? channel
            .fromPath(resolved_tagdirs_glob, type: 'dir', checkIfExists: true)
            .map { tagdir ->
                def sample_id = extractSampleId(tagdir, ['_tagdir'])
                [ buildMeta(sample_id, samplesheet_map), tagdir ]
            }
        : channel.empty()

    //
    // Resolve BigWig files from Dropbox (08_bigwig/deepTools/*.bw or 08_bigwig/UCSC/*.bw) when metapeak plotting is enabled
    //
    def ch_bigwig = params.run_deeptools_metapeak
        ? channel
            .fromPath(resolved_bigwig_glob, checkIfExists: true)
            .filter { bw_file ->
                if (bw_file.size() == 0) {
                    log.warn "Skipping 0-byte BigWig file (Dropbox online-only placeholder?): ${bw_file}"
                    return false
                }
                return true
            }
            .map { bw_file ->
                def sample_id = extractSampleId(bw_file, ['.bw', '.bigWig'])
                [ buildMeta(sample_id, samplesheet_map), bw_file ]
            }
        : channel.empty()

    //
    // Resolve pre-existing per-sample peak files when both MACS2 and HOMER peak callers are toggled off
    //
    def needs_existing_sample_peaks = !params.run_macs2_callpeak && !params.run_homer_findpeaks && (
        params.run_merge_replicate_peaks ||
        params.run_merge_master_peaks ||
        params.run_summary_plots
    )
    def ch_existing_sample_peaks = needs_existing_sample_peaks
        ? channel
            .fromPath(params.input_sample_peaks, checkIfExists: params.run_merge_replicate_peaks || params.run_merge_master_peaks)
            .map { peak_file ->
                def sample_id = extractSampleId(peak_file, [
                    '_peaks.narrowPeak',
                    '_peaks.broadPeak',
                    '_peaks.bed',
                    '.narrowPeak',
                    '.broadPeak',
                    '.bed'
                ])
                [ buildMeta(sample_id, samplesheet_map), peak_file ]
            }
        : channel.empty()

    //
    // Resolve pre-existing condition-merged replicate peaks when run_merge_replicate_peaks is toggled off
    //
    def needs_existing_replicated_peaks = !params.run_merge_replicate_peaks && (
        (params.run_merge_master_peaks && !needs_existing_sample_peaks && !params.run_macs2_callpeak && !params.run_homer_findpeaks) ||
        params.run_summary_plots
    )
    def ch_existing_replicated_peaks = needs_existing_replicated_peaks
        ? channel
            .fromPath(params.input_replicated_peaks, checkIfExists: params.run_merge_master_peaks && !params.run_summary_plots)
            .map { rep_bed ->
                def condition_id = extractSampleId(rep_bed, ['_replicated_peaks.bed', '.bed'])
                def target_name = condition_to_target[condition_id] ?: 'default'
                [ [ id: condition_id, condition: condition_id, target: target_name ], rep_bed ]
            }
        : channel.empty()

    //
    // Resolve pre-existing master peak files per target when run_merge_master_peaks is toggled off
    //
    def needs_existing_master_peaks = !params.run_merge_master_peaks && (
        params.run_homer_annotatepeaks ||
        params.run_homer_diffpeaks ||
        params.run_deeptools_metapeak ||
        params.run_homer_findmotifs ||
        params.run_meme_streme ||
        params.run_summary_plots
    )
    def ch_existing_master_peaks = needs_existing_master_peaks
        ? channel
            .fromPath(params.input_peaks_bed, checkIfExists: true)
            .map { master_bed ->
                def target_name = extractSampleId(master_bed, ['_master_peaks.bed', '.bed'])
                [ [ id: target_name, target: target_name ], master_bed ]
            }
        : channel.empty()

    //
    // Resolve pre-existing annotated peak tables when run_homer_annotatepeaks is toggled off
    //
    def resolved_annotated_glob = params.input_annotated_peaks ?: "${params.outdir}/11_peak_quantification/*_annotated_peaks.txt"
    def ch_existing_annotated_peaks = (!params.run_homer_annotatepeaks && params.run_summary_plots)
        ? channel
            .fromPath(resolved_annotated_glob, checkIfExists: false)
            .map { annot_txt ->
                def target_name = extractSampleId(annot_txt, ['_annotated_peaks.txt', '.txt'])
                [ [ id: target_name, target: target_name ], annot_txt ]
            }
        : channel.empty()

    //
    // Resolve pre-existing differential peak tables when run_homer_diffpeaks is toggled off
    //
    def contrast_map = [:]
    if (params.diff_contrasts) {
        params.diff_contrasts.each { c ->
            contrast_map[c.id] = c
        }
    }
    def resolved_diff_glob = params.input_diff_peaks ?: "${params.outdir}/12_differential_peaks/*_differential_peaks.txt"
    def ch_existing_diff_peaks = (!params.run_homer_diffpeaks && params.run_summary_plots)
        ? channel
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
        : channel.empty()

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
