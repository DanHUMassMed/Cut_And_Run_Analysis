# How `BEDTOOLS_MERGE_REPLICATES` Resolves HOMER and MACS2 Inputs

> **Note:** This pipeline uses **MACS2** (`MACS2_CALLPEAK`), not MACS3. However, MACS3 produces the same standard `.narrowPeak` / `.broadPeak` BED formats, so the same mechanism applies.

---

## 1. Upstream Channel Resolution in `workflows/cutandrun.nf`

Before `BEDTOOLS_MERGE_REPLICATES` runs, `workflows/cutandrun.nf` decides which peak caller's output feeds into Step d:

1. **Peak Calling (Step c):**
   - `MACS2_CALLPEAK` ([modules/local/macs2/callpeak/main.nf](modules/local/macs2/callpeak/main.nf)) emits native `*.{narrowPeak,broadPeak}` on `MACS2_CALLPEAK.out.peak` and explicitly converts it into a headerless, sorted 3-column BED (`${prefix}_macs2_merge_ready_peaks.bed`) on `MACS2_CALLPEAK.out.merge_ready_bed`, published to `09_peaks/macs2/`.
   - `HOMER_FINDPEAKS` ([modules/local/homer/findpeaks/main.nf](modules/local/homer/findpeaks/main.nf)) runs `findPeaks ... -o ${prefix}_peaks.txt` and `pos2bed.pl ${prefix}_peaks.txt > ${prefix}_peaks.bed`, then explicitly strips `#` headers and extra columns into a sorted 3-column BED (`${prefix}_homer_merge_ready_peaks.bed`) on `HOMER_FINDPEAKS.out.merge_ready_bed`, published to `09_peaks/homer/`.

2. **Active Peak Caller Selection (`ch_active_sample_peaks`):**
   In [workflows/cutandrun.nf](workflows/cutandrun.nf#L67-L87), `ch_active_sample_peaks` is resolved strictly from `params.active_peak_caller` (`'macs2'` or `'homer'`):
   1. If `params.active_peak_caller == 'homer'` and `params.run_homer_findpeaks` is `true` → uses `ch_homer_peaks` (`HOMER_FINDPEAKS.out.merge_ready_bed`).
   2. If `params.active_peak_caller == 'macs2'` and `params.run_macs2_callpeak` is `true` → uses `ch_macs2_peaks` (`MACS2_CALLPEAK.out.merge_ready_bed`).
   3. If both `run_macs2_callpeak` and `run_homer_findpeaks` are `false` → defaults to `ch_existing_sample_peaks` (pre-existing files matching `params.input_sample_peaks`, by default `*_${params.active_peak_caller}_merge_ready_peaks.bed`).
   4. If `active_peak_caller` is disabled while the other caller is enabled → fails immediately with an `error(...)` instead of silently falling back.

3. **Grouping Replicates by Condition (Step d1):**
   In [workflows/cutandrun.nf](workflows/cutandrun.nf#L85-L97):
   - `IgG` control samples are filtered out (`meta.target?.toLowerCase() != 'igg'`).
   - Samples are re-keyed by `[ id: meta.condition, condition: meta.condition, target: meta.target ?: 'default' ]` and grouped with `.groupTuple(by: 0)` so all replicate peak files for a given condition are passed together as `beds` to `BEDTOOLS_MERGE_REPLICATES`.

---

## 2. How `BEDTOOLS_MERGE_REPLICATES` Merges the Standardized Inputs

Because `MACS2_CALLPEAK` and `HOMER_FINDPEAKS` each publish a standardized, headerless, sorted 3-column BED (`<sample_id>_macs2_merge_ready_peaks.bed` in `09_peaks/macs2/` and `<sample_id>_homer_merge_ready_peaks.bed` in `09_peaks/homer/`), `BEDTOOLS_MERGE_REPLICATES` ([modules/local/bedtools/merge_replicates/main.nf](modules/local/bedtools/merge_replicates/main.nf#L33-L44)) reads those uniform BED3 files directly and only needs to tag each interval with its source `FILENAME` before merging:

```bash
awk 'BEGIN{OFS="\t"} NF>=3 {print $1, $2, $3, FILENAME}' ${beds} > combined_unmerged.bed

if [ -s combined_unmerged.bed ]; then
    bedtools sort -i combined_unmerged.bed | \
        bedtools merge -i stdin -c 4 -o count_distinct ${args} | \
        awk -v min_rep=${effective_min} 'BEGIN{OFS="\t"} $4 >= min_rep {print $1, $2, $3}' > ${prefix}_replicated_peaks.bed
else
    touch ${prefix}_replicated_peaks.bed
fi
```

### Step-by-Step Breakdown

1. **Caller-Side Normalization (`MACS2_CALLPEAK` / `HOMER_FINDPEAKS`)**
   - **HOMER** (`pos2bed.pl`) prepends `#` header lines and outputs 6 columns (`chr`, `start`, `end`, `PeakID`, `score`, `strand`). `HOMER_FINDPEAKS` strips `#`/`track`/`browser` lines, extracts `$1, $2, $3`, and sorts into `${prefix}_homer_merge_ready_peaks.bed`.
   - **MACS2** outputs 10-column `.narrowPeak` or 9-column `.broadPeak` files. `MACS2_CALLPEAK` extracts `$1, $2, $3` and sorts into `${prefix}_macs2_merge_ready_peaks.bed`.
   - Both directories (`09_peaks/macs2/` and `09_peaks/homer/`) therefore contain a transparent, merge-ready BED3 file alongside the caller's native output.

2. **Source Tagging (`NF>=3 {print $1, $2, $3, FILENAME}`)**
   - `BEDTOOLS_MERGE_REPLICATES` appends `FILENAME` as column 4, producing `combined_unmerged.bed`.

3. **Sorting & Counting Distinct Replicates (`bedtools sort` | `bedtools merge -c 4 -o count_distinct`)**
   - `bedtools sort` orders all intervals across all replicate files.
   - `bedtools merge -i stdin -c 4 -o count_distinct` merges overlapping/adjacent intervals and counts how many **unique `FILENAME` values** contributed to each merged region.
   - Using `count_distinct` on `FILENAME` prevents multiple nearby peaks within the *same* replicate from inflating the replicate count.

4. **Replicate Threshold Filtering (`$4 >= min_rep {print $1, $2, $3}`)**
   - `effective_min` is computed in Nextflow as `bed_list.size() < min_overlap ? bed_list.size() : min_overlap` (default `params.min_replicate_overlap = 2` in [nextflow.config](nextflow.config#L37)). This caps the required overlap at the actual number of replicates available for that condition.
   - Intervals supported by at least `effective_min` replicates are written as a standard 3-column BED (`${prefix}_replicated_peaks.bed`).
   - If `combined_unmerged.bed` is empty (e.g. no peaks called in any replicate), an empty `${prefix}_replicated_peaks.bed` is created via `touch`.

---

## 3. Downstream Compatibility (`BEDTOOLS_MERGE_MASTER`)

In Step d(2), `BEDTOOLS_MERGE_MASTER` ([modules/local/bedtools/merge_master/main.nf](modules/local/bedtools/merge_master/main.nf#L33-L40)) uses the same `awk` pre-filter (`!/^#/ && !/^track/ && !/^browser/ && NF>=3 {print $1, $2, $3}`) before `bedtools sort` and `bedtools merge`. This means it works identically whether it receives the 3-column output from `BEDTOOLS_MERGE_REPLICATES` or raw HOMER/MACS2 peak files directly (when `params.run_merge_replicate_peaks` is `false`).
