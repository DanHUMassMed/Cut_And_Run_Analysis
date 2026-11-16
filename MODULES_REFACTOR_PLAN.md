# `modules/local` Refactoring Plan

## Goal
Reorganize `modules/local/` from flat `<tool>_<action>/` directories into a two-level `<tool>/<action>/` hierarchy matching nf-core module conventions (e.g. `bedtools/merge_master/`, `homer/annotatepeaks/`).

---

## Proposed `modules/local` Structure

| Current Path | Proposed Path | Tool | Action | Files |
| :--- | :--- | :--- | :--- | :--- |
| `modules/local/bedtools_merge_master/` | `modules/local/bedtools/merge_master/` | `bedtools` | `merge_master` | `main.nf`, `environment.yml` |
| `modules/local/bedtools_merge_replicates/` | `modules/local/bedtools/merge_replicates/` | `bedtools` | `merge_replicates` | `main.nf`, `environment.yml` |
| `modules/local/deeptools_metapeak/` | `modules/local/deeptools/metapeak/` | `deeptools` | `metapeak` | `main.nf`, `environment.yml` |
| `modules/local/homer_annotatepeaks/` | `modules/local/homer/annotatepeaks/` | `homer` | `annotatepeaks` | `main.nf`, `environment.yml` |
| `modules/local/homer_findmotifsgenome/` | `modules/local/homer/findmotifsgenome/` | `homer` | `findmotifsgenome` | `main.nf`, `environment.yml` |
| `modules/local/homer_findpeaks/` | `modules/local/homer/findpeaks/` | `homer` | `findpeaks` | `main.nf`, `environment.yml` |
| `modules/local/homer_getdifferentialpeaks/` | `modules/local/homer/getdifferentialpeaks/` | `homer` | `getdifferentialpeaks` | `main.nf`, `environment.yml` |
| `modules/local/macs2_callpeak/` | `modules/local/macs2/callpeak/` | `macs2` | `callpeak` | `main.nf`, `environment.yml` |
| `modules/local/meme_streme/` | `modules/local/meme/streme/` | `meme` | `streme` | `main.nf`, `environment.yml` |
| `modules/local/plot_annotated_summary/` | `modules/local/python/plot_annotated_summary/` | `python` | `plot_annotated_summary` | `main.nf`, `environment.yml` |
| `modules/local/plot_differential_volcano_ma/` | `modules/local/python/plot_differential_volcano_ma/` | `python` | `plot_differential_volcano_ma` | `main.nf`, `environment.yml` |
| `modules/local/plot_peak_counts/` | `modules/local/python/plot_peak_counts/` | `python` | `plot_peak_counts` | `main.nf`, `environment.yml` |

### Resulting Directory Tree
```text
modules/local/
├── bedtools/
│   ├── merge_master/
│   └── merge_replicates/
├── deeptools/
│   └── metapeak/
├── homer/
│   ├── annotatepeaks/
│   ├── findmotifsgenome/
│   ├── findpeaks/
│   └── getdifferentialpeaks/
├── macs2/
│   └── callpeak/
├── meme/
│   └── streme/
└── python/
    ├── plot_annotated_summary/
    ├── plot_differential_volcano_ma/
    └── plot_peak_counts/
```

---

## Execution Steps (Upon Approval)

1. **Move Module Directories**
   - Use `git mv` (or `mkdir -p` + `mv` for untracked directories) to relocate all 12 directories from `modules/local/<tool>_<action>/` to `modules/local/<tool>/<action>/`.
   - Each module keeps its `main.nf` and `environment.yml` intact (`${moduleDir}/environment.yml` resolves automatically).
   - Process names (e.g., `BEDTOOLS_MERGE_MASTER`, `HOMER_ANNOTATEPEAKS`, `PLOT_PEAK_COUNTS`) remain unchanged, so `conf/modules.config` requires no edits.

2. **Update Workflow Imports**
   - Update the 12 `include` statements in `workflows/cutandrun.nf` (lines 6–17) to point to `../modules/local/<tool>/<action>/main`.

3. **Update Documentation References**
   - Update module path references in:
     - `docs/MAKING_METAPEAK_PLOTS.md` (lines 9, 54)
     - `docs/USERS_GUIDE.md` (lines 193, 219, 241, 263, 309, 338, 363, 397, 417)

4. **Verification**
   - Run `nextflow run main.nf -stub-run` (or `nextflow inspect` / pipeline lint) to confirm all module imports resolve cleanly without syntax or path errors.
