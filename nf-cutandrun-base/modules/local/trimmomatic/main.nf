process TRIMMOMATIC {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/trimmomatic:0.39--hdfd78af_2'
        : 'quay.io/biocontainers/trimmomatic:0.39--hdfd78af_2'}"

    input:
    tuple val(meta), path(reads)
    val(adapters_path)

    output:
    tuple val(meta), path(["${prefix}_R1_paired.fq.gz", "${prefix}_R2_paired.fq.gz"]), emit: trimmed_reads
    tuple val(meta), path("${prefix}_trimmomatic.log"), emit: log
    tuple val("${task.process}"), val('trimmomatic'), val('0.39'), emit: versions_trimmomatic, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: 'SLIDINGWINDOW:4:10 TRAILING:3 MINLEN:10'
    def illuminaclip_params = params.trimmomatic_illuminaclip ?: '2:25:7:1:true'
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    TRIMMOMATIC_CMD="trimmomatic"
    if [[ -n "${params.trimmomatic_jar ?: ''}" && -f "${params.trimmomatic_jar ?: ''}" ]]; then
        TRIMMOMATIC_CMD="java -jar ${params.trimmomatic_jar}"
    fi

    \$TRIMMOMATIC_CMD PE \\
        -threads ${task.cpus} \\
        "${reads[0]}" "${reads[1]}" \\
        "${prefix}_R1_paired.fq.gz" "${prefix}_R1_unpaired.tmp.fq.gz" \\
        "${prefix}_R2_paired.fq.gz" "${prefix}_R2_unpaired.tmp.fq.gz" \\
        ILLUMINACLIP:"${adapters_path}":${illuminaclip_params} \\
        ${args} \\
        2> "${prefix}_trimmomatic.log"

    rm -f "${prefix}_R1_unpaired.tmp.fq.gz" "${prefix}_R2_unpaired.tmp.fq.gz"
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "" | gzip -c > "${prefix}_R1_paired.fq.gz"
    echo "" | gzip -c > "${prefix}_R2_paired.fq.gz"
    touch "${prefix}_trimmomatic.log"
    """
}

