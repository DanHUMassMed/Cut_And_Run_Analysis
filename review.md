# CUT&RUN Downstream Analysis Pipeline: Technical and Bioinformatics Review

> **Generated with:** Seqera Co-Scientist CLI (`seqera ai --headless`, v1.14.0)  
> **Target:** `/Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis`  
> **Scope:** `main.nf`, `nextflow.config`, `conf/`, `workflows/`, `subworkflows/local/`, `modules/local/`, `lib/`, `bin/`, the two helper scripts at the repo root, and `docs/Example_Run/config/`. Nothing was edited or created during evaluation.  
> **Checks run:** `nextflow lint` (Nextflow 26.10.0) gave **0 errors and 43 warnings in 6 files**. `git status` shows a large amount of uncommitted and untracked work.

---

## Executive summary

The engineering is careful for a single-lab pipeline. It has typed DSL2 modules with `stub:` blocks, topic-channel versions, strong samplesheet validation, per-target `peak_mode`, and FRiP that compares IgG against targets on a shared peak set. A fresh clone and the statistics of the differential results are the weak points:

1. **The code is not reproducible from git.** The whole `subworkflows/` directory, 5 modules and 2 `bin/` scripts are untracked, and `modules.json` is deleted.
2. **The example design has n = 1 per condition.** Differential peaks are still produced with p-values and FDR, replicate filtering quietly does nothing, and the volcano script quietly switches to raw p-values.
3. **Runs depend on earlier runs.** "Pre-existing" inputs are read back from `${params.outdir}`, so old results can be mixed into new ones without any warning.
4. **HOMER genome data is supplied through `docker.runOptions` bind mounts.** That breaks Singularity, cloud executors and Seqera Platform, and the HOMER version changes by CPU architecture.

---

## 🔴 Critical

### C1. Core pipeline code is untracked or uncommitted
`git status`:
```text
?? subworkflows/                       (all 4 subworkflows)
?? modules/local/deeptools/{bigwig_qc,gene_metaplot,plotfingerprint}/
?? modules/local/python/{plot_frip_and_depth,util_prepare_gene_bed}/
?? bin/homer_rna_to_gene_bed.py  bin/plot_frip_and_depth.py
 D modules.json
 M main.nf, nextflow.config, workflows/cutandrun.nf, conf/*, lib/*, 13 modules
```
The working tree's `workflows/cutandrun.nf` includes `subworkflows/local/*`, which is not in git. A clone, `nextflow run <repo> -r <tag>`, or a Seqera Platform launch would either fail or run different code from what produced your results. Lab-notebook reproducibility fails as well, because no commit SHA describes what was actually run.

**Fix:**
- Commit everything on a feature branch and tag a release.
- Record `workflow.commitId` / `workflow.revision` in `pipeline_info`.
- Either restore `modules.json` or remove the empty `modules/nf-core/` directory on purpose.

### C2. Differential analysis without replicates
- In `docs/Example_Run/config/samplesheet.csv`, every condition has `replicate = 1`, and all 3 contrasts in `experiment.config:71-75` are 1 vs 1.
- `modules/local/homer/getdifferentialpeaks/main.nf:33` silently adds `-edgeR -balanced` when both groups have fewer than 2 samples. With no replicates, edgeR has no dispersion estimate, so the reported p-values and FDR have no inferential meaning.
- `bin/plot_differential_volcano_ma.py:169-170`: if no FDR value is below 0.9999, the script **switches to raw p-values** for significance calls, colouring and the "Up_in_X" labels in `*_top_differential_genes.tsv`. Nothing in the output marks that this happened. That is p-hacking by default.
- **Batch confounding:** N2 samples are `S66–S68_L008` and EV_INT samples are `S141–S143_L004` (EV_INT_MC is also on L008). Condition is partly confounded with sequencing run, and the only IgG (`S143_L004`) belongs to the EV_INT batch.

**Fix:**
- In `validateDiffContrasts` (`lib/samplesheet.nf`), fail or warn loudly when either group has fewer than 2 replicates. For n = 1, output only descriptive fold changes, with no p-values or FDR.
- Remove the raw-p fallback, or print it in the plot title and in a TSV column.
- Note the lane/batch structure in the docs, and add a `batch` column to the samplesheet.

---

## 🟠 High

