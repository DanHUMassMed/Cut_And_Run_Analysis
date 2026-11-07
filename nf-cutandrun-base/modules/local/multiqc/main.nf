process MULTIQC {
    tag "${report_name}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/multiqc:1.25.1--pyhdfd78af_0'
        : 'quay.io/biocontainers/multiqc:1.25.1--pyhdfd78af_0'}"

    input:
    path(qc_files)
    val(report_name)

    output:
    path("${report_name}.html"), emit: report
    path("${report_name}_data"), emit: data
    tuple val("${task.process}"), val('multiqc'), eval("multiqc --version | sed 's/.*version //'"), emit: versions_multiqc, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    """
    multiqc \\
        ${args} \\
        -f \\
        -n "${report_name}.html" \\
        .
    """

    stub:
    """
    touch "${report_name}.html"
    mkdir -p "${report_name}_data"
    touch "${report_name}_data/multiqc_general_stats.txt"
    """
}

