process PLOT_FRIP_AND_DEPTH {
    tag "frip_and_depth_qc"
    label 'process_low'

    conda "${moduleDir}/environment.yml"

    container {
        if (workflow.containerEngine in ['singularity', 'apptainer'] &&
            !task.ext.singularity_pull_docker_container) {

            return 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ba/ba9641d61acf134c6b989b3af5f25bcd5aadb3faf692a41c00ba4cd25f99032e/data'
        }

        return task.arch == 'arm64'
            ? 'community.wave.seqera.io/library/deeptools:3.5.6--8f196e4fd4d940f7'
            : 'community.wave.seqera.io/library/deeptools:3.5.6--511a2b05870b9ec3'
    }

    input:
    path samplesheet
    path bams
    path bais
    path sample_peaks
    path master_peaks
    path tagdirs
    path trimmomatic_logs
    path bowtie2_logs
    path picard_dups
    path bam_stats
    path chrom_sizes

    output:
    path "frip_summary.tsv", emit: frip_tsv
    path "read_retention_depth_summary.tsv", emit: depth_tsv
    path "frip_comparison.svg", emit: frip_svg
    path "frip_comparison.png", emit: frip_png
    path "read_retention_funnel.svg", emit: depth_svg
    path "read_retention_funnel.png", emit: depth_png
    tuple val("${task.process}"), val('pysam'), eval('python3 -c "import pysam; print(pysam.__version__)"'), emit: versions_pysam, topic: versions


    script:
    def bams_arg        = bams             ? "--bams ${bams}"                         : ''
    def sample_pk_arg   = sample_peaks     ? "--sample-peaks ${sample_peaks}"         : ''
    def master_pk_arg   = master_peaks     ? "--master-peaks ${master_peaks}"         : ''
    def tagdirs_arg     = tagdirs          ? "--tagdirs ${tagdirs}"                   : ''
    def trim_arg        = trimmomatic_logs ? "--trimmomatic-logs ${trimmomatic_logs}" : ''
    def bt2_arg         = bowtie2_logs     ? "--bowtie2-logs ${bowtie2_logs}"         : ''
    def dup_arg         = picard_dups      ? "--picard-dups ${picard_dups}"           : ''
    def stats_arg       = bam_stats        ? "--bam-stats ${bam_stats}"               : ''
    def chrom_arg       = chrom_sizes      ? "--chrom-sizes ${chrom_sizes}"           : ''
    """
    plot_frip_and_depth.py \\
        --samplesheet ${samplesheet} \\
        ${bams_arg} \\
        ${sample_pk_arg} \\
        ${master_pk_arg} \\
        ${tagdirs_arg} \\
        ${trim_arg} \\
        ${bt2_arg} \\
        ${dup_arg} \\
        ${stats_arg} \\
        ${chrom_arg} \\
        --outdir .
    """

    stub:
    """
    touch frip_summary.tsv
    touch read_retention_depth_summary.tsv
    touch frip_comparison.svg
    touch frip_comparison.png
    touch read_retention_funnel.svg
    touch read_retention_funnel.png
    """
}