### H1. Results from earlier runs are reused without warning
`main.nf:130+` resolves `ch_existing_sample_peaks`, `ch_existing_replicated_peaks`, `ch_existing_master_peaks`, `ch_existing_annotated_peaks` and `ch_existing_diff_peaks` from `${params.outdir}`.
- `subworkflows/local/peak_calling/main.nf:111-148` falls back to, or **mixes**, these with freshly computed channels. For example, the master set is built from `ch_replicated_peaks.mix(ch_active_sample_peaks)` when replicate merging is off.
- Output names don't include the peak caller (`${condition}_replicated_peaks.bed`, `${target}_master_peaks.bed`). Switching `active_peak_caller` therefore overwrites the files, and later "existing" runs pick up whichever caller ran last.
- A missing fallback file is only logged, so downstream steps silently drop out.

**Fix:**
- Make reuse explicit, for example `params.reuse_from = '<dir>'` that defaults to null.
- Put the caller in file names and directories (`10_merged_peaks/macs2/...`).
- Use `-resume` for caching instead of reading `outdir` back in.

### H2. `min_replicate_overlap` is silently weakened
`modules/local/bedtools/merge_replicates/main.nf:32` sets `effective_min = min(n_reps, min_overlap)`. With n = 1, the "replicated_peaks" file is just one sample's peaks, but the name and docs suggest a reproducibility filter. **Fix:** emit `log.warn` from `PEAK_CALLING` and record the effective N in the output name or a sidecar file.

### H3. No ce11 blacklist and no chrM filtering
- `chrom.sizes` includes `chrM`.
- No step removes ENCODE/Boyle-lab `ce11-blacklist.v2` regions or chrM before peaks are merged, annotated, run through FRiP or used for motifs.

In worms, high-signal artefact regions (rDNA and satellite repeats on chrI/chrV arms) inflate peak counts and motif hits. **Fix:** add a `bedtools intersect -v` step against a blacklist plus chrM right after each caller.

### H4. Settings in `experiment.config` for derived input globs are overwritten
In `nextflow.config:124-134`, the second `params {}` block runs **after** `includeConfig "${launchDir}/config/experiment.config"`. It therefore overwrites any `input_bam`, `input_bigwig`, `input_sample_peaks`, etc. set in `experiment.config`; only CLI `--param` still wins.

Separately, a missing `config/experiment.config` makes config parsing fail with an unclear error, even for `nextflow config`. **Fix:**
- Use `params.input_bam = params.input_bam ?: "${params.input_dir}/..."`, or derive the globs in `main.nf`.
- Use `-c`/`-params-file` instead of a hard-coded `launchDir` include.

### H5. HOMER genome provisioning and version drift
- In `nextflow.config:147/165/176`, the ce11 genome is supplied by `docker.runOptions -v` bind mounts. This only works on local Docker; Singularity, AWS Batch, Google Batch and Seqera Platform all ignore it.
- `HOMER_FINDMOTIFSGENOME` uses `quay.io/biocontainers/homer:4.9.1` (and the Galaxy 4.9.1 SIF) on amd64. The arm64 container and conda use 4.11, and the other HOMER modules use 4.11.
- The version strings are hard-coded (`val('4.9.1')`, `val('4.11')`), so the `versions` topic is wrong on arm64.
- The genome data package is labelled HOMER **v4.11.1** (`assets/homer_ce11/config.txt`) but is mounted into the 4.9.1 container.

**Fix:**
- Use one HOMER 4.11 image for all HOMER modules.
- Pass the genome as a `path` input with `findMotifsGenome.pl ... ${genome_fa}`, and use `annotatePeaks.pl ... ${fasta} -gtf ${gtf}` or `-preparsedDir`, instead of the `ce11` keyword.
- Report the version with `eval('homer ... | grep version')`.

### H6. Differential-table parser relies on column positions
`bin/cutandrun_plot_utils.py:495-512` assumes the last 3 columns are FC, p and FDR, and that the tag columns split **in half** with background first. With unequal group sizes (2 vs 3), or if HOMER orders target before background, the mean tag counts and the MA-plot A-values will be wrong. **Fix:** find the columns by header (the `Tag Count` headers contain the tag-directory names) and match them to the contrast's sample IDs.

### H7. Not ready for Seqera Platform or portable execution
- Configuration lives in `launchDir/config/experiment.config`, and `params.input_dir` is a local Dropbox path that is also bind-mounted.
- There is no `nextflow_schema.json`, so Launchpad has no launch form or validation.
- `resourceLimits` is set only in the example `experiment.config:109`, not in `conf/base.config`. Without it, a laptop run requesting `process_medium` (e.g. 36 GB) fails on the local executor.

**Fix:**
- Move defaults into `nextflow.config`, add `resourceLimits` to `base.config`, and add a schema.
- Make every input an S3/GS URI-capable `path`.
- Add a `test` profile.

