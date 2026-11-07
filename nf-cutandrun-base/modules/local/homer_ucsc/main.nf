process HOMER_UCSC {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/0f/0fe4a3875b78dce3c66b43fb96489769cc32e55e329e2525d2af09096af2252a/data'
        : 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:a8f4c58755bb281b'}"

    input:
    tuple val(meta), path(mapq_sam)

    output:
    tuple val(meta), path("${prefix}"), emit: tagdir
    tuple val(meta), path("${prefix}/${prefix}.ucsc.bedGraph.gz"), emit: bedgraph
    tuple val("${task.process}"), val('homer'), val('4.11'), emit: versions_homer, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args  = task.ext.args  ?: ''
    def args2 = task.ext.args2 ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p "${prefix}"
    makeTagDirectory "${prefix}" "${mapq_sam}" ${args}
    makeUCSCfile "${prefix}" -o auto ${args2}
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p "${prefix}"
    touch "${prefix}/tagInfo.txt"
    echo "" | gzip -c > "${prefix}/${prefix}.ucsc.bedGraph.gz"
    """
}

