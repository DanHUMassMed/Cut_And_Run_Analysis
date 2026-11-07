# Downstream analysis steps

Beyond this point, all the data processing is pretty much done, and the data are ready for any downstream analysis that you may want to do. Below are scripts for various things you may want to do in your downstream analysis. Because downstream analysis varies a lot depending on the experiment, a lot of these steps are highly customizable. As such, if one of the scripts below doesn’t do quite what you want, I recommend looking up the documentation for the command to see how to get the output you need.

## a. Making a tag directory in HOMER

HOMER is an analysis suite used for various downstream steps. Both `homer` and `samtools` must be available in the execution environment (e.g., via a Conda environment or container in Nextflow).

In order to do any downstream steps with HOMER, you first need to make something called a HOMER tag directory:

```bash
makeTagDirectory SAMPLE_TAG_DIRECTORY/ SAMPLE.sam
```

## b. Making files for viewing on the genome browser

There are two types of browser track files I use to view my data: bedGraph and bigWig. BedGraph files are a bit bigger in size and plot the data with slightly higher base resolution, while bigWig files cut down a bit on resolution to save on file size.

To make a bedGraph file using HOMER (`homer` and `samtools` must be available):

```bash
makeUCSCfile SAMPLE_TAG_DIRECTORY/ -o auto
```

To make a bigWig file using deeptools (`samtools` and `deeptools` must be available):

```bash
samtools view -bh SAMPLE.sam > SAMPLE.bam
samtools index SAMPLE.bam
bamCoverage -b SAMPLE.bam --normalizeUsing RPKM -o SAMPLE.bw
```

Here, we’re first using `samtools view` to convert the sam file into bam format. The `-b` argument specifies that the output will be in bam format, and the `-h` argument specifies that the header will be included. Second, we’re making a bam index file of our bam file, which will have the suffix `.bam.bai`. This is simply a prep step required for the next command. Lastly, we’re using `bamCoverage` from deeptools to make our bigWig file.

## c. Calling peaks

Two important notes about peak calling:

First, peak calling is always an imperfect process to some extent. Peak calling algorithms usually do a pretty good job with the obvious peaks, but there will always be tiny borderline blips of signal that are called as peaks even when they look like they shouldn’t be or vice versa. This means that while peak calling is a necessary part of many analyses, the presence or absence of a peak call can’t always be taken as an end-all-be-all result. If you want to look at peaks being lost or gained between two conditions, it’s often more informative to look at lost or gained intensity at those sites rather than looking at whether or not a peak was called.

Second, while peak calling for ChIP-seq is done against a reference input sample, I’ve found that doing the same with CUT&RUN and CUT&Tag against an IgG sample doesn’t yield great results. I think because of how sparse the background is for CUT&RUN and CUT&Tag, IgG negative control libraries for CUT&RUN and CUT&Tag don’t provide as even of a baseline to call against as input does in ChIP-seq. There is a CUT&RUN/CUT&Tag-specific peak caller called SEACR, but I’ve not had success with it myself. Instead, I’ve had the most success calling peaks in CUT&RUN and CUT&Tag by using traditional ChIP-seq peak callers but without using a background file, although you’re certainly welcome to experiment with alternative approaches yourself!

There are two peak callers that I’ve used: MACS2 and HOMER. The main difference I’ve found is that MACS2 has a propensity to call lots of narrow peaks whereas HOMER will often call fewer and broader peaks. You can also make MACS2 call slightly broader peaks using the `--broad` argument if you want something in the middle. There’s no clear favorite among these three that will work best in every situation. I’d recommend just trying one, seeing how the peaks look, and then if they look too broad or too narrow, see if one of the other methods works better for your data.

**For calling peaks with MACS2** (`macs2` must be available):

```bash
macs2 callpeak -t SAMPLE.bam \
  -g GENOME_SIZE \
  -f BAMPE \
  -n SAMPLE \
  -q 0.01
```

Breaking down the command:

* `-t` specifies your experiment bam file. If you want to try calling peaks against an IgG background, specify that bam file using the `-c` argument.
* `-g` specifies the size of the genome you’re mapping to. If you’re working in human, mouse, C. elegans or Drosophila, MACS2 has pre-loaded shortcuts for those genome sizes that can be specified using `hs`, `mm`, `ce`, or `dm`, respectively, in place of an actual number.
* `-n` specifies the sample prefix that will be on all files output by this command.
* `-q` specifies the minimum FDR cutoff