---

## 🟡 Medium

### Methodology for ce11 CUT&RUN

**M1. Broad marks (H3K27me3).**
- In *C. elegans*, H3K27me3 forms megabase-scale domains on chromosome arms and on chrX in the germline. MACS2 `--broad` and HOMER `-style histone` break these into many fragments.
- Consider SEACR (the CUT&RUN standard; used by nf-core/cutandrun), epic2/SICER, or a domain-calling method based on fixed bins.
- `metapeak_reference_point = 'center'` (`nextflow.config:80`) on merged broad domains is not meaningful; use `scale-regions` for `peak_mode == 'broad'`.

**M2. Normalisation for comparing conditions.**
- HOMER normalises to 10 M tags, and the bigwigs are RPKM or HOMER UCSC files, chosen by `bigwig_source`.
- This hides global changes, which are typical when perturbing PRC2/H3K27me3.
- CUT&RUN carries over *E. coli* DNA (or uses yeast spike-in). Add an optional spike-in scale factor, and print the normalisation used on every metaplot.

**M3. Motif analysis.**
- `HOMER_FINDMOTIFS` and `MEME_STREME` run on master peaks of **all** targets, including H3K27me3, using the centre of **merged** intervals rather than summits.
- MACS2 summits are produced but thrown away by the 3-column `merge_ready` BED.
- Limit motif analysis to `narrow` targets, centre on summits, and add `-mask`.
- MEME output names hard-code `PlusMinus50bp` (`meme/streme/main.nf:27-28`) even though `meme_slop_*` can be changed.

**M4. HOMER `-style factor` for H3K4me3.** H3K4me3 is nucleosomal, not a TF. `-style histone` (or `factor` with `-size`/`-L` tuned) tends to give promoter-sized peaks that agree better with MACS2. This would partly explain the MACS2 vs HOMER count gap documented in earlier commits.

**M5. MACS2 narrow `-p 1e-5`** without a q-value permits many false positives at CUT&RUN's low background. Consider the q-value as default, or IDR/consensus once replicates exist. MACS2 is single-threaded but labelled `process_medium`, which wastes CPUs and limits local parallelism.

**M6. Gene BED (`bin/homer_rna_to_gene_bed.py`).**
- HOMER `.rna` starts are 1-based, but they are written to BED without subtracting 1, an off-by-one error.
- Isoform collapsing keeps only the longest transcript per overlapping same-strand cluster, which can merge distinct genes.
- Names are RefSeq `NM_` IDs, not gene names.
- Worm-specific caveat for TSS metaplots: SL1 trans-splicing and operons (~15% of genes) mean many annotated "TSSs" are trans-splice acceptors, not promoters. Consider TSSs from GRO-cap/ATAC data (Chen 2013, Kruesi 2013, Jänes 2018).

**M7. FRiP (`bin/plot_frip_and_depth.py`).**
- The interval-merging and no-double-count logic is correct.
- If `pysam` fails to import, FRiP is silently 0 or skipped. Make this a hard error.
- Counting reads rather than fragments is consistent between numerator and denominator, but say so in the axis label.

### Pipeline engineering

**M8. Input requirements don't follow the toggles.** `main.nf` requires tag directories and bigwigs for **every** samplesheet ID (`expectedIds`), even when HOMER or deepTools steps are disabled. Also, gene metaplots run under `run_summary_plots` rather than `run_deeptools_metapeak`.

**M9. The `arm64` profile's `wave.strategy = 'conda,container'`** (`nextflow.config:173`) makes Wave build from `environment.yml` whenever a `conda` directive exists, so the hand-pinned arm64 images are probably bypassed. This needs to be checked. Use `'container,conda'` if pinned images are intended.

**M10. Unmatched items are silently dropped.** `join` between master peaks and tag directories in `peak_annotation_and_diff` drops targets that have no match. Use `join(..., failOnMismatch: true)`, or add an explicit check.

**M11. Lint warnings.** 43 warnings: implicit `it` in `lib/samplesheet.nf` (×20), the subworkflows, `conf/modules.config:45,66` and `deeptools/metapeak:34`, plus unused closure parameters (`peak_calling:28,57`, `peak_annotation_and_diff:26`, `qc_and_plots:48`). These are low-risk, easy fixes ahead of a Nextflow 26 strict upgrade.

---

## 🟢 Low

