/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW: MOTIF_DISCOVERY
    Step h (1): HOMER findMotifsGenome
    Step h (2): MEME STREME
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { HOMER_FINDMOTIFSGENOME } from '../../../modules/local/homer/findmotifsgenome/main'
include { MEME_STREME            } from '../../../modules/local/meme/streme/main'

workflow MOTIF_DISCOVERY {

    take:
    ch_master_peaks // channel: [ val(meta), path(master_bed) ]

    main:
    //
    // Step h (1): Looking for enriched motifs in peaks using HOMER (findMotifsGenome.pl)
    //
    def ch_homer_motifs = channel.empty()
    if (params.run_homer_findmotifs) {
        HOMER_FINDMOTIFSGENOME(
            ch_master_peaks,
            params.genome_name
        )
        ch_homer_motifs = HOMER_FINDMOTIFSGENOME.out.motifs_dir
    }

    //
    // Step h (2): Looking for enriched motifs in peaks using MEME Suite (STREME)
    //
    def ch_meme_motifs = channel.empty()
    if (params.run_meme_streme) {
        if (!params.chrom_sizes || !params.genome_fasta) {
            error("params.chrom_sizes and params.genome_fasta must be provided when params.run_meme_streme = true")
        }
        def chrom_sizes_file  = file(params.chrom_sizes, checkIfExists: true)
        def genome_fasta_file = file(params.genome_fasta, checkIfExists: true)

        MEME_STREME(
            ch_master_peaks,
            chrom_sizes_file,
            genome_fasta_file,
            params.meme_slop_left,
            params.meme_slop_right
        )
        ch_meme_motifs = MEME_STREME.out.motifs_dir
    }

    emit:
    homer_motifs = ch_homer_motifs
    meme_motifs  = ch_meme_motifs
}
