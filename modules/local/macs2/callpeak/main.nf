process MACS2_CALLPEAK {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"

    container {
        if (workflow.containerEngine in ['singularity', 'apptainer'] &&
            !task.ext.singularity_pull_docker_container) {

            return 'https://depot.galaxyproject.org/singularity/macs2:2.2.9.1--py39hff71179_1'
        }

        return task.arch == 'arm64'
            ? 'community.wave.seqera.io/library/macs2_python_setuptools:0c1a054d6205dcdc'
            : 'quay.io/biocontainers/macs2:2.2.9.1--py39hff71179_1'
    }

    input:
    tuple val(meta), path(bam), path(bai), path(control_bam), path(control_bai)

    output:
    tuple val(meta), path("*.{narrowPeak,broadPeak}"), emit: peak
    tuple val(meta), path("${prefix}_macs2_merge_ready_peaks.bed"), emit: merge_ready_bed
    tuple val(meta), path("*.xls"), emit: xls
    tuple val(meta), path("*_summits.bed"), emit: summits, optional: true
    tuple val(meta), path("*.gappedPeak"), emit: gapped, optional: true
    tuple val("${task.process}"), val('macs2'), eval("macs2 --version | sed 's/macs2 //'"), emit: versions_macs2, topic: versions

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def peak_ext = args.contains('--broad') ? 'broadPeak' : 'narrowPeak'
    def control_arg = control_bam ? "-c ${control_bam}" : ''
    """
    macs2 callpeak \\
        -t ${bam} \\
        ${control_arg} \\
        -n ${prefix} \\
        ${args}

    awk 'BEGIN{OFS="\\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print \$1, \$2, \$3}' ${prefix}_peaks.${peak_ext} | \\
        LC_ALL=C sort -k1,1 -k2,2n > ${prefix}_macs2_merge_ready_peaks.bed
    """

    stub:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def is_broad = args.contains('--broad')
    def peak_ext = is_broad ? 'broadPeak' : 'narrowPeak'
    def extra_file = is_broad ? "${prefix}_peaks.gappedPeak" : "${prefix}_summits.bed"
    """
    touch ${prefix}_peaks.${peak_ext}
    touch ${prefix}_macs2_merge_ready_peaks.bed
    touch ${prefix}_peaks.xls
    touch ${extra_file}
    """
}

