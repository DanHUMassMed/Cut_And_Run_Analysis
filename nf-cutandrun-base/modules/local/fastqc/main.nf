process FASTQC {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/fastqc:0.11.9--0'
        : 'quay.io/biocontainers/fastqc:0.11.9--0'}"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("*_fastqc.html"), emit: html
    tuple val(meta), path("*_fastqc.zip"), emit: zip
    tuple val("${task.process}"), val('fastqc'), eval("fastqc --version | sed 's/FastQC v//'"), emit: versions_fastqc, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    """
    fastqc \\
        ${args} \\
        -t ${task.cpus} \\
        -o . \\
        ${reads}
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_1_fastqc.html
    touch ${prefix}_1_fastqc.zip
    touch ${prefix}_2_fastqc.html
    touch ${prefix}_2_fastqc.zip
    """
}