- **L1. No tests or CI.** There is no nf-test, no `test` profile and no CI workflow, even though every module has a `stub:` block. A `-stub-run` smoke test with a tiny samplesheet is nearly free.
- **L2. nf-core module equivalents exist** for `macs2/callpeak`, `homer/*`, `deeptools/*`, `bedtools/merge` and `meme`. Reusing them would reduce maintenance.
- **L3. `assets/homer_ce11` (~300 MB of genome data) is in git.** Prefer a download or staging step, Git LFS, or an S3/Zenodo URI.
- **L4. Root helper scripts** `Peak_Count_by_Chromosome.sh` and `Signal_Check_on_chrX.sh` hard-code experiment `cut_run103026B`, sample IDs and fixed columns from position 19 onward. The chrX dosage and germline-silencing checks are good biology; consider turning them into a parameterised module, or moving them to `docs/` or `scripts/`.
- **L5. Possibly too many samples for plotFingerprint** (low confidence): `--numberOfSamples 500000` × `--binSize 500` = 250 Mb, which is more than the ~100 Mb ce11 genome. 100–150 k is more sensible.
- **L6. IgG detection is defined twice:** `is_igg_label` (Python, token match on any label) and `isControlTarget` (Groovy, exact match on target). Use a single definition.
- **L7. The `.bigWig` suffix can never match** because the glob is `*.bw`. `docker.runOptions` is duplicated across the global block and two profiles.
- **L8. Contrasts against IgG are allowed** by validation. A target-vs-IgG differential test is not meaningful; restrict contrasts to the same target.
- **L9. Modernisation:** consider a workflow `output {}` block instead of `publishDir`, and typed params, when moving to 26.04+ strict syntax. Don't make this part of the fixes above.

---

## What works well
- **Samplesheet validation** in `lib/samplesheet.nf`:
  - required headers
  - duplicate replicates per condition
  - one target per condition
  - consistent `peak_mode` per target
  - `control_id` checked against the sheet
  - contrasts checked against conditions and targets
- **`resolveInputFiles` options:** `requireBai`, `skipEmpty` (useful for Dropbox placeholder files) and `errorOnUnrecognized`.
- **Module hygiene:** consistent typed `tuple val(meta)` modules with stubs, versions sent to a topic channel, an explicit `-C noclobber` shell, and retries that scale memory on exit codes 104 and 130–145.
- **Shared-peak FRiP:** targets and matched IgG are scored on the same peak set, which is the right comparison for enrichment.
- **QC parsing:** read-retention and depth QC combines Trimmomatic, Bowtie2, Picard, samtools and HOMER, and degrades gracefully when a log is missing.

---

## Prioritised action list

| # | Priority | Action | Files |
|---|---|---|---|
| 1 | Critical | Commit `subworkflows/`, the new modules and `bin/` scripts; tag a release | repo |
| 2 | Critical | Block or flag inferential diff stats when n < 2; remove the raw-p fallback; document lane batch | `lib/samplesheet.nf`, `homer/getdifferentialpeaks`, `bin/plot_differential_volcano_ma.py` |
| 3 | High | Replace reuse of `outdir` with explicit `reuse_from`; caller-specific output names | `main.nf`, `subworkflows/local/peak_calling` |
| 4 | High | Add a ce11 blacklist and chrM filter after peak calling | new step in `peak_calling` |
| 5 | High | Fix param precedence (`?:` defaults); stop the hard-coded `launchDir` include | `nextflow.config:124-134` |
| 6 | High | One HOMER 4.11 image; genome as `path` inputs; versions from `eval` | `modules/local/homer/*`, `nextflow.config` |
| 7 | High | Parse HOMER diff columns by header | `bin/cutandrun_plot_utils.py:451-534` |
| 8 | High | `resourceLimits` in `base.config`, `nextflow_schema.json`, `test` profile | `conf/base.config`, repo root |
| 9 | Medium | SEACR/epic2 option for broad marks; `scale-regions` metaplots for broad targets; spike-in normalisation | `conf/modules.config`, `deeptools/*` |
| 10 | Medium | Motifs: narrow targets only, summit-centred, `-mask`; fix hard-coded MEME names | `motif_discovery`, `meme/streme` |
| 11 | Medium | Fix the gene BED off-by-one; document trans-splicing/operon caveats for TSS plots | `bin/homer_rna_to_gene_bed.py` |
| 12 | Medium | Require inputs only for enabled steps; `failOnMismatch` joins; fix the 43 lint warnings | `main.nf`, subworkflows |
| 13 | Low | stub-run CI, nf-core modules, move the HOMER assets out of git, parameterise the helper scripts | repo |

Start with items 1 and 2: they decide whether a fresh clone runs and whether the differential results can be trusted.
