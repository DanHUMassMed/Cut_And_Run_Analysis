process SAMTOOLS_BAM_BIGWIG {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/aa/aa2a707745965f561e777fdce54f18881d0e53a12c1b3a29ba1b2a6f2112f099/data'
        : 'community.wave.seqera.io/library/deeptools_samtools:22ef5f45259c4336'}"

    input:
    tuple val(meta), path(mapq_sam)

    output:
    tuple val(meta), path("${prefix}.bam"), path("${prefix}.bam.bai"), emit: bam_bai
    tuple val(meta), path("${prefix}.bw"), emit: bigwig
    tuple val("${task.process}"), val('samtools'), eval("samtools version | sed '1!d;s/.* //'"), emit: versions_samtools, topic: versions
    tuple val("${task.process}"), val('deeptools'), eval('bamCoverage --version | sed "s/bamCoverage //g"'), emit: versions_deeptools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: '--normalizeUsing RPKM'
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    samtools view -@ ${task.cpus} -bh "${mapq_sam}" > "${prefix}.bam"
    samtools index -@ ${task.cpus} "${prefix}.bam"
    bamCoverage -b "${prefix}.bam" -p ${task.cpus} ${args} -o "${prefix}.bw"
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch "${prefix}.bam"
    touch "${prefix}.bam.bai"
    touch "${prefix}.bw"
    """
}

