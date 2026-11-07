#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CUT&RUN Upstream Base Pipeline (HPC)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CUTANDRUN_BASE } from './workflows/cutandrun_base'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HELP MESSAGE & METADATA HELPERS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def helpMessage() {
    log.info """
    ========================================================================
     CUT&RUN Upstream Base Pipeline (HPC)
    ========================================================================
    Usage:
      nextflow -c config/experiment.config run ../nf-cutandrun-base -profile hpc -resume

    Core Paths & Inputs:
      --experiment                  Experiment name (default: ${params.experiment})
      --fastq_dir                   Directory containing raw paired-end FASTQ files (default: ${params.fastq_dir})
      --outdir                      Output directory for results (default: ${params.outdir})
      --samplesheet                 Optional sample metadata CSV (default: ${params.samplesheet})

    Step Toggles:
      --run_raw_fastqc              Step 00: FastQC & MultiQC on raw FASTQ pairs (default: ${params.run_raw_fastqc})
      --run_trimmomatic             Step 01: Trimmomatic PE adapter trimming (default: ${params.run_trimmomatic})
      --run_trimmed_fastqc          Step 02: FastQC & MultiQC on trimmed FASTQ pairs (default: ${params.run_trimmed_fastqc})
      --run_bowtie2_align           Step 03: Bowtie2 paired-end alignment (default: ${params.run_bowtie2_align})
      --run_picard_dedup            Step 04: Picard SortSam & MarkDuplicates (default: ${params.run_picard_dedup})
      --run_mapq_filter             Step 05: samtools view MAPQ filter (default: ${params.run_mapq_filter})
      --run_index_bam               Step 06: samtools BAM + index + deepTools RPKM BigWig (default: ${params.run_index_bam})
      --run_homer_ucsc              Step 07: HOMER makeTagDirectory + makeUCSCfile (default: ${params.run_homer_ucsc})
      --run_ucsc_bigwig             Step 08: UCSC bedGraphToBigWig conversion (default: ${params.run_ucsc_bigwig})
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

def normalizePairKey(pair_key) {
    return pair_key
        .replaceAll(/\.paired\.trim$/, '')
        .replaceAll(/_paired$/, '')
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

    if (!params.experiment || !params.fastq_dir || !params.outdir) {
        error("params.experiment, params.fastq_dir, and params.outdir must be set in config/experiment.config.")
    }

    def resolved_fastq_glob   = params.input_fastq         ?: "${params.fastq_dir}/*_R{1,2}_*.f*q.gz"
    def resolved_trimmed_glob = params.input_trimmed_fastq ?: "${params.outdir}/01_trim/*{_R1_paired.fq.gz,_R2_paired.fq.gz,.paired.trim_1.fastq.gz,.paired.trim_2.fastq.gz}"
    def resolved_align_glob   = params.input_align_sam     ?: "${params.outdir}/03_align/*_bowtieoutput.sam"
    def resolved_dedup_glob   = params.input_dedup_bam     ?: "${params.outdir}/04_dedup/*_PicardDedup.bam"
    def resolved_mapq_glob    = params.input_mapq_sam      ?: "${params.outdir}/05_mapq_filter/*_PicardDedup_mapqfilt.sam"
    def resolved_bg_glob      = params.input_bedgraph      ?: "${params.outdir}/07_ucsc/*/*.ucsc.bedGraph.gz"

    log.info """\
    ========================================================================
     C U T & R U N   U P S T R E A M   B A S E   P I P E L I N E
    ========================================================================
     experiment                 : ${params.experiment}
     fastq_dir                  : ${params.fastq_dir}
     input_fastq                : ${resolved_fastq_glob}
     outdir                     : ${params.outdir}
     samplesheet                : ${params.samplesheet}
     bowtie2_index              : ${params.bowtie2_index}
     chrom_sizes                : ${params.chrom_sizes}
     ----------------------------------------------------------------------
     Active Step Toggles:
       raw_fastqc               : ${params.run_raw_fastqc}
       trimmomatic              : ${params.run_trimmomatic}
       trimmed_fastqc           : ${params.run_trimmed_fastqc}
       bowtie2_align            : ${params.run_bowtie2_align}
       picard_dedup             : ${params.run_picard_dedup}
       mapq_filter              : ${params.run_mapq_filter}
       index_bam                : ${params.run_index_bam}
       homer_ucsc               : ${params.run_homer_ucsc}
       ucsc_bigwig              : ${params.run_ucsc_bigwig}
    ========================================================================
    """.stripIndent()

    //
    // Load optional sample metadata from samplesheet.csv if present
    //
    def samplesheet_map = loadSamplesheetMap(params.samplesheet)

    //
    // Resolve raw paired-end FASTQ files when raw FastQC or Trimmomatic is enabled
    //
    def needs_raw_reads = params.run_raw_fastqc || params.run_trimmomatic
    def ch_raw_reads = needs_raw_reads
        ? channel
            .fromFilePairs(resolved_fastq_glob, checkIfExists: true)
            .filter { _pair_id, reads ->
                if (reads.any { f -> f.size() == 0 && !workflow.stubRun }) {
                    log.warn "Skipping 0-byte FASTQ pair (Dropbox placeholder?): ${reads}"
                    return false
                }
                return true
            }
            .map { pair_id, reads ->
                def sample_id = normalizePairKey(pair_id)
                [ buildMeta(sample_id, samplesheet_map), reads ]
            }
        : channel.empty()

    //
    // Resolve pre-existing trimmed paired-end FASTQs when run_trimmomatic is toggled off
    //
    def needs_existing_trimmed = !params.run_trimmomatic && (
        params.run_trimmed_fastqc ||
        params.run_bowtie2_align
    )
    def ch_existing_trimmed = needs_existing_trimmed
        ? channel
            .fromFilePairs(resolved_trimmed_glob, checkIfExists: true)
            .map { pair_id, reads ->
                def sample_id = normalizePairKey(pair_id)
                [ buildMeta(sample_id, samplesheet_map), reads ]
            }
        : channel.empty()

    //
    // Resolve pre-existing Bowtie2 SAM files when run_bowtie2_align is toggled off
    //
    def needs_existing_align_sam = !params.run_bowtie2_align && params.run_picard_dedup
    def ch_existing_align_sam = needs_existing_align_sam
        ? channel
            .fromPath(resolved_align_glob, checkIfExists: true)
            .map { sam_file ->
                def sample_id = extractSampleId(sam_file, ['_bowtieoutput.sam', '.sam'])
                [ buildMeta(sample_id, samplesheet_map), sam_file ]
            }
        : channel.empty()

    //
    // Resolve pre-existing Picard deduplicated BAM files when run_picard_dedup is toggled off
    //
    def needs_existing_dedup_bam = !params.run_picard_dedup && params.run_mapq_filter
    def ch_existing_dedup_bam = needs_existing_dedup_bam
        ? channel
            .fromPath(resolved_dedup_glob, checkIfExists: true)
            .map { bam_file ->
                def sample_id = extractSampleId(bam_file, ['_PicardDedup.bam', '.bam'])
                [ buildMeta(sample_id, samplesheet_map), bam_file ]
            }
        : channel.empty()

    //
    // Resolve pre-existing MAPQ-filtered SAM files when run_mapq_filter is toggled off
    //
    def needs_existing_mapq_sam = !params.run_mapq_filter && (
        params.run_index_bam ||
        params.run_homer_ucsc
    )
    def ch_existing_mapq_sam = needs_existing_mapq_sam
        ? channel
            .fromPath(resolved_mapq_glob, checkIfExists: true)
            .map { sam_file ->
                def sample_id = extractSampleId(sam_file, ['_PicardDedup_mapqfilt.sam', '.sam'])
                [ buildMeta(sample_id, samplesheet_map), sam_file ]
            }
        : channel.empty()

    //
    // Resolve pre-existing HOMER UCSC bedGraph files when run_homer_ucsc is toggled off
    //
    def needs_existing_bedgraph = !params.run_homer_ucsc && params.run_ucsc_bigwig
    def ch_existing_bedgraph = needs_existing_bedgraph
        ? channel
            .fromPath(resolved_bg_glob, checkIfExists: true)
            .map { bg_file ->
                def sample_id = extractSampleId(bg_file, ['.ucsc.bedGraph.gz', '.bedGraph.gz', '.bedGraph'])
                [ buildMeta(sample_id, samplesheet_map), bg_file ]
            }
        : channel.empty()

    //
    // WORKFLOW: Run CUTANDRUN_BASE
    //
    CUTANDRUN_BASE(
        ch_raw_reads,
        ch_existing_trimmed,
        ch_existing_align_sam,
        ch_existing_dedup_bam,
        ch_existing_mapq_sam,
        ch_existing_bedgraph
    )

    onComplete:
    if (workflow.success) {
        log.info "\nUpstream base pipeline completed successfully! Results available in: ${params.outdir}\n"
    } else {
        log.warn "\nUpstream base pipeline completed with errors. Check the logs for details.\n"
    }
}

