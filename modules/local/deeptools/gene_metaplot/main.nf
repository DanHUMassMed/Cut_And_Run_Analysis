process DEEPTOOLS_GENE_METAPLOT {
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
    tuple val(meta), path(gene_bed), path(bigwigs)

    output:
    tuple val(meta), path("${prefix}_tss_matrix.mat.gz"), emit: tss_matrix
    tuple val(meta), path("${prefix}_tss_profile.pdf"), emit: tss_profile
    tuple val(meta), path("${prefix}_tss_heatmap.pdf"), emit: tss_heatmap
    tuple val(meta), path("${prefix}_genebody_matrix.mat.gz"), emit: genebody_matrix
    tuple val(meta), path("${prefix}_genebody_profile.pdf"), emit: genebody_profile
    tuple val(meta), path("${prefix}_genebody_heatmap.pdf"), emit: genebody_heatmap
    tuple val("${task.process}"), val('deeptools'), eval('computeMatrix --version | sed "s/computeMatrix //g"'), emit: versions_deeptools, topic: versions


    script:
    def tss_args      = task.ext.args  ?: ''
    def genebody_args = task.ext.args2 ?: ''
    def heatmap_args  = task.ext.args3 ?: ''
    def samples_label = meta.sample_names
        ? "--samplesLabel ${meta.sample_names.join(' ')}"
        : (meta.sample_name ? "--samplesLabel ${meta.sample_name}" : '')
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    computeMatrix reference-point \\
        --referencePoint TSS \\
        -R ${gene_bed} \\
        -S ${bigwigs} \\
        --missingDataAsZero \\
        --skipZeros \\
        ${tss_args} \\
        -p ${task.cpus} \\
        -o ${prefix}_tss_matrix.mat.gz

    plotProfile \\
        -m ${prefix}_tss_matrix.mat.gz \\
        --perGroup \\
        ${samples_label} \\
        --refPointLabel TSS \\
        -o ${prefix}_tss_profile.pdf

    plotHeatmap \\
        -m ${prefix}_tss_matrix.mat.gz \\
        ${samples_label} \\
        --refPointLabel TSS \\
        ${heatmap_args} \\
        -o ${prefix}_tss_heatmap.pdf

    computeMatrix scale-regions \\
        -R ${gene_bed} \\
        -S ${bigwigs} \\
        --missingDataAsZero \\
        --skipZeros \\
        ${genebody_args} \\
        -p ${task.cpus} \\
        -o ${prefix}_genebody_matrix.mat.gz

    plotProfile \\
        -m ${prefix}_genebody_matrix.mat.gz \\
        --perGroup \\
        ${samples_label} \\
        --startLabel TSS \\
        --endLabel TES \\
        -o ${prefix}_genebody_profile.pdf

    plotHeatmap \\
        -m ${prefix}_genebody_matrix.mat.gz \\
        ${samples_label} \\
        --startLabel TSS \\
        --endLabel TES \\
        ${heatmap_args} \\
        -o ${prefix}_genebody_heatmap.pdf
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "" | gzip -c > ${prefix}_tss_matrix.mat.gz
    touch ${prefix}_tss_profile.pdf
    touch ${prefix}_tss_heatmap.pdf
    echo "" | gzip -c > ${prefix}_genebody_matrix.mat.gz
    touch ${prefix}_genebody_profile.pdf
    touch ${prefix}_genebody_heatmap.pdf
    """
}
