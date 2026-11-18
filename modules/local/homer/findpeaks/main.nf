process HOMER_FINDPEAKS {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    container {
        if (workflow.containerEngine in ['singularity', 'apptainer'] &&
            !task.ext.singularity_pull_docker_container) {

            return 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/0f/0fe4a3875b78dce3c66b43fb96489769cc32e55e329e2525d2af09096af2252a/data'
        }

        return task.arch == 'arm64'
            ? 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:bc0d14d491757f78'
            : 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:a8f4c58755bb281b'
    }

    input:
    tuple val(meta), path(tagdir), path(control_tagdir)

    output:
    tuple val(meta), path("${prefix}_peaks.txt"), emit: txt
    tuple val(meta), path("${prefix}_peaks.bed"), emit: bed
    tuple val(meta), path("${prefix}_homer_merge_ready_peaks.bed"), emit: merge_ready_bed
    tuple val("${task.process}"), val('homer'), val('4.11'), emit: versions_homer, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def control_arg = control_tagdir ? "-i ${control_tagdir}" : ''
    """
    findPeaks \\
        ${tagdir} \\
        ${control_arg} \\
        ${args} \\
        -o ${prefix}_peaks.txt

    pos2bed.pl ${prefix}_peaks.txt > ${prefix}_peaks.bed

    awk 'BEGIN{OFS="\\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print \$1, \$2, \$3}' ${prefix}_peaks.bed | \\
        LC_ALL=C sort -k1,1 -k2,2n > ${prefix}_homer_merge_ready_peaks.bed
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_peaks.txt
    touch ${prefix}_peaks.bed
    touch ${prefix}_homer_merge_ready_peaks.bed
    """
}

