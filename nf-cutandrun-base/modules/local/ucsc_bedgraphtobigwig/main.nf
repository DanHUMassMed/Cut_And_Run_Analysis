process UCSC_BEDGRAPHTOBIGWIG {
    tag "${meta.id}"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/ucsc-bedgraphtobigwig:469--h9b8f530_0'
        : 'quay.io/biocontainers/ucsc-bedgraphtobigwig:469--h9b8f530_0'}"

    input:
    tuple val(meta), path(bedgraph)
    val(chrom_sizes)

    output:
    tuple val(meta), path("${prefix}.bw"), emit: bigwig
    tuple val("${task.process}"), val('ucsc_bedgraphtobigwig'), val('20240312'), emit: versions_ucsc, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    if [[ "${bedgraph}" =~ \\.gz\$ ]]; then
        gzip -dc "${bedgraph}"
    else
        cat "${bedgraph}"
    fi | grep -v '^#' | grep -v '^track' | LC_COLLATE=C sort -k1,1 -k2,2n > "${prefix}.temp.bedGraph"

    bedGraphToBigWig "${prefix}.temp.bedGraph" "${chrom_sizes}" "${prefix}.bw"
    rm -f "${prefix}.temp.bedGraph"
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch "${prefix}.bw"
    """
}