This command will produce three files, one narrowPeak file (these are the peaks themselves), a bed file of the peak summits, and an Excel file providing more details about the peaks. If you use the `--broad` argument, the peak file will instead have the broadPeak suffix, and the summits file will be replaced by one with the suffix gappedPeak. To be honest, I’m not 100% sure what the gappedPeak file actually is.

**For calling peaks with HOMER** (`homer` and `samtools` must be available):

```bash
findPeaks SAMPLE_TAG_DIRECTORY/ \
  -style <factor/histone> \
  -o SAMPLE_peaks.txt

pos2bed.pl SAMPLE_peaks.txt > SAMPLE_peaks.bed
```

The `findPeaks` command is for actually calling the peaks. The `-style` argument specifies whether the program will look for narrower TF-style peaks (`factor`) or broader histone mark-style peaks (`histone`). There are more options you can use for this argument, but those are the only two I use for CUT&RUN or CUT&Tag. The `pos2bed.pl` command simply converts the peaks from the first step from a HOMER-specific txt format to the more widely used bed format.

## d. Merging peak files using bedtools

The `bedtools` suite must be available in the environment. The commands I find I get the most use out of are `intersect`, `sort`, `merge`, and `slop`. The use cases for the suite are so varied and the bedtools website is so detailed already that it doesn’t make much sense for me to type it all up myself. Instead, I’ll just direct you to the bedtools website with a few words of wisdom:

* A lot of bedtools operations require that you first sort your bed file by genome coordinate using `bedtools sort`.
* The `bedtools merge` command doesn’t merge multiple bed files. Instead, it takes a single bed file and merges any ranges within that file that overlap with each other into a single range while leaving the non-overlapping ranges unchanged. If you want to merge multiple bed files, you’ll need to first `cat` the files together, then sort the combined file, and then use `bedtools merge`.
* If you’re working with multiple replicates from the same condition, I’d recommend first calling peaks on each replicate individually, then merge the files but only keep peaks that are called in multiple replicates. This can help remove tiny borderline peak calls that only got called in one replicate and can make your peak-by-peak analyses more noisy.
* When making a master peak set across multiple conditions for peak-by-peak analysis (below), I’d recommend first merging the replicates of each condition as above and then merging the peaks from each condition inclusively (i.e., keep all peaks when merging between conditions, even those that are only called in one condition).

## e. Peak-by-peak analysis using HOMER

To do peak-by-peak analysis, I use the `annotatePeaks` command from HOMER (`homer` and `samtools` must be available). This will take a set of peaks and a set of samples and output a file that shows the amount of signal each sample has at each peak (which will be expressed in terms of number of fragments per 10 million mapped, aka “normalized tags”) and also includes a bunch of other useful information about each peak such as its location relative to nearest genes and genomic annotations. You can then load this file into Rstudio (or Python or any other data analysis software that handles large data tables) and plot/analyze things however you like.

One other important note about normalized tags: HOMER doesn’t by default normalize these numbers by the width of a peak, meaning that wider peaks will tend to have higher numbers than narrower ones. If you’re comparing individual peaks across conditions, then this won’t be an issue, but if you want to compare different peaks to one another, then you’ll need to make a new column of the table yourself for normalized tags per kb or per bp.

```bash
annotatePeaks.pl PEAK_FILE.bed \
  REFERENCE_GENOME_NAME \
  -size given \
  -d SAMPLE1_TAG_DIRECTORY/ \
  SAMPLE2_TAG_DIRECTORY/ \
  SAMPLE3_TAG_DIRECTORY/ \
  SAMPLE4_TAG_DIRECTORY/ > OUTPUT_FILE.txt
```

## f. Calling differential peaks using HOMER

This command works similar to the HOMER `annotatePeaks` command (`homer` and `samtools` must be available) but calls the significance of fold changes between one condition and another at a specific set of peaks. Similar to `annotatePeaks` above, the file output by this command has columns that are meant to express the normalized tags of each sample at each peak, but weirdly, I’ve not found that these numbers match those in the `annotatePeaks` output file. I’m not sure why this is, but I’ve found that the normalized tags numbers in the `annotatePeaks` output are the numbers to trust. Really the only thing that I use in the output from the command below is the adjusted p-value (aka FDR or q-value) for change in each peak.

