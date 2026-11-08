process BEDTOOLS_MERGE_REPLICATES {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/52/52d3fbb86c48b8c39a989733ca97bfd84cf665a9ab279be7cfbbb36f5a53c46a/data'
        : 'community.wave.seqera.io/library/bedtools:2.31.1--897920cd303d6413'}"

    input:
    tuple val(meta), path(beds)
    val min_overlap

    output:
    tuple val(meta), path("${prefix}_replicated_peaks.bed"), emit: bed
    tuple val("${task.process}"), val('bedtools'), eval("bedtools --version | sed -e 's/bedtools v//g'"), emit: versions_bedtools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def bed_list = beds instanceof List ? beds : [beds]
    def effective_min = bed_list.size() < min_overlap ? bed_list.size() : min_overlap
    """
    awk 'BEGIN{OFS="\\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print \$1, \$2, \$3, FILENAME}' ${beds} > combined_unmerged.bed

    if [ -s combined_unmerged.bed ]; then
        bedtools sort -i combined_unmerged.bed | \\
            bedtools merge -i stdin -c 4 -o count_distinct ${args} | \\
            awk -v min_rep=${effective_min} 'BEGIN{OFS="\\t"} \$4 >= min_rep {print \$1, \$2, \$3}' > ${prefix}_replicated_peaks.bed
    else
        touch ${prefix}_replicated_peaks.bed
    fi
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_replicated_peaks.bed
    """
}

