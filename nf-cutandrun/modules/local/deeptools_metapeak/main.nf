process DEEPTOOLS_METAPEAK {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/ba/ba9641d61acf134c6b989b3af5f25bcd5aadb3faf692a41c00ba4cd25f99032e/data'
        : 'community.wave.seqera.io/library/deeptools:3.5.6--511a2b05870b9ec3'}"

    input:
    tuple val(meta), path(peaks_bed), path(bigwigs)

    output:
    tuple val(meta), path("${prefix}_matrix.mat.gz"), emit: matrix
    tuple val(meta), path("${prefix}_metapeak_heatmap.pdf"), emit: pdf
    tuple val("${task.process}"), val('deeptools'), eval('computeMatrix --version | sed "s/computeMatrix //g"'), emit: versions_deeptools, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def raw_args2 = task.ext.args2 ?: ''
    def samples_label = (!raw_args2.contains('--samplesLabel') && meta.sample_names)
        ? "--samplesLabel ${meta.sample_names.join(' ')}"
        : (!raw_args2.contains('--samplesLabel') && meta.sample_name ? "--samplesLabel ${meta.sample_name}" : '')
    def args2 = [raw_args2, samples_label].findAll { it }.join(' ')
    prefix = task.ext.prefix ?: "${meta.sample_name ?: meta.id}"
    """
    computeMatrix reference-point \\
        -S ${bigwigs} \\
        -R ${peaks_bed} \\
        ${args} \\
        -p ${task.cpus} \\
        -o ${prefix}_matrix.mat.gz

    plotHeatmap \\
        -m ${prefix}_matrix.mat.gz \\
        ${args2} \\
        -o ${prefix}_metapeak_heatmap.pdf
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.sample_name ?: meta.id}"
    """
    echo "" | gzip -c > ${prefix}_matrix.mat.gz
    touch ${prefix}_metapeak_heatmap.pdf
    """
}

