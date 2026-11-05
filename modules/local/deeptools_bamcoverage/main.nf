process DEEPTOOLS_BAMCOVERAGE {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/aa/aa2a707745965f561e777fdce54f18881d0e53a12c1b3a29ba1b2a6f2112f099/data'
        : 'community.wave.seqera.io/library/deeptools_samtools:22ef5f45259c4336'}"

    input:
    tuple val(meta), path(bam), path(bai)

    output:
    tuple val(meta), path("${prefix}.bw"), emit: bigwig
    tuple val("${task.process}"), val('deeptools'), eval('bamCoverage --version | sed "s/bamCoverage //g"'), emit: versions_deeptools, topic: versions
    tuple val("${task.process}"), val('samtools'), eval("samtools version | sed '1!d;s/.* //'"), emit: versions_samtools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    bamCoverage \\
        -b ${bam} \\
        ${args} \\
        -p ${task.cpus} \\
        -o ${prefix}.bw
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bw
    """
}

