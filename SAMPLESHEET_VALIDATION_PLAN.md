# Plan: End-to-End Samplesheet Validation & Single Source of Truth

## 1. Objective & Core Design Principles

1. **Samplesheet as Single Source of Truth (SSOT):**
   Every sample, condition, target (histone mark / TF), and control relationship in the pipeline must originate from `samplesheet.csv`.
2. **Zero Silent Fallbacks:**
   Eliminate all `?: 'default'`, `?: meta.id`, `?: 'Treatment'`, and `?: ''` fallbacks across `lib/utils.nf`, `main.nf`, `workflows/cutandrun.nf`, modules, and Python plotting scripts.
3. **Fail Fast with Actionable, Aggregated Error Messages:**
   Validate the entire samplesheet, `diff_contrasts`, and active input channels at pipeline startup—before launching any container jobs—and report **all** violations in a single formatted error block with CSV line numbers, column names, and how to fix them.
4. **Clean, Easy-to-Understand Code:**
   Centralize parsing and validation in `lib/utils.nf` with small, single-purpose functions so `main.nf` and `workflows/cutandrun.nf` stay declarative and free of defensive boilerplate.

---

## 2. Samplesheet Schema & Invariants

### 2.1 Required Columns
`samplesheet.csv` must have a header row containing all 6 columns:

| Column | Required? | Type / Format | Meaning & Pipeline Usage |
| :--- | :--- | :--- | :--- |
| `sample_id` | **Required** | Safe ID (`^[A-Za-z0-9._-]+$`) | Matches input BAM, TagDir, BigWig, and per-sample peak filenames |
| `sample_name` | **Required** | Non-empty string (no whitespace/control chars) | Human-readable label in `deepTools` heatmaps and summary QC plots |
| `condition` | **Required** | Safe ID (`^[A-Za-z0-9._-]+$`) | Groups biological replicates; prefix for `<condition>_replicated_peaks.bed` |
| `target` | **Required** | Safe ID (`^[A-Za-z0-9._-]+$`), not `'default'` | Groups conditions by antibody/mark; prefix for `<target>_master_peaks.bed` |
| `replicate` | **Required** | Positive integer (`>= 1`) | Replicate index within `(condition, target)` |
| `control_id` | Optional | Empty or valid `sample_id` in sheet | Optional negative control (`IgG`) `sample_id` |

---

## 3. Comprehensive Edge Cases to Catch

### 3.1 File & Header Edge Cases
1. **Missing or unset `params.samplesheet`:** Currently returns `[:]` silently. Must fail immediately with the expected path.
2. **Empty file or header-only CSV:** Must fail if 0 data rows exist.
3. **UTF-8 BOM (`\uFEFF`) or trailing spaces in column headers:** Excel exports often prepend a BOM to `sample_id` (`\uFEFFsample_id`), causing `row.sample_id` to evaluate to `null` on every row. Strip BOM and whitespace from headers.
4. **Missing or misspelled column headers:** e.g., `Target` instead of `target` or missing `condition`. Validate header names before row iteration.
5. **Blank lines in CSV:** Ignore completely blank lines, but fail if a partially filled row is missing required columns.

