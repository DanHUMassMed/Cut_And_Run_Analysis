process DEEPTOOLS_BIGWIG_QC {
    tag "${meta.id}"
    label 'process_medium'

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
    tuple val(meta), path(bigwigs)

    output:
    tuple val(meta), path("${prefix}_bw_summary.npz"), emit: npz
    tuple val(meta), path("${prefix}_bw_raw_counts.tsv"), emit: raw_counts
    tuple val(meta), path("${prefix}_correlation_heatmap.pdf"), emit: corr_pdf, optional: true
    tuple val(meta), path("${prefix}_correlation_matrix.tsv"), emit: corr_matrix, optional: true
    tuple val(meta), path("${prefix}_pca.pdf"), emit: pca_pdf, optional: true
    tuple val(meta), path("${prefix}_pca_data.tsv"), emit: pca_data, optional: true
    tuple val("${task.process}"), val('deeptools'), eval('multiBigwigSummary --version | sed "s/multiBigwigSummary //g"'), emit: versions_deeptools, topic: versions


    script:
    def args  = task.ext.args  ?: ''
    def args2 = task.ext.args2 ?: ''
    def args3 = task.ext.args3 ?: ''
    def labels_arg = (!args.contains('--labels') && meta.sample_names)
        ? "--labels ${meta.sample_names.join(' ')}"
        : ''
    def n_samples = bigwigs instanceof List ? bigwigs.size() : 1
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    multiBigwigSummary bins \\
        -b ${bigwigs} \\
        ${labels_arg} \\
        -p ${task.cpus} \\
        -o ${prefix}_bw_summary.npz \\
        --outRawCounts ${prefix}_bw_raw_counts.tsv \\
        ${args}

    if [ ${n_samples} -ge 2 ]; then
        plotCorrelation \\
            -in ${prefix}_bw_summary.npz \\
            --skipZeros \\
            --removeOutliers \\
            --whatToPlot heatmap \\
            --colorMap RdYlBu_r \\
            --plotNumbers \\
            -o ${prefix}_correlation_heatmap.pdf \\
            --outFileCorMatrix ${prefix}_correlation_matrix.tsv \\
            ${args2}
    fi

    if [ ${n_samples} -ge 3 ]; then
        plotPCA \\
            -in ${prefix}_bw_summary.npz \\
            -o ${prefix}_pca.pdf \\
            --outFileNameData ${prefix}_pca_data.tsv \\
            ${args3}
    fi
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_bw_summary.npz
    touch ${prefix}_bw_raw_counts.tsv
    touch ${prefix}_correlation_heatmap.pdf
    touch ${prefix}_correlation_matrix.tsv
    touch ${prefix}_pca.pdf
    touch ${prefix}_pca_data.tsv
    """
}
