process BOWTIE2_ALIGN {
    tag "${meta.id}"
    label 'process_high'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/mulled-v2-ac74a7f02cebcfcc07d8e8d1d750af9c83b4d45a:f70b31a2db15c023d641c32f433fb02cd04df5a6-0'
        : 'quay.io/biocontainers/mulled-v2-ac74a7f02cebcfcc07d8e8d1d750af9c83b4d45a:f70b31a2db15c023d641c32f433fb02cd04df5a6-0'}"

    input:
    tuple val(meta), path(reads)
    val(bowtie2_index)

    output:
    tuple val(meta), path("${prefix}_bowtieoutput.sam"), emit: sam
    tuple val(meta), path("${prefix}_bowtie2.log"), emit: log
    tuple val("${task.process}"), val('bowtie2'), eval("bowtie2 --version | head -n 1 | sed 's/.*version //'"), emit: versions_bowtie2, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: '--very-sensitive -N 0 -X 500'
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    bowtie2 -q \\
        ${args} \\
        -p ${task.cpus} \\
        -x "${bowtie2_index}" \\
        -1 "${reads[0]}" \\
        -2 "${reads[1]}" \\
        -S "${prefix}_bowtieoutput.sam" \\
        2> "${prefix}_bowtie2.log"
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch "${prefix}_bowtieoutput.sam"
    touch "${prefix}_bowtie2.log"
    """
}

