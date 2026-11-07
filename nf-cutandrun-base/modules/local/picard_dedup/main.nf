process PICARD_DEDUP {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/picard:2.27.5--hdfd78af_0'
        : 'quay.io/biocontainers/picard:2.27.5--hdfd78af_0'}"

    input:
    tuple val(meta), path(sam)

    output:
    tuple val(meta), path("${prefix}_PicardDedup.bam"), emit: dedup_bam
    tuple val(meta), path("${prefix}_PicardSort.bam"), emit: sorted_bam, optional: true
    tuple val(meta), path("${prefix}_dup.txt"), emit: metrics
    tuple val("${task.process}"), val('picard'), val('2.5.0'), emit: versions_picard, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args  = task.ext.args  ?: 'VALIDATION_STRINGENCY=LENIENT SORT_ORDER=coordinate'
    def args2 = task.ext.args2 ?: 'VALIDATION_STRINGENCY=LENIENT REMOVE_DUPLICATES=true'
    def avail_mem = task.memory ? Math.max(4, (task.memory.toGiga() * 0.8).intValue()) : 4
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir -p tmp

    PICARD_CMD="picard -Xmx${avail_mem}g"
    if [[ -n "${params.picard_jar ?: ''}" && -f "${params.picard_jar ?: ''}" ]]; then
        PICARD_CMD="java -Xmx${avail_mem}g -jar ${params.picard_jar}"
    fi

    \$PICARD_CMD SortSam \\
        INPUT="${sam}" \\
        OUTPUT="${prefix}_PicardSort.bam" \\
        ${args} \\
        TMP_DIR="./tmp"

    \$PICARD_CMD MarkDuplicates \\
        INPUT="${prefix}_PicardSort.bam" \\
        OUTPUT="${prefix}_PicardDedup.bam" \\
        METRICS_FILE="${prefix}_dup.txt" \\
        ${args2} \\
        TMP_DIR="./tmp"
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch "${prefix}_PicardSort.bam"
    touch "${prefix}_PicardDedup.bam"
    touch "${prefix}_dup.txt"
    """
}

