process HOMER_FINDMOTIFSGENOME {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    container {
        if (workflow.containerEngine in ['singularity', 'apptainer'] &&
            !task.ext.singularity_pull_docker_container) {

            return 'https://depot.galaxyproject.org/singularity/homer:4.9.1--pl5.22.0_5'
        }

        return task.arch == 'arm64'
            ? 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:bc0d14d491757f78'
            : 'quay.io/biocontainers/homer:4.9.1--pl5.22.0_5'
    }

    input:
    tuple val(meta), path(peaks_bed)
    val genome_name

    output:
    tuple val(meta), path("${prefix}_homer_motifs"), emit: motifs_dir
    tuple val("${task.process}"), val('homer'), val('4.9.1'), emit: versions_homer, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    findMotifsGenome.pl \\
        ${peaks_bed} \\
        ${genome_name} \\
        ${prefix}_homer_motifs/ \\
        ${args} \\
        -p ${task.cpus} \\
        -preparsedDir preparsed_tmp/
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p ${prefix}_homer_motifs/
    touch ${prefix}_homer_motifs/homerResults.html
    touch ${prefix}_homer_motifs/knownResults.html
    """
}
