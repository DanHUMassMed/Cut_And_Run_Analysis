process PLOT_ANNOTATED_SUMMARY {
    tag "${meta.id}"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ba/ba9641d61acf134c6b989b3af5f25bcd5aadb3faf692a41c00ba4cd25f99032e/data'
        : 'community.wave.seqera.io/library/deeptools:3.5.6--511a2b05870b9ec3'}"

    input:
    tuple val(meta), path(annotated_peaks_txt)
    path samplesheet

    output:
    tuple val(meta), path("${prefix}_genomic_features.svg"),               emit: features_svg
    tuple val(meta), path("${prefix}_genomic_features.png"),               emit: features_png
    tuple val(meta), path("${prefix}_genomic_features.tsv"),               emit: features_tsv
    tuple val(meta), path("${prefix}_correlation_pca.svg"),                emit: corr_pca_svg
    tuple val(meta), path("${prefix}_correlation_pca.png"),                emit: corr_pca_png
    tuple val(meta), path("${prefix}_correlation_matrix.tsv"),             emit: corr_tsv
    tuple val(meta), path("${prefix}_signal_and_width_distributions.svg"), emit: signal_svg
    tuple val(meta), path("${prefix}_signal_and_width_distributions.png"), emit: signal_png
    tuple val(meta), path("${prefix}_signal_summary_stats.tsv"),           emit: signal_tsv
    tuple val("${task.process}"), val('matplotlib'), eval('python3 -c "import matplotlib; print(matplotlib.__version__)"'), emit: versions_matplotlib, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.target ?: meta.id}"
    """
    plot_annotated_features_qc.py \\
        --annotated-peaks ${annotated_peaks_txt} \\
        --samplesheet ${samplesheet} \\
        --target ${prefix} \\
        --outdir . \\
        ${args}
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.target ?: meta.id}"
    """
    touch ${prefix}_genomic_features.svg
    touch ${prefix}_genomic_features.png
    touch ${prefix}_genomic_features.tsv
    touch ${prefix}_correlation_pca.svg
    touch ${prefix}_correlation_pca.png
    touch ${prefix}_correlation_matrix.tsv
    touch ${prefix}_signal_and_width_distributions.svg
    touch ${prefix}_signal_and_width_distributions.png
    touch ${prefix}_signal_summary_stats.tsv
    """
}

