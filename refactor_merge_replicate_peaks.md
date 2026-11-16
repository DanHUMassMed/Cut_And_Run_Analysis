# Plan: Transparent Merge-Ready Peak Outputs for `run_macs2_callpeak` and `run_homer_findpeaks`

## 1. Objective & Design Principle

**Principle:** Prioritize **transparency** over conserving disk space or lines of code.

Currently, `MACS2_CALLPEAK` (`run_macs2_callpeak`) emits `.narrowPeak`/`.broadPeak` files and `HOMER_FINDPEAKS` (`run_homer_findpeaks`) emits `pos2bed.pl` BED6 files with `#` comment headers. Format normalization (stripping headers and projecting columns 1–3) happens silently inside `BEDTOOLS_MERGE_REPLICATES` (`run_merge_replicate_peaks`). When inspecting `09_peaks/macs2/` or `09_peaks/homer/`, it is not immediately obvious what exact intervals are fed into `BEDTOOLS_MERGE_REPLICATES`.

This refactor makes each peak caller explicitly produce and publish a **standardized, merge-ready 3-column BED file** alongside its native outputs, so `09_peaks/macs2/` and `09_peaks/homer/` both contain a file that can be read directly into `BEDTOOLS_MERGE_REPLICATES`.

---

## 2. Standardized File Naming & Format

- **Chosen filename:** `<sample_id>_merge_ready_peaks.bed`
  - Published to:
    - `09_peaks/macs2/<sample_id>_merge_ready_peaks.bed`
    - `09_peaks/homer/<sample_id>_merge_ready_peaks.bed`
  - **Why this name:**
    - Self-documenting: clearly indicates the file is the exact input prepared for replicate merging.
    - Consistent with downstream naming (`<condition>_replicated_peaks.bed` in `10_merged_peaks/replicates/` and `<target>_master_peaks.bed` in `10_merged_peaks/master/`).
    - Avoids colliding with HOMER's native `<sample_id>_peaks.bed` (6-column `pos2bed.pl` output with `#` headers).
    - Ends in `.bed` for direct compatibility with `bedtools` and genome browsers (IGV/UCSC).

- **Guaranteed format specification (BED3):**
  - Headerless (no `#`, `track`, or `browser` lines).
  - Strictly 3 tab-separated columns: `chrom`, `start`, `end`.
  - Coordinate-sorted (`LC_ALL=C sort -k1,1 -k2,2n`).
  - Empty file (`0` bytes) if zero peaks were called (via `touch` / empty output).

---

## 3. Module Changes

### 3.1 `modules/local/macs2/callpeak/main.nf`
- **Keep all native outputs:** `*.{narrowPeak,broadPeak}`, `*.xls`, `*_summits.bed`, `*.gappedPeak`.
- **Add new output channel:**
  ```groovy
  tuple val(meta), path("${prefix}_merge_ready_peaks.bed"), emit: merge_ready_bed
  ```
- **In `script`:** After `macs2 callpeak`, explicitly convert the `.narrowPeak` or `.broadPeak` file into `${prefix}_merge_ready_peaks.bed`:
  ```bash
  awk 'BEGIN{OFS="\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print $1, $2, $3}' ${prefix}_peaks.*Peak | \
      LC_ALL=C sort -k1,1 -k2,2n > ${prefix}_merge_ready_peaks.bed
  ```
  *(Note: Uses `LC_ALL=C sort` rather than `bedtools sort` so no extra dependency is needed inside the MACS2 container.)*
- **In `stub`:** Add `touch ${prefix}_merge_ready_peaks.bed`.

### 3.2 `modules/local/homer/findpeaks/main.nf`
- **Keep all native outputs:** `${prefix}_peaks.txt` and `${prefix}_peaks.bed` (from `pos2bed.pl`).
- **Add new output channel:**
  ```groovy
  tuple val(meta), path("${prefix}_merge_ready_peaks.bed"), emit: merge_ready_bed
  ```
