process UTIL_PREPARE_GENE_BED {
    tag "${genome_name}"
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
    val genome_name
    path homer_rna
    path chrom_sizes

    output:
    path "${genome_name}_genes.bed", emit: bed
    tuple val("${task.process}"), val('python'), eval('python3 --version | sed "s/Python //g"'), emit: versions_python, topic: versions


    script:
    def args = task.ext.args ?: ''
    """
    homer_rna_to_gene_bed.py \\
        --homer-rna ${homer_rna} \\
        --chrom-sizes ${chrom_sizes} \\
        --output ${genome_name}_genes.bed \\
        ${args}
    """

    stub:
    """
    touch ${genome_name}_genes.bed
    """
}
