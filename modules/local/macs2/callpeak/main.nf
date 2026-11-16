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
    tuple val(meta), path(bam), path(bai)

    output:
    tuple val(meta), path("*.{narrowPeak,broadPeak}"), emit: peak
    tuple val(meta), path("*.xls"), emit: xls
    tuple val(meta), path("*_summits.bed"), emit: summits, optional: true
    tuple val(meta), path("*.gappedPeak"), emit: gapped, optional: true
    tuple val("${task.process}"), val('macs2'), eval("macs2 --version | sed 's/macs2 //'"), emit: versions_macs2, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    macs2 callpeak \\
        -t ${bam} \\
        -n ${prefix} \\
        ${args}
    """

    stub:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def is_broad = args.contains('--broad')
    def peak_ext = is_broad ? 'broadPeak' : 'narrowPeak'
    def extra_file = is_broad ? "${prefix}_peaks.gappedPeak" : "${prefix}_summits.bed"
    """
    touch ${prefix}_peaks.${peak_ext}
    touch ${prefix}_peaks.xls
    touch ${extra_file}
    """
}