- **In `script`:** After `findPeaks` and `pos2bed.pl ${prefix}_peaks.txt > ${prefix}_peaks.bed`, explicitly strip HOMER `#` header lines and columns 4–6, and sort into `${prefix}_merge_ready_peaks.bed`:
  ```bash
  awk 'BEGIN{OFS="\t"} !/^#/ && !/^track/ && !/^browser/ && NF>=3 {print $1, $2, $3}' ${prefix}_peaks.bed | \
      LC_ALL=C sort -k1,1 -k2,2n > ${prefix}_merge_ready_peaks.bed
  ```
- **In `stub`:** Add `touch ${prefix}_merge_ready_peaks.bed`.

### 3.3 `modules/local/bedtools/merge_replicates/main.nf`
- Since both `MACS2_CALLPEAK` and `HOMER_FINDPEAKS` now emit clean, headerless, sorted 3-column `*_merge_ready_peaks.bed` files, `BEDTOOLS_MERGE_REPLICATES` no longer needs to silently normalize heterogeneous caller formats.
- Update the script to directly tag each BED3 interval with `FILENAME` for replicate counting:
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

---

## 4. Workflow, Config & Downstream Updates

### 4.1 `workflows/cutandrun.nf`
- Wire the merge-ready outputs into the active sample peak channels:
  - `ch_macs2_peaks = MACS2_CALLPEAK.out.merge_ready_bed`
  - `ch_homer_peaks = HOMER_FINDPEAKS.out.merge_ready_bed`
- `ch_active_sample_peaks` then passes `*_merge_ready_peaks.bed` directly into:
  - `BEDTOOLS_MERGE_REPLICATES` (when `params.run_merge_replicate_peaks` is `true`)
  - `BEDTOOLS_MERGE_MASTER` (when `params.run_merge_replicate_peaks` is `false`)
- Review `PLOT_PEAK_COUNTS` (`ch_all_peak_files`) so that passing `ch_macs2_peaks`, `ch_homer_peaks`, and `ch_active_sample_peaks` does not double-count samples.

### 4.2 `nextflow.config` & `main.nf`
- **`nextflow.config`:** Update `params.input_sample_peaks` default to:
  ```groovy
  input_sample_peaks = "${params.outdir}/09_peaks/${params.active_peak_caller}/*_merge_ready_peaks.bed"
  ```
- **`main.nf`:** Add `'_merge_ready_peaks.bed'` to the top of the suffix list in `resolveInputFiles(params.input_sample_peaks, samplesheet_map, [...])` while retaining `'_peaks.narrowPeak'`, `'_peaks.broadPeak'`, `'_peaks.bed'`, etc. as fallbacks for manually supplied files.

### 4.3 `bin/plot_peak_counts.py`
- Update `sample_suffixes` in `collect_peak_records()` and filename classification in `main()` to recognize `*_merge_ready_peaks.bed` (stripping `_merge_ready_peaks.bed` to resolve `sample_id` from the samplesheet).

### 4.4 `web/config_parser.py` & Documentation
- **`web/config_parser.py`:** Update the generated `input_sample_peaks` default string to `*_merge_ready_peaks.bed`.
- **`BEDTOOLS_MERGE_REPLICATES.md` & `docs/`:** Update references to document the explicit `*_merge_ready_peaks.bed` contract in `09_peaks/macs2/` and `09_peaks/homer/`.

---

## 5. Verification Plan

1. **Stub Run:** Execute `nextflow run main.nf -stub-run` (with both `run_macs2_callpeak = true` and `run_homer_findpeaks = true`) and verify that `09_peaks/macs2/<sample>_merge_ready_peaks.bed` and `09_peaks/homer/<sample>_merge_ready_peaks.bed` are created and wired into `BEDTOOLS_MERGE_REPLICATES`.
2. **Format & Count Validation:** On a real or test run, confirm:
   - Neither `*_merge_ready_peaks.bed` contains `#`, `track`, or `browser` lines.
   - Every line has exactly 3 tab-separated columns (`awk 'NF != 3'`).
   - Line counts of `<sample>_merge_ready_peaks.bed` match the data-line counts of `<sample>_peaks.narrowPeak`/`.broadPeak` (MACS2) and `<sample>_peaks.txt` / `<sample>_peaks.bed` (HOMER).
3. **Web Config Tests:** Run `pytest web/test_app.py` to confirm config parsing and generation remain valid.
