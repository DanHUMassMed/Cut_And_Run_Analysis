| Step # | Process | Step | Tool | Input | Output | postfix |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | Adapter Trimming | 1 | trimmomatic | fatsq | fastq | _paired.fq.gz|
| 2 | Alignment | 1 | bowtie2 | fastq | sam | .sam|
| 3 | Remove Duplicates | 1 | picard SortSam | sam | bam | _sort.bam|
| 3 | Remove Duplicates | 2 | picard MarDuplicates | bam | bam | _dedup.bam|
| 4 | Filter Low Quality Reads | 1 | samtool view | bam | sam | _mapqfilter.sam|
| 5 | Filter Fragment Length | 1 | samtool view | sam | bam | _120bp.bam (not currently used)|
| 6 | HOMER Tag Dir | 1 | makeTagDirectory | sam | TAG_DIR |tag_dir/ |
| 7 | HOMER WigWig | 1 | makeUCSCfile | TAG_DIR | bedGraph | .ucsc.bedGraph|
| 7 | HOMER WigWig | 1 | bedGraphToBigWig | bedGraph | bw | .homer.bw |
| 8 | deeptools BigWig | 1 | samtools view | sam | bam | .bam|
| 8 | deeptools BigWig | 2 | samtools index | bam | bai | .bam.bai|
| 8 | deeptools BigWig | 3 | bamCoverage | bam | bw | .deeptools.bw|
