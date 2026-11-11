process PLOT_DIFFERENTIAL_VOLCANO_MA {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"

    container {
        if (workflow.containerEngine in ['singularity', 'apptainer'] &&
            !task.ext.singularity_pull_docker_container) {

            return 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ba/ba9641d61acf134c6b989b3af5f25bcd5aadb3faf692a41c00ba4cd25f99032e/data'
        }

        return task.arch == 'arm64'
            ? 'community.wave.seqera.io/library/deeptools:3.5.6--8f196e4fd4d940f7'
            : 'community.wave.seqera.io/library/deeptools:3.5.6--511a2b05870b9ec3'
    }

    input:
    tuple val(meta), path(diff_peaks_txt)

    output:
    tuple val(meta), path("${prefix}_volcano_ma.svg"),             emit: svg
    tuple val(meta), path("${prefix}_volcano_ma.png"),             emit: png
    tuple val(meta), path("${prefix}_top_differential_genes.tsv"), emit: tsv
    tuple val("${task.process}"), val('matplotlib'), eval('python3 -c "import matplotlib; print(matplotlib.__version__)"'), emit: versions_matplotlib, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def treatment  = meta.treatment  ?: 'Treatment'
    def background = meta.background ?: 'Background'
    def target     = meta.target     ?: ''
    """
    plot_differential_volcano_ma.py \\
        --diff-file ${diff_peaks_txt} \\
        --contrast-id ${prefix} \\
        --treatment ${treatment} \\
        --background ${background} \\
        --target "${target}" \\
        --out-prefix ${prefix}_volcano_ma \\
        ${args}
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_volcano_ma.svg
    touch ${prefix}_volcano_ma.png
    touch ${prefix}_top_differential_genes.tsv
    """
}

