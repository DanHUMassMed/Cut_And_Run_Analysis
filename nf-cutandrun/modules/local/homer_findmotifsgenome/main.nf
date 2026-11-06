process HOMER_FINDMOTIFSGENOME {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/0f/0fe4a3875b78dce3c66b43fb96489769cc32e55e329e2525d2af09096af2252a/data'
        : 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:a8f4c58755bb281b'}"

    input:
    tuple val(meta), path(peaks_bed)
    val genome_name

    output:
    tuple val(meta), path("${prefix}_homer_motifs"), emit: motifs_dir
    tuple val("${task.process}"), val('homer'), val('4.11'), emit: versions_homer, topic: versions

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
