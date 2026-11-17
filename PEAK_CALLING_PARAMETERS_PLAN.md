# Peak Calling Discrepancy Discussion & Action Plan

## 1. Executive Summary & Root Cause Analysis

### 1.1 Observed Discrepancy (`peak_counts_summary.jpg`)
Across all samples in `cut_run103026B`, **MACS2** called drastically more peaks than **HOMER**, with the largest divergences occurring in the broad repressive histone mark (`H3K27me3`) and the `EV_INT_MC` sample:

| Target Mark | Biological Nature | Condition / Sample | MACS2 Peaks | HOMER Peaks | Fold Difference |
| :--- | :--- | :--- | ---: | ---: | ---: |
| **H3K27me3** | Broad repressive domain | `EV_INT` (`L9254-0001-0002_S142_L004`) | 4,008 | 291 | **13.8×** |
| **H3K27me3** | Broad repressive domain | `N2` (`L9254-0001-0005_S67_L008`) | 622 | 197 | **3.2×** |
| **H3K4me3** | Narrow active promoter | `EV_INT` (`L9254-0001-0001_S141_L004`) | 8,503 | 4,169 | **2.0×** |
| **H3K4me3** | Narrow active promoter | `N2` (`L9254-0001-0004_S66_L008`) | 5,953 | 3,173 | **1.9×** |
| **H3K4me3** | Narrow active promoter | `EV_INT_MC` (`L9254-0001-0006_S68_L008`) | 7,136 | 472 | **15.1×** |

