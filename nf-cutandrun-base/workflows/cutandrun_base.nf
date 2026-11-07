/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { FASTQC as FASTQC_RAW                  } from '../modules/nf-core/fastqc/main'
include { MULTIQC as MULTIQC_RAW                } from '../modules/nf-core/multiqc/main'
include { TRIMMOMATIC                           } from '../modules/nf-core/trimmomatic/main'
include { FASTQC as FASTQC_TRIMMED              } from '../modules/nf-core/fastqc/main'
include { MULTIQC as MULTIQC_TRIMMED            } from '../modules/nf-core/multiqc/main'
include { BOWTIE2_ALIGN                         } from '../modules/nf-core/bowtie2/align/main'
include { PICARD_SORTSAM                        } from '../modules/nf-core/picard/sortsam/main'
include { PICARD_MARKDUPLICATES                 } from '../modules/nf-core/picard/markduplicates/main'
include { SAMTOOLS_VIEW as SAMTOOLS_MAPQ_FILTER } from '../modules/nf-core/samtools/view/main'
include { SAMTOOLS_VIEW as SAMTOOLS_VIEW_BAM    } from '../modules/nf-core/samtools/view/main'
include { SAMTOOLS_INDEX                        } from '../modules/nf-core/samtools/index/main'
include { DEEPTOOLS_BAMCOVERAGE                 } from '../modules/nf-core/deeptools/bamcoverage/main'
include { HOMER_MAKETAGDIRECTORY                } from '../modules/nf-core/homer/maketagdirectory/main'
include { HOMER_MAKEUCSCFILE                    } from '../modules/nf-core/homer/makeucscfile/main'
include { UCSC_BEDGRAPHTOBIGWIG                 } from '../modules/nf-core/ucsc/bedgraphtobigwig/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow CUTANDRUN_BASE {

    take:
    ch_raw_reads             // channel: [ val(meta), [ path(r1), path(r2) ] ]
    ch_existing_trimmed      // channel: [ val(meta), [ path(r1), path(r2) ] ]
    ch_existing_align_sam    // channel: [ val(meta), path(sam) ]
    ch_existing_dedup_bam    // channel: [ val(meta), path(bam) ]
    ch_existing_mapq_sam     // channel: [ val(meta), path(sam) ]
    ch_existing_bedgraph     // channel: [ val(meta), path(bedgraph) ]
    ch_bowtie2_index         // value:   [ val(meta2), path(index_dir) ]
    ch_chrom_sizes           // value:   path(chrom_sizes)

    main:

    //
    // Step 00: Raw Read QC (FastQC + MultiQC on raw input FASTQ pairs)
    //
    def ch_raw_fastqc_html = channel.empty()
    def ch_raw_fastqc_zip  = channel.empty()
    def ch_raw_multiqc     = channel.empty()

    if (params.run_raw_fastqc) {
        FASTQC_RAW(ch_raw_reads)
        ch_raw_fastqc_html = FASTQC_RAW.out.html
        ch_raw_fastqc_zip  = FASTQC_RAW.out.zip

        def ch_raw_multiqc_in = ch_raw_fastqc_zip
            .map { _meta, zips -> zips }
            .flatten()
            .collect()
            .map { files -> [ [ id: 'multiqc_original_report' ], files, [], [], [], [] ] }

        MULTIQC_RAW(ch_raw_multiqc_in)
        ch_raw_multiqc = MULTIQC_RAW.out.report
    }

    //
    // Step 01: Adapter Trimming with Trimmomatic PE
    //
    def ch_trimmed_reads   = ch_existing_trimmed
    def ch_trimmomatic_log = channel.empty()

    if (params.run_trimmomatic) {
        TRIMMOMATIC(ch_raw_reads)
        ch_trimmed_reads   = TRIMMOMATIC.out.trimmed_reads
        ch_trimmomatic_log = TRIMMOMATIC.out.out_log
    }

    //
    // Step 02: Trimmed Read QC (FastQC + MultiQC on trimmed paired FASTQ outputs)
    //
    def ch_trimmed_fastqc_html = channel.empty()
    def ch_trimmed_fastqc_zip  = channel.empty()
    def ch_trimmed_multiqc     = channel.empty()

    if (params.run_trimmed_fastqc) {
        FASTQC_TRIMMED(ch_trimmed_reads)
        ch_trimmed_fastqc_html = FASTQC_TRIMMED.out.html
        ch_trimmed_fastqc_zip  = FASTQC_TRIMMED.out.zip

        def ch_trimmed_multiqc_in = ch_trimmed_fastqc_zip
            .map { _meta, zips -> zips }
            .flatten()
            .collect()
            .map { files -> [ [ id: 'multiqc_trimmed_report' ], files, [], [], [], [] ] }

        MULTIQC_TRIMMED(ch_trimmed_multiqc_in)
        ch_trimmed_multiqc = MULTIQC_TRIMMED.out.report
    }

    //
    // Step 03: Paired-End Genome Alignment with Bowtie2 (on trimmed paired reads)
    //
    def ch_align_sam   = ch_existing_align_sam
    def ch_bowtie2_log = channel.empty()

    if (params.run_bowtie2_align) {
        BOWTIE2_ALIGN(
            ch_trimmed_reads,
            ch_bowtie2_index,
            [ [ id: 'none' ], [] ],
            false,
            false
        )
        ch_align_sam   = BOWTIE2_ALIGN.out.sam
        ch_bowtie2_log = BOWTIE2_ALIGN.out.log
    }

    //
    // Step 04: Coordinate Sorting & Duplicate Removal with Picard
    //
    def ch_dedup_bam     = ch_existing_dedup_bam
    def ch_dedup_metrics = channel.empty()

    if (params.run_picard_dedup) {
        PICARD_SORTSAM(
            ch_align_sam,
            'coordinate'
        )
        PICARD_MARKDUPLICATES(
            PICARD_SORTSAM.out.bam,
            [ [ id: 'none' ], [], [] ]
        )
        ch_dedup_bam     = PICARD_MARKDUPLICATES.out.bam
        ch_dedup_metrics = PICARD_MARKDUPLICATES.out.metrics
    }

    //
    // Step 05: Low-Quality Read Filtering (MAPQ >= params.mapq_threshold) with samtools
    //
    def ch_mapq_sam = ch_existing_mapq_sam

    if (params.run_mapq_filter) {
        SAMTOOLS_MAPQ_FILTER(
            ch_dedup_bam.map { meta, bam -> [ meta, bam, [] ] },
            [ [ id: 'none' ], [], [] ],
            [ [ id: 'none' ], [] ],
            [ [ id: 'none' ], [] ],
            ''
        )
        ch_mapq_sam = SAMTOOLS_MAPQ_FILTER.out.sam
    }

    //
    // Step 06: SAM-to-BAM Conversion, Indexing, & deepTools RPKM BigWig
    //
    def ch_bam_bai = channel.empty()
    def ch_rpkm_bw = channel.empty()

    if (params.run_index_bam) {
        SAMTOOLS_VIEW_BAM(
            ch_mapq_sam.map { meta, sam -> [ meta, sam, [] ] },
            [ [ id: 'none' ], [], [] ],
            [ [ id: 'none' ], [] ],
            [ [ id: 'none' ], [] ],
            ''
        )
        SAMTOOLS_INDEX(SAMTOOLS_VIEW_BAM.out.bam)
        ch_bam_bai = SAMTOOLS_VIEW_BAM.out.bam.join(SAMTOOLS_INDEX.out.index)

        DEEPTOOLS_BAMCOVERAGE(
            ch_bam_bai,
            [],
            [],
            [ [ id: 'none' ], [] ]
        )
        ch_rpkm_bw = DEEPTOOLS_BAMCOVERAGE.out.bigwig
    }

    //
    // Step 07: HOMER Tag Directory & UCSC bedGraph Track
    //
    def ch_tagdir   = channel.empty()
    def ch_bedgraph = ch_existing_bedgraph

    if (params.run_homer_ucsc) {
        HOMER_MAKETAGDIRECTORY(
            ch_mapq_sam,
            []
        )
        ch_tagdir = HOMER_MAKETAGDIRECTORY.out.tagdir

        HOMER_MAKEUCSCFILE(ch_tagdir)
        ch_bedgraph = HOMER_MAKEUCSCFILE.out.bedGraph
    }

    //
    // Step 08: UCSC bedGraphToBigWig Conversion
    //
    def ch_ucsc_bw = channel.empty()

    if (params.run_ucsc_bigwig) {
        UCSC_BEDGRAPHTOBIGWIG(
            ch_bedgraph,
            ch_chrom_sizes
        )
        ch_ucsc_bw = UCSC_BEDGRAPHTOBIGWIG.out.bigwig
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
    raw_fastqc_html     = ch_raw_fastqc_html
    raw_multiqc         = ch_raw_multiqc
    trimmed_reads       = ch_trimmed_reads
    trimmomatic_log     = ch_trimmomatic_log
    trimmed_fastqc_html = ch_trimmed_fastqc_html
    trimmed_multiqc     = ch_trimmed_multiqc
    align_sam           = ch_align_sam
    bowtie2_log         = ch_bowtie2_log
    dedup_bam           = ch_dedup_bam
    dedup_metrics       = ch_dedup_metrics
    mapq_sam            = ch_mapq_sam
    bam_bai             = ch_bam_bai
    rpkm_bw             = ch_rpkm_bw
    tagdir              = ch_tagdir
    bedgraph            = ch_bedgraph
    ucsc_bw             = ch_ucsc_bw
    versions            = ch_collated_versions
}
