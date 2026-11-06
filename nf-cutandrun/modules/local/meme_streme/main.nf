process MEME_STREME {
    tag "${meta.id}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container
        ? 'https://depot.galaxyproject.org/singularity/meme:5.5.7--pl5321h1ca524f_3'
        : 'quay.io/biocontainers/meme:5.5.7--pl5321h1ca524f_3'}"

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
    awk -v left=${slop_left} -v right=${slop_right} 'BEGIN{FS=OFS="\\t"}
        NR==FNR { chrom_len[\$1] = \$2; next }
        !/^#/ && !/^track/ && !/^browser/ && NF>=3 && (\$1 in chrom_len) {
            center = int((\$2 + \$3) / 2)
            s = center - left
            e = center + 1 + right
            if (s < 0) s = 0
            if (e > chrom_len[\$1]) e = chrom_len[\$1]
            if (e > s) print \$1, s, e
        }' ${chrom_sizes} ${peaks_bed} > ${prefix}_centers_PlusMinus50bp.bed

    if [ -d "${genome_fasta}" ]; then
        cat "${genome_fasta}"/chr*.fa > genome_combined.fa
        fasta-file-indexer genome_combined.fa genome_combined.fa.fai
        FASTA_REF="genome_combined.fa"
    else
        if [ ! -f "${genome_fasta}.fai" ]; then
            cp "${genome_fasta}" genome_combined.fa
            fasta-file-indexer genome_combined.fa genome_combined.fa.fai
            FASTA_REF="genome_combined.fa"
        else
            FASTA_REF="${genome_fasta}"
        fi
    fi

    bed2fasta \\
        -o ${prefix}_centers_PlusMinus50bp.fa \\
        ${prefix}_centers_PlusMinus50bp.bed \\
        "\${FASTA_REF}"

    rm -f genome_combined.fa genome_combined.fa.fai

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