### 1.2 Why the Pipeline Generated Identical Narrow-Mode Commands for All Samples
Inspecting [nextflow.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/nextflow.config#L47-L56) and [conf/modules.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/conf/modules.config#L21-L44) reveals the architectural root cause:

1. **Global Scalar Peak-Calling Parameters:**
   Currently, both peak callers are configured using static, experiment-wide scalar parameters in `nextflow.config`:
   - `params.macs2_qvalue = 0.01`, `params.macs2_broad = false`, `params.macs2_broad_cutoff = 0.1`
   - `params.homer_peak_style = 'factor'`
2. **No Per-Sample / Per-Target Parameter Dispatch:**
   In [conf/modules.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/conf/modules.config#L21-L44), `MACS2_CALLPEAK` and `HOMER_FINDPEAKS` build `ext.args` purely from `params.*` without inspecting the sample's `meta` map (`meta.target` or `meta.peak_mode`) coming from `samplesheet.csv`:
   ```groovy
   // Current conf/modules.config (lines 21-44)
   withName: 'MACS2_CALLPEAK' {
       ext.args = {
           [
               "-g ${params.macs2_gsize}",
               "-f ${params.macs2_format}",
               "-q ${params.macs2_qvalue}",
               params.macs2_broad ? "--broad --broad-cutoff ${params.macs2_broad_cutoff}" : ''
           ].findAll { it }.join(' ')
       }
   }

   withName: 'HOMER_FINDPEAKS' {
       ext.args = { "-style ${params.homer_peak_style}" }
   }
   ```
3. **Mixed Histone Marks in a Single Samplesheet:**
   Because [samplesheet.csv](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/docs/Example_Run/config/samplesheet.csv) contains **both** `H3K4me3` (a narrow promoter mark) and `H3K27me3` (a broad repressive domain mark) in the same run, a single global `params.macs2_broad` or `params.homer_peak_style` setting **cannot** properly configure both targets at once.
4. **ChIP-seq Defaults Applied to Ultra-Low Background CUT&RUN Data:**
   - **MACS2 Overcalling:** Running `macs2 callpeak -f BAMPE -q 0.01` without a control sample estimates local background noise ($\lambda_{\text{local}}$) from flanking windows. Because CUT&RUN has near-zero background compared to ChIP-seq, $\lambda_{\text{local}}$ is tiny and minor read fluctuations pass `-q 0.01`. Worse, running `H3K27me3` without `--broad` splits contiguous repressive domains into dozens of tiny narrow peaks.
   - **HOMER Undercalling:** Running `findPeaks -style factor` forces a narrow 175 bp window and a strict default 4-fold local enrichment requirement (`-F 4`), filtering out slightly broader CUT&RUN peaks and completely missing broad `H3K27me3` domains (which require `-style histone`).
5. **Unused `control_id` Metadata in `samplesheet.csv`:**
   Even though [samplesheet.csv](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/docs/Example_Run/config/samplesheet.csv) specifies `control_id` (`L9254-0001-0003_S143_L004`) for three samples and [lib/utils.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/lib/utils.nf#L228-L249) validates `control_id`, [workflows/cutandrun.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/workflows/cutandrun.nf#L43-L66) filters out all `IgG` samples before peak calling and never passes `-c` (MACS2) or `-i` (HOMER).

---

## 2. Using `samplesheet.csv` to Drive Peak-Calling Parameters

In Nextflow DSL2, every item entering `MACS2_CALLPEAK` (`tuple val(meta), path(bam), path(bai)`) and `HOMER_FINDPEAKS` (`tuple val(meta), path(tagdir)`) already carries the per-sample `meta` map parsed from `samplesheet.csv`. Inside `conf/modules.config`, `ext.args = { ... }` has direct access to `meta`.

There are two complementary ways to represent the peak-calling mode in `samplesheet.csv`:

### Option A (Recommended): Add an Explicit `peak_mode` Column to `samplesheet.csv`
Add a required column `peak_mode` (accepted values: `narrow` or `broad` for experimental targets; empty for `IgG` controls) to `samplesheet.csv`:

```csv
sample_id,sample_name,condition,target,peak_mode,replicate,control_id
L9254-0001-0001_S141_L004,EV_INT_H3K4me3,EV_INT_H3K4me3,H3K4me3,narrow,1,L9254-0001-0003_S143_L004
L9254-0001-0002_S142_L004,EV_INT_H3K27me3,EV_INT_H3K27me3,H3K27me3,broad,1,L9254-0001-0003_S143_L004
L9254-0001-0003_S143_L004,EV_INT_IgG,EV_INT_IgG,IgG,,1,
L9254-0001-0004_S66_L008,N2_H3K4me3,N2_H3K4me3,H3K4me3,narrow,1,
L9254-0001-0005_S67_L008,N2_H3K27me3,N2_H3K27me3,H3K27me3,broad,1,
L9254-0001-0006_S68_L008,EV_INT_MC_H3K4me3,EV_INT_MC_H3K4me3,H3K4me3,narrow,1,L9254-0001-0003_S143_L004
```

**Why Option A is best:**
- **Single Source of Truth:** Matches the design philosophy in [SAMPLESHEET_VALIDATION_PLAN.md](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/SAMPLESHEET_VALIDATION_PLAN.md)—all sample/target biological behavior lives directly in `samplesheet.csv` with zero guesswork.
- **Works for Any Novel Target/TF:** If a future experiment profiles a new transcription factor, histone variant, or custom antibody, the user simply sets `narrow` or `broad` in `samplesheet.csv` without editing Groovy code.
- **Cross-Row Consistency Validation:** `lib/utils.nf` can enforce that all rows sharing the same `target` also share the same `peak_mode` (preventing a user from accidentally marking one `H3K27me3` sample `narrow` and another `broad`).

### Option B (Alternative / Fallback): Infer from `target` Column via Config Map
Keep the current 6-column `samplesheet.csv` and map `meta.target` (`H3K4me3` -> `narrow`, `H3K27me3` -> `broad`) via a `params.target_peak_modes` map in `nextflow.config` / `experiment.config`, failing at startup if a non-IgG `target` in `samplesheet.csv` is not present in the map.

> **Recommendation:** Use **Option A (`peak_mode` column in `samplesheet.csv`)** as the primary mechanism, and have the Web Control Center UI auto-select `narrow` or `broad` when the user types known marks like `H3K4me3` (`narrow`) or `H3K27me3` (`broad`).

---

## 3. Target-Specific Commands & Parameter Design

### 3.1 Target Commands by `peak_mode`

| Mode | Example Target | MACS2 Command (`MACS2_CALLPEAK`) | HOMER Command (`HOMER_FINDPEAKS`) |
| :--- | :--- | :--- | :--- |
| **`narrow`** | `H3K4me3`, TFs | `macs2 callpeak -t <bam> -n <id> -g ce -f BAM -p 1e-5` | `findPeaks <tagdir> -style factor -F 2 -o <id>_peaks.txt` |
| **`broad`** | `H3K27me3` | `macs2 callpeak -t <bam> -n <id> -g ce -f BAM --broad --broad-cutoff 0.05` | `findPeaks <tagdir> -style histone -F 2 -o <id>_peaks.txt` |

### 3.2 Proposed Parameters in `nextflow.config` & `experiment.config`
Replace the single global `macs2_broad` / `homer_peak_style` toggles with mode-specific parameters that `conf/modules.config` selects based on `meta.peak_mode`, and change the default `macs2_format` from `'BAMPE'` to `'BAM'`:

```groovy
    // Step c: MACS2 parameters (dispatched per sample via meta.peak_mode from samplesheet.csv)
    macs2_gsize                    = 'ce'                    // hs, mm, ce, dm, or numeric size
    macs2_format                   = 'BAM'                   // Single-end / standard BAM format
    macs2_narrow_pvalue            = 1e-5                    // Strict p-value cutoff for narrow marks in CUT&RUN (set null to use macs2_narrow_qvalue)
    macs2_narrow_qvalue            = 0.01                    // Fallback q-value when macs2_narrow_pvalue is null
    macs2_broad_cutoff             = 0.05                    // --broad-cutoff for broad marks (e.g. H3K27me3)

    // Step c: HOMER findPeaks parameters (dispatched per sample via meta.peak_mode from samplesheet.csv)
    homer_narrow_style             = 'factor'                // -style for narrow marks
    homer_broad_style              = 'histone'               // -style for broad marks
    homer_fold_enrichment          = 2                       // -F fold enrichment over local background (HOMER default is 4)
    homer_local_fold               = null                    // Optional -L local fold filter (e.g., 2 or 0; null uses HOMER default)
```

### 3.3 Dynamic `ext.args` Resolution in `conf/modules.config`

```groovy
    withName: 'MACS2_CALLPEAK' {
        ext.args = {
            def is_broad = (meta.peak_mode == 'broad')
            def threshold_arg = is_broad
                ? "--broad --broad-cutoff ${params.macs2_broad_cutoff}"
                : (params.macs2_narrow_pvalue
                    ? "-p ${params.macs2_narrow_pvalue}"
                    : "-q ${params.macs2_narrow_qvalue}")
            [
                "-g ${params.macs2_gsize}",
                "-f ${params.macs2_format}",
                threshold_arg
            ].findAll { it }.join(' ')
        }
        publishDir = [
            path: { "${params.outdir}/09_peaks/macs2" },
            mode: params.publish_dir_mode,
            saveAs: { filename -> filename.equals('versions.yml') ? null : filename }
        ]
    }

    withName: 'HOMER_FINDPEAKS' {
        ext.args = {
            def style = (meta.peak_mode == 'broad')
                ? params.homer_broad_style
                : params.homer_narrow_style
            [
                "-style ${style}",
                params.homer_fold_enrichment != null ? "-F ${params.homer_fold_enrichment}" : '',
                params.homer_local_fold != null ? "-L ${params.homer_local_fold}" : ''
            ].findAll { it }.join(' ')
        }
        publishDir = [
            path: { "${params.outdir}/09_peaks/homer" },
            mode: params.publish_dir_mode,
            saveAs: { filename -> filename.equals('versions.yml') ? null : filename }
        ]
    }
```

### 3.4 Downstream Compatibility Check
- **`MACS2_CALLPEAK` ([modules/local/macs2/callpeak/main.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/modules/local/macs2/callpeak/main.nf#L34-L45)):**
  Already inspects `args.contains('--broad')` to choose between `${prefix}_peaks.broadPeak` and `${prefix}_peaks.narrowPeak` when generating `${prefix}_macs2_merge_ready_peaks.bed`! No changes are required in `MACS2_CALLPEAK/main.nf` for mixed narrow/broad runs.
- **`HOMER_FINDPEAKS` ([modules/local/homer/findpeaks/main.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/modules/local/homer/findpeaks/main.nf#L35-L44)):**
  When `-style histone` is passed to `findPeaks` with `-o ${prefix}_peaks.txt`, HOMER writes the region calls to `${prefix}_peaks.txt`, and `pos2bed.pl` converts them to `${prefix}_peaks.bed` identically to `-style factor`.
- **Step h (`HOMER_FINDMOTIFSGENOME` & `MEME_STREME`):**
  Note that for broad histone marks (`H3K27me3`), motif discovery with a fixed 100 bp window around peak centers is less biologically meaningful than for narrow marks, or may benefit from `-size given` in HOMER if desired.

---

## 4. Deferred Phase: `control_id` (IgG) Handling

Addressing `control_id` (IgG) usage during peak calling is **deferred until after the `peak_mode` (`narrow` vs. `broad`) and parameter updates are implemented and verified**:
- In [docs/Example_Run/config/samplesheet.csv](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/docs/Example_Run/config/samplesheet.csv), `EV_INT_H3K4me3`, `EV_INT_H3K27me3`, and `EV_INT_MC_H3K4me3` specify `control_id = L9254-0001-0003_S143_L004` (`EV_INT_IgG`), while `N2_H3K4me3` and `N2_H3K27me3` have an empty `control_id`.
- Currently, [workflows/cutandrun.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/workflows/cutandrun.nf#L43-L66) filters out IgG samples (`!isControlTarget(meta)`) and runs `MACS2_CALLPEAK` and `HOMER_FINDPEAKS` without passing `-c <control.bam>` or `-i <control_tagdir>`.
- Once the `peak_mode` and `macs2_format = 'BAM'` updates are complete, we will revisit how `control_id` should be handled in a dedicated follow-up step.

---

## 5. Step-by-Step Implementation Plan

When you are ready to apply these changes, here is the ordered implementation plan across the repository:

### Step 1: Update `samplesheet.csv` Schema & Validation (`lib/utils.nf`)
1. Add `peak_mode` to `required_columns` in [lib/utils.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/lib/utils.nf#L21-L30) (`parseSamplesheetRows`).
2. In `validateSamplesheetRows` ([lib/utils.nf](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/lib/utils.nf#L110-L288)):
   - Require `peak_mode` to be `'narrow'` or `'broad'` (case-insensitive, normalized to lowercase) for all non-IgG rows.
   - Allow `peak_mode` to be empty (or `'control'`) for `IgG` rows.
   - Validate that all rows with the same `target` specify the same `peak_mode` (e.g., `H3K4me3` cannot be `'narrow'` on one row and `'broad'` on another).
   - Store `peak_mode` on each sample's `meta` map (`meta.peak_mode`).
3. Update [docs/Example_Run/config/samplesheet.csv](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/docs/Example_Run/config/samplesheet.csv) (and any active `Analysis_Run/config/samplesheet.csv`) with `peak_mode` (`narrow` for `H3K4me3`, `broad` for `H3K27me3`).

### Step 2: Update Pipeline Configuration (`nextflow.config`, `conf/modules.config`, `experiment.config`)
1. In [nextflow.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/nextflow.config#L47-L56) and [docs/Example_Run/config/experiment.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/docs/Example_Run/config/experiment.config#L44-L53):
   - Set `macs2_format = 'BAM'` (updated from `'BAMPE'`).
   - Add `macs2_narrow_pvalue = 1e-5`, `macs2_narrow_qvalue = 0.01`, `macs2_broad_cutoff = 0.05`.
   - Add `homer_narrow_style = 'factor'`, `homer_broad_style = 'histone'`, `homer_fold_enrichment = 2`, `homer_local_fold = null`.
2. In [conf/modules.config](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/conf/modules.config#L21-L44):
   - Update `withName: 'MACS2_CALLPEAK'` and `withName: 'HOMER_FINDPEAKS'` `ext.args` closures to branch on `meta.peak_mode`.

### Step 3: Update Python Plotting Utilities & Web Control Center (`bin/` & `web/`)
1. **[bin/cutandrun_plot_utils.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/bin/cutandrun_plot_utils.py#L57-L67):**
   - Add `peak_mode: str | None = None` to `SampleMetadata` and validate `peak_mode` (`narrow` | `broad`) for non-IgG rows in `load_samplesheet()`.
2. **Web Control Center ([web/models.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/models.py), [web/config_parser.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/config_parser.py), [web/repositories.py](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/repositories.py), [web/static/js/samplesheet.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/samplesheet.js), [web/static/js/config.js](file:///Users/dan/Code/NextFlow/Arjamand/Cut_And_Run_Analysis/web/static/js/config.js)):**
   - Change default `macs2_format` to `'BAM'` in `Macs2Settings` / `ExperimentConfigModel` and `web/static/js/config.js`.
   - Add `peak_mode` dropdown (`narrow` / `broad`) to the Samplesheet table in the Web UI (auto-populating `broad` when target contains `H3K27me3`, `H3K9me3`, or `H3K36me3`, and `narrow` otherwise).
   - Update `Macs2Settings` and `HomerSettings` in `web/models.py` and `web/config_parser.py` to expose the narrow/broad thresholds (`macs2_narrow_pvalue`, `macs2_broad_cutoff`, `homer_fold_enrichment`).
   - Run `make test` and `make lint` to verify all backend/frontend tests pass.

### Step 4: Verification & Visual QC in IGV
1. Run `nextflow run main.nf -stub-run` to verify channel wiring and command generation.
2. Execute `MACS2_CALLPEAK`, `HOMER_FINDPEAKS`, and `PLOT_PEAK_COUNTS` on `cut_run103026B`.
3. Inspect the updated `peak_counts_summary.png` and `04_signal_distributions` peak-width violin plots to verify:
   - `H3K27me3` peaks are called as broad domains (hundreds to thousands of bp wide) with converged counts between MACS2 and HOMER.
   - `H3K4me3` false-positive micro-peaks in MACS2 are suppressed by `-p 1e-5` while true promoter peaks in HOMER are retained by `-F 2`.
4. Load the `.bam` / `.bw` tracks alongside `09_peaks/macs2/*.{narrowPeak,broadPeak}` and `09_peaks/homer/*_peaks.bed` in IGV to confirm visual concordance at representative loci.
