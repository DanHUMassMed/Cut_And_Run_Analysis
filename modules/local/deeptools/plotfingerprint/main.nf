process DEEPTOOLS_PLOTFINGERPRINT {
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
    tuple val(meta), path(bams), path(bais)

    output:
    tuple val(meta), path("${prefix}_fingerprint.pdf"), emit: pdf
    tuple val(meta), path("${prefix}_fingerprint_metrics.tsv"), emit: metrics
    tuple val(meta), path("${prefix}_fingerprint_counts.tsv"), emit: counts
    tuple val("${task.process}"), val('deeptools'), eval('plotFingerprint --version | sed "s/plotFingerprint //g"'), emit: versions_deeptools, topic: versions


    script:
    def args = task.ext.args ?: ''
    def labels_arg = (!args.contains('--labels') && meta.sample_names)
        ? "--labels ${meta.sample_names.join(' ')}"
        : ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    plotFingerprint \\
        -b ${bams} \\
        ${labels_arg} \\
        --extendReads \\
        --skipZeros \\
        --numberOfProcessors ${task.cpus} \\
        --outQualityMetrics ${prefix}_fingerprint_metrics.tsv \\
        --outRawCounts ${prefix}_fingerprint_counts.tsv \\
        --plotFile ${prefix}_fingerprint.pdf \\
        ${args}
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_fingerprint.pdf
    touch ${prefix}_fingerprint_metrics.tsv
    touch ${prefix}_fingerprint_counts.tsv
    """
}
