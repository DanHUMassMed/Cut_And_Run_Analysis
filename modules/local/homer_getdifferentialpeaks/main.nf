process HOMER_GETDIFFERENTIALPEAKS {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/0f/0fe4a3875b78dce3c66b43fb96489769cc32e55e329e2525d2af09096af2252a/data'
        : 'community.wave.seqera.io/library/bioconductor-deseq2_bioconductor-edger_homer_samtools_pruned:a8f4c58755bb281b'}"

    input:
    tuple val(meta), path(treatment_tagdirs), path(background_tagdirs), path(peaks_bed)
    val genome_name

    output:
    tuple val(meta), path("${prefix}_differential_peaks.txt"), emit: txt
    tuple val("${task.process}"), val('homer'), val('4.11'), emit: versions_homer, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    def treat_list = treatment_tagdirs instanceof List ? treatment_tagdirs : [treatment_tagdirs]
    def bg_list    = background_tagdirs instanceof List ? background_tagdirs : [background_tagdirs]
    def diff_alg   = (treat_list.size() < 2 && bg_list.size() < 2 && !args.contains('-edgeR') && !args.contains('-DESeq')) ? '-edgeR -balanced' : ''
    """
    getDifferentialPeaksReplicates.pl \\
        -t ${treatment_tagdirs} \\
        -b ${background_tagdirs} \\
        -p ${peaks_bed} \\
        -genome ${genome_name} \\
        ${diff_alg} \\
        ${args} \\
        > ${prefix}_differential_peaks.txt

    if [ ! -s ${prefix}_differential_peaks.txt ]; then
        echo "ERROR: getDifferentialPeaksReplicates.pl produced an empty output file for ${prefix}." >&2
        exit 1
    fi
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_differential_peaks.txt
    """
}
