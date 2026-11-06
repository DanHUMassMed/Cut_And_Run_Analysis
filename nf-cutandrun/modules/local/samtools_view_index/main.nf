process SAMTOOLS_VIEW_INDEX {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/87/87660348a4d032cc08d6ac8101ff9d4d27164300d39c9472043bb5001f9ba801/data'
        : 'community.wave.seqera.io/library/htslib_samtools:1.25--704fb80d75745bd4'}"

    input:
    tuple val(meta), path(sam)

    output:
    tuple val(meta), path("${prefix}.bam"), path("${prefix}.bam.bai"), emit: bam_bai
    tuple val("${task.process}"), val('samtools'), eval('samtools version | sed "1!d;s/.* //"'), emit: versions_samtools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    samtools view -@ ${task.cpus} -bh ${args} ${sam} > ${prefix}.bam
    samtools index -@ ${task.cpus} ${prefix}.bam
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.bam
    touch ${prefix}.bam.bai
    """
}

