process PLOT_PEAK_COUNTS {
    tag "peak_counts_summary"
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
    path samplesheet
    path peak_files

    output:
    path "peak_counts_summary.svg", emit: svg
    path "peak_counts_summary.png", emit: png
    path "peak_counts_summary.tsv", emit: tsv
    tuple val("${task.process}"), val('matplotlib'), eval('python3 -c "import matplotlib; print(matplotlib.__version__)"'), emit: versions_matplotlib, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    """
    plot_peak_counts.py \\
        --samplesheet ${samplesheet} \\
        --peak-files ${peak_files} \\
        --out-prefix peak_counts_summary \\
        ${args}
    """

    stub:
    """
    touch peak_counts_summary.svg
    touch peak_counts_summary.png
    touch peak_counts_summary.tsv
    """
}