### 3.2 Row-Level Edge Cases (with CSV Line Numbers)
1. **Missing `sample_id`, `sample_name`, `condition`, `target`, or `replicate`:** Previously silently skipped (`if (row.sample_id)`) or defaulted to `'default'` / `1`. Must report the exact CSV line number (`line = row_index + 2`) and missing column(s).
2. **Literal `'default'` used as `target` or `condition`:** Reject `'default'` (case-insensitive) so leftover placeholder values never masquerade as real biological metadata.
3. **Unsafe characters in `sample_id`, `condition`, or `target`:** Since these values become output filenames (`${condition}_replicated_peaks.bed`, `${target}_master_peaks.bed`) and shell arguments (`--samplesLabel`), reject spaces, slashes (`/`, `\`), quotes, and shell metacharacters.
4. **Non-integer or `<= 0` `replicate`:** Previously `row.replicate.toInteger()` threw an unhandled Groovy stack trace on values like `rep1` or `0`. Catch and report a friendly error with the row number.

### 3.3 Cross-Row / Relational Edge Cases
1. **Duplicate `sample_id`:** Previously `meta_map[row.sample_id] = ...` silently overwrote earlier rows. Track seen IDs and report both line numbers.
2. **Duplicate `sample_name` within the same `target`:** Causes colliding labels in `deepTools plotHeatmap --samplesLabel` and PCA/correlation plots.
3. **Duplicate `(condition, replicate)` pair:** Two samples in the same condition claiming the same replicate number (e.g., two `rep 1` rows for `EV_INT_H3K4me3`).
4. **One `condition` mapped to multiple `target`s (Critical Bug Prevention):**
   - In `main.nf` (`condition_to_target[meta.condition] = meta.target`), `BEDTOOLS_MERGE_REPLICATES` (`[id: meta.condition, ...]`), and `HOMER_GETDIFFERENTIALPEAKS` (`ch_tagdirs_by_condition` keyed by `meta.condition`), each `condition` is assumed to belong to **exactly one `target`**.
   - If a user names a condition `N2` under both `H3K4me3` and `H3K27me3` (instead of `N2_H3K4me3` and `N2_H3K27me3`), `BEDTOOLS_MERGE_REPLICATES` overwrites `N2_replicated_peaks.bed` and `HOMER_GETDIFFERENTIALPEAKS` mixes `H3K4me3` and `H3K27me3` tag directories together.
   - **Rule:** Enforce a strict 1-to-1 mapping from `condition -> target`. If a `condition` appears with two different `target` values, fail and instruct the user to include the target in the condition name (e.g., `N2_H3K4me3`).
5. **Invalid `control_id` references:**
   - `control_id == sample_id` (self-reference).
   - `control_id` does not exist as a `sample_id` in `samplesheet.csv`.
   - `control_id` points to a sample whose `target` is not `IgG` (case-insensitive).
   - An `IgG` sample itself specifies a `control_id`.
6. **No non-IgG experimental samples:** If every row in `samplesheet.csv` has `target == 'IgG'`, all downstream channels filter to empty. Fail upfront.

---

## 4. Addressing All Pipeline Boundary Exceptions

Earlier we identified four places in `main.nf` and `workflows/cutandrun.nf` that bypassed `samplesheet_map` or only validated in one direction. Here is how each will be fixed:

### Exception 1: Pre-existing Replicated Peaks (`ch_existing_replicated_peaks`)
- **Current behavior (`main.nf:127-133`):**
  Extracts `condition_id` from filename and does `condition_to_target[condition_id] ?: 'default'`.
- **New behavior:**
  1. Resolve `ch_existing_replicated_peaks` unconditionally in `main.nf` via `resolveConditionFiles(...)` (keeping `main.nf` flat and free of `params.run_*` checks, with step toggles evaluated downstream in `workflows/cutandrun.nf`).
  2. Look up `condition_id` via `buildConditionMeta(condition_id, samplesheet_context)`.
  3. If `condition_id` is not a known condition in `samplesheet.csv`, fail immediately listing the unrecognized file, the extracted `condition_id`, and the valid conditions from `samplesheet.csv`.

### Exception 2: Pre-existing Master Peaks & Annotated Peaks (`ch_existing_master_peaks`, `ch_existing_annotated_peaks`)
- **Current behavior (`main.nf:138-153`):**
  Extracts `target_name` from `<target>_master_peaks.bed` or `<target>_annotated_peaks.txt` and builds `[id: target_name, target: target_name]` without checking `samplesheet.csv`.
- **New behavior:**
  1. Resolve `ch_existing_master_peaks` and `ch_existing_annotated_peaks` unconditionally in `main.nf` via `resolveTargetFiles(...)`.
  2. Validate `target_name` via `buildTargetMeta(target_name, samplesheet_context)`. If `target_name` is not in the set of non-IgG targets from `samplesheet.csv`, fail with a clear message showing the valid targets.

### Exception 3: Differential Contrasts (`params.diff_contrasts` & `ch_existing_diff_peaks`)
- **Current behavior (`main.nf:158-178`, `workflows/cutandrun.nf:163-200`):**
  `params.diff_contrasts` is not validated against `samplesheet.csv`. A typo in `treatment`, `background`, or `target` causes `.combine(..., by: 0)` in `cutandrun.nf` to silently emit 0 items. Missing `target` falls back to `'default'`.
- **New behavior (`validateDiffContrasts` in `lib/utils.nf`):**
  1. Verify every contrast entry has non-empty `id`, `treatment`, `background`, and `target`.
  2. Verify contrast `id` values are unique and filename-safe.
  3. Verify `treatment != background`.
  4. Verify `contrast.target` exists in `samplesheet.csv` (as a non-IgG target).
  5. Verify `contrast.treatment` and `contrast.background` both exist as conditions in `samplesheet.csv`.
  6. Verify that both `treatment` and `background` belong to `contrast.target` (or `IgG` for `background`) in `samplesheet.csv`.
  7. In `ch_existing_diff_peaks`, validate `contrast_id` against `contrast_map` via `resolveContrastFiles(...)` instead of defaulting to `'Treatment'` / `'Background'`.

### Exception 4: Bidirectional Completeness Check for Input Files
- **Current problems:**
  If a sample is listed in `samplesheet.csv` (e.g., 6 samples), but only 4 BAMs, TagDirs, or BigWigs exist in `input_dir`, Nextflow silently runs with 4 samples and never warns that 2 samples from `samplesheet.csv` were missing on disk.
- **New behavior:**
  - **Keep `main.nf` unconditional:** Channel creation in `main.nf` never branches on `params.run_*` step toggles; step toggles are checked exclusively inside `workflows/cutandrun.nf`.
  - **Two-way verification (Files <-> Samplesheet):**
    - **File -> Samplesheet (`buildMeta`):** Every matched file must map to a `sample_id` (or `condition` / `target` / `contrast_id`) in `samplesheet.csv`.
    - **Samplesheet -> Files (`expectedIds`):** For primary Dropbox inputs (`ch_bam_bai`, `ch_tagdirs`, `ch_bigwig`), verify that every expected non-IgG sample in `samplesheet.csv` has a corresponding non-empty input file on disk. If any sample in `samplesheet.csv` is missing its input file, fail at startup with the exact missing sample IDs and expected directory.

---

## 5. Proposed Code Architecture

### 5.1 `lib/utils.nf` — Clean Separation of Parsing and Validation

```groovy
// 1. Parse raw CSV rows (preserving line numbers and checking header columns)
def parseSamplesheetRows(samplesheet_path)

// 2. Validate all row-level and cross-row rules; throw formatted error if any fail
def validateSamplesheetRows(rows, samplesheet_path)

// 3. Public entrypoint returning a structured context map:
//    [
//      samples            : Map<String, Map>, // sample_id -> meta
//      condition_to_target: Map<String, String>, // condition -> target (non-IgG & IgG)
//      targets            : Set<String>,      // non-IgG targets
//      conditions         : Set<String>       // all valid conditions
//    ]
def loadAndValidateSamplesheet(samplesheet_path)

// 4. Validate diff_contrasts against the validated samplesheet context
def validateDiffContrasts(diff_contrasts, sheet_ctx)

// 5. Strict metadata builders (no 'default' fallbacks)
def buildMeta(sample_id, sheet_ctx, source_label = 'file')
def buildConditionMeta(condition_id, sheet_ctx, source_label = 'replicated peak file')
def buildTargetMeta(target_name, sheet_ctx, source_label = 'master/annotated peak file')
def isControlTarget(meta)
```

### 5.2 Example Error Message Format
When validation fails, the user gets one clear, scannable block:

```text
========================================================================
 SAMPLESHEET VALIDATION FAILED
 File: /path/to/config/samplesheet.csv
------------------------------------------------------------------------
  - [Line 3] Column 'target' is empty for sample_id 'L9254-0001-0002_S142_L004'. Every row must specify a target (e.g., H3K4me3, H3K27me3, IgG).
  - [Line 5] Invalid replicate 'rep1' for sample_id 'L9254-0001-0004_S66_L008'. 'replicate' must be a positive integer (1, 2, ...).
  - [Line 6] Duplicate sample_id 'L9254-0001-0001_S141_L004' (first seen on Line 2).
  - [Line 7] Condition 'N2' is assigned to multiple targets ('H3K4me3' on Line 5, 'H3K27me3' on Line 7). Each condition must belong to a single target (e.g., 'N2_H3K4me3', 'N2_H3K27me3').
  - [Line 8] Unknown control_id 'MISSING_IGG_ID' for sample_id 'L9254-0001-0006_S68_L008'. Not found in sample_id column.
========================================================================
```

### 5.3 Simplifications in `workflows/cutandrun.nf`
Once `main.nf` validates inputs through `sheet_ctx`:
- Replace all 6 occurrences of `meta.target?.toLowerCase() != 'igg'` with `!isControlTarget(meta)`.
- Replace all `meta.target ?: 'default'` and `meta.target ?: meta.id` with `meta.target`:
  - Line 97 (`BEDTOOLS_MERGE_REPLICATES`): `[ [ id: meta.condition, condition: meta.condition, target: meta.target ], bed ]`
  - Line 120 (`BEDTOOLS_MERGE_MASTER`): `[ [ id: meta.target, target: meta.target ], bed ]`
  - Line 133 (`ch_master_by_target`): `[ meta.target, meta, bed ]`
  - Line 143 (`ch_tagdirs_by_target`): `[ meta.target, tagdir ]`
  - Lines 178 & 187 (`HOMER_GETDIFFERENTIALPEAKS`): `contrast.target`
  - Line 211 (`DEEPTOOLS_METAPEAK`): `[ meta.target, [ meta.sample_name, bw ] ]`

### 5.4 Alignment in Python Plotting Scripts (`bin/`) & Web Control Center (`web/`)
- **`bin/cutandrun_plot_utils.py` & `bin/plot_peak_counts.py`:**
  Remove `"default"` fallbacks in `load_samplesheet()` and `collect_peak_records()`; raise a clear `ValueError` if required columns (`sample_id`, `sample_name`, `condition`, `target`, `replicate`) are missing or unmapped.
- **`web/services/preflight.py` (Optional Enhancement):**
  Add a `SamplesheetValidationCheck` to `DEFAULT_PREFLIGHT_CHECKS` so the Web GUI pre-flight panel catches and displays these exact same samplesheet errors before the user even clicks "Run Pipeline".

---

## 6. Step-by-Step Implementation Order

1. **`lib/utils.nf`:** Implement `parseSamplesheetRows()`, `validateSamplesheetRows()`, `loadAndValidateSamplesheet()`, `validateDiffContrasts()`, `verifyExpectedInputs()`, `buildMeta()`, `buildConditionMeta()`, `buildTargetMeta()`, and `isControlTarget()`.
2. **`main.nf`:**
   - Replace `loadSamplesheetMap()` with `loadAndValidateSamplesheet(params.samplesheet)`.
   - Call `validateDiffContrasts()` when differential peaks or summary plots are active.
   - Gate `ch_existing_*` fallback channels behind their step toggles and use `buildConditionMeta()` / `buildTargetMeta()`.
   - Verify expected sample inputs exist on disk for active steps.
3. **`workflows/cutandrun.nf` & `modules/local/`:**
   - Remove all `?: 'default'` and `?: meta.id` fallbacks; use `meta.target` and `meta.sample_name` directly.
4. **`bin/cutandrun_plot_utils.py` & `bin/plot_peak_counts.py`:**
   - Enforce strict samplesheet parsing without `"default"` fallbacks.
5. **Verification:**
   - Test with valid `docs/Example_Run/config/samplesheet.csv`.
   - Test failure modes (missing `target`, duplicate `sample_id`, shared `condition` across targets, invalid `control_id`, bad `diff_contrasts`) to confirm clear error messages.
