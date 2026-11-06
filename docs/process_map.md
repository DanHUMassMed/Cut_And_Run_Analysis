| Step # | Process | Step | Tool | Input | Output | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 1 | Adapter Trim | 1 | trimmomatic | fatsq | fastq | |
| 2 | Alignment | 1 | bowtie | fastq | sam | |
| 3 | remove dups | 1 | picard SortSam | sam | bam | |
| 3 | remove dups | 2 | picard MarDuplicates | bam | bam | |
| 4 | remove low quality reads | 1 | samtool view | bam | sam | |
| 5 | remove fags 120 bp < | 1 | samtool view | sam | bam | (not currently used) |
| 6 | HOMER DIR | 1 | makeTagDirectory | sam | TAG_DIR | |
| 7 | make bedGrap | 1 | makeUCSCfile | TAG_DIR | bedGraph | |
| 8 | make BigWig | 1 | samtools view | sam | bam | |
| 8 | make BigWig | 2 | samtools index | bam | bai | |
| 8 | make BigWig | 3 | bamCoverage | bam | bw | |
