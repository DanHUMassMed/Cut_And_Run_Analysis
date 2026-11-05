process MEME_STREME {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/meme:5.5.7--pl5321h10d4599_0'
        : 'quay.io/biocontainers/meme:5.5.7--pl5321h10d4599_0'}"

    input:
    tuple val(meta), path(peaks_bed)
    path chrom_sizes
    path genome_fasta
    val slop_left
    val slop_right

    output:
    tuple val(meta), path("${prefix}_centers_PlusMinus50bp.bed"), emit: centers_bed
    tuple val(meta), path("${prefix}_centers_PlusMinus50bp.fa"), emit: centers_fa
    tuple val(meta), path("${prefix}_streme_motifs"), emit: motifs_dir
    tuple val("${task.process}"), val('meme'), eval('streme -version'), emit: versions_meme, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    awk 'BEGIN{FS=OFS="\\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print \$1, int((\$2 + \$3)/2), int((\$2 + \$3)/2) + 1}' ${peaks_bed} | \\
        bedtools slop -i stdin -g ${chrom_sizes} -l ${slop_left} -r ${slop_right} > ${prefix}_centers_PlusMinus50bp.bed

    bed2fasta \\
        -o ${prefix}_centers_PlusMinus50bp.fa \\
        ${prefix}_centers_PlusMinus50bp.bed \\
        ${genome_fasta}

    streme \\
        --oc ${prefix}_streme_motifs \\
        ${args} \\
        --p ${prefix}_centers_PlusMinus50bp.fa
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}_centers_PlusMinus50bp.bed
    touch ${prefix}_centers_PlusMinus50bp.fa
    mkdir -p ${prefix}_streme_motifs
    touch ${prefix}_streme_motifs/streme.html
    touch ${prefix}_streme_motifs/streme.txt
    """
}

