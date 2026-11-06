process BEDTOOLS_MERGE_MASTER {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/52/52d3fbb86c48b8c39a989733ca97bfd84cf665a9ab279be7cfbbb36f5a53c46a/data'
        : 'community.wave.seqera.io/library/bedtools:2.31.1--897920cd303d6413'}"

    input:
    tuple val(meta), path(beds)

    output:
    tuple val(meta), path("${prefix}_master_peaks.bed"), emit: bed
    tuple val("${task.process}"), val('bedtools'), eval("bedtools --version | sed -e 's/bedtools v//g'"), emit: versions_bedtools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    awk 'BEGIN{OFS="\\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print \$1, \$2, \$3}' ${beds} > combined_conditions.bed

    if [ -s combined_conditions.bed ]; then
        bedtools sort -i combined_conditions.bed | \\
            bedtools merge -i stdin ${args} > ${prefix}_master_peaks.bed
    else
        touch ${prefix}_master_peaks.bed
    fi
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_master_peaks.bed
    """
}