```bash
getDifferentialPeaksReplicates.pl \
  -t CONDITION2_REP1_TAG_DIRECTORY/ \
  CONDITION2_REP2_TAG_DIRECTORY/ \
  CONDITION2_REP3_TAG_DIRECTORY/ \
  -b CONDITION1_REP1_TAG_DIRECTORY/ \
  CONDITION1_REP2_TAG_DIRECTORY/ \
  CONDITION1_REP3_TAG_DIRECTORY/ \
  -p PEAK_FILE.bed \
  -genome REFERENCE_GENOME_NAME \
  -all > OUTPUT_FILE.txt
```

Breaking down the command:

* The `-t` and `-b` arguments are for specifying your experimental and control tag directories, respectively (aka “treatment” and “background”). Thus, peaks that are higher in `-t` than in `-b` will be expressed with a positive fold change in the output file.
* The `-all` argument specifies that all peaks will be printed in the output, not just ones that are significantly changed.

## g. Making metapeak plots (aka tornado plots)

There are a lot of customization options for making metapeak plots with `deeptools` (e.g., changing the color scale, sorting based on the intensity of a specific sample, k-means clustering of the peaks, etc.). Below is a basic script for making metapeak plots (`deeptools` must be available), but if you want to customize it further, the deeptools website has thorough documentation for how to do so.

```bash
computeMatrix reference-point -S SAMPLE1.bw \
  SAMPLE2.bw \
  -R PEAK_FILE.bed \
  -a BP_DOWNSTREAM \
  -b BP_UPSTREAM \
  --referencePoint center \
  -o OUTPUT_MATRIX.mat.gz

plotHeatmap -m OUTPUT_MATRIX.mat.gz \
  --colorMap inferno \
  --interpolationMethod nearest \
  -o OUTPUT.pdf
```

## h. Looking for enriched motifs in peaks

When you’re testing a new antibody for a TF of interest, the best way to tell if it’s working properly is to compare it to a previous ChIP-seq dataset for the same TF in roughly the same cell type. However, in situations where no such dataset is available, the next-best option is to look for enrichment of a known binding motif for the TF in the peaks. There are two different methods I’ve used to do this in the past: HOMER and the MEME suite.

**Using HOMER** (`homer` and `samtools` must be available):

```bash
findMotifsGenome.pl PEAK_FILE.bed \
  REFERENCE_GENOME_NAME \
  OUTPUT_DIRECTORY/ \
  -size 100
```

One note about the `-size` argument above: peaks are often not precisely centered on the binding motif for a TF. Instead, motifs are usually within ~50 bp of the peak center, which sometimes falls outside the bounds of the peak itself. The `-size` argument sets how big of a region (centered on the peak center) the program will look for motifs in. If you want to restrict your motif search to only the bounds of your called peaks, specify “given” in place of a number in this argument.

Inside the output directory made by this command, there will be two sets of results: so-called “known” results and “homer” results. The “known” results will display previously identified TF motifs that were found to be enriched in your peaks. The “homer” results will display motifs that HOMER detected de novo in your peaks and will show what known motif these results match most closely.

**Using the MEME suite** (`awk`, `bedtools`, and the `meme` suite must be available):

```bash
awk 'BEGIN{FS=OFS="\t"} {print  $1, int(($2 + $3)/2), int(($2 + $3)/2) + 1}' PEAK_FILE.bed |\
bedtools slop -i stdin -g GENOME.chrom.sizes -l 50 -r 49 > PEAK_CENTERS_PlusMinus50bp.bed

bed2fasta -o PEAK_CENTERS_PlusMinus50bp.fa \
  PEAK_CENTERS_PlusMinus50bp.bed \
  GENOME.fa

streme --oc OUTPUT_DIRECTORY \
  --nmotifs 20 \
  --dna \
  --p PEAK_CENTERS_PlusMinus50bp.fa
```

The code above has three steps. First, we need to make a new bed file that is our peak centers plus/minus 50 bp. We do this by using some awk code to find the center of each peak in the form of 1-bp-wide ranges, then we pipe that output to bedtools slop, which adds a defined number of bp onto either side of our peak centers, resulting in 100-bp wide ranges. Second, we convert these bed ranges into fasta sequences, and third, we feed those sequences into STREME, which is the MEME suite’s motif detection program.

STREME will detect enriched motifs de novo, but unlike HOMER, it won’t by default tell you what known motifs these correspond to. If you already know what motif you’re looking for, you can just examine the STREME results by eye to see if your motif of interest pops out. If you don’t know what you’re looking for or if a motif pops out that is unfamiliar to you, the MEME suite has a program called TOMTOM that will tell you what known motifs your STREME results match most closely. I’ve not used TOMTOM myself and thus don’t have any code example to present, but the MEME suite website has pretty good documentation for how to use all their programs.
