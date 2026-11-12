import { apiFetch } from './api.js';
import { appState } from './state.js';
import { setButtonState, showToast } from './ui.js';
import { renderContrasts } from './contrasts.js';

const STRING_FIELDS = [
  ['cfg_email', 'email', ''],
  ['cfg_experiment', 'experiment', ''],
  ['cfg_input_dir', 'input_dir', ''],
  ['cfg_bigwig_source', 'bigwig_source', 'deepTools'],
  ['cfg_active_peak_caller', 'active_peak_caller', 'macs2'],
  ['cfg_genome_name', 'genome_name', 'ce11'],
  ['cfg_homer_dir', 'homer_dir', ''],
  ['cfg_genome_fasta', 'genome_fasta', ''],
  ['cfg_chrom_sizes', 'chrom_sizes', ''],
  ['cfg_macs2_gsize', 'macs2_gsize', 'ce'],
  ['cfg_macs2_format', 'macs2_format', 'BAMPE'],
  ['cfg_homer_peak_style', 'homer_peak_style', 'factor'],
  ['cfg_annotatepeaks_size', 'annotatepeaks_size', 'given'],
  ['cfg_metapeak_reference_point', 'metapeak_reference_point', 'center'],
  ['cfg_heatmap_colormap', 'heatmap_colormap', 'inferno'],
  ['cfg_heatmap_interpolation', 'heatmap_interpolation', 'nearest'],
  ['cfg_homer_motif_size', 'homer_motif_size', '100'],
];

const NUMBER_FIELDS = [
  ['cfg_min_replicate_overlap', 'min_replicate_overlap', 2, 'int'],
  ['cfg_resource_cpus', 'resource_cpus', 8, 'int'],
  ['cfg_macs2_qvalue', 'macs2_qvalue', 0.01, 'float'],
  ['cfg_macs2_broad_cutoff', 'macs2_broad_cutoff', 0.1, 'float'],
  ['cfg_metapeak_upstream', 'metapeak_upstream', 2000, 'int'],
  ['cfg_metapeak_downstream', 'metapeak_downstream', 2000, 'int'],
  ['cfg_meme_slop_left', 'meme_slop_left', 50, 'int'],
  ['cfg_meme_slop_right', 'meme_slop_right', 49, 'int'],
  ['cfg_meme_streme_nmotifs', 'meme_streme_nmotifs', 20, 'int'],
  ['cfg_volcano_fdr_threshold', 'volcano_fdr_threshold', 0.05, 'float'],
  ['cfg_volcano_log2fc_threshold', 'volcano_log2fc_threshold', 1.0, 'float'],
  ['cfg_volcano_top_n_labels', 'volcano_top_n_labels', 12, 'int'],
];

const UNIT_FIELDS = [
  {
    valueId: 'cfg_resource_memory_value',
    unitId: 'cfg_resource_memory_unit',
    key: 'resource_memory',
    fallback: '16.GB',
    uppercaseUnit: true,
  },
  {
    valueId: 'cfg_resource_time_value',
    unitId: 'cfg_resource_time_unit',
    key: 'resource_time',
    fallback: '72.h',
    uppercaseUnit: false,
  },
];

function splitValueAndUnit(raw, fallback, uppercaseUnit) {
  const text = String(raw ?? fallback).trim();
  const match = text.match(/^(\d+(?:\.\d+)?)\s*\.?\s*([A-Za-z]+)$/);
  if (match) {
    const unit = uppercaseUnit ? match[2].toUpperCase() : match[2].toLowerCase();
    return { amount: match[1], unit };
  }
  if (raw !== fallback) {
    return splitValueAndUnit(fallback, fallback, uppercaseUnit);
  }
  return { amount: '1', unit: '' };
}

const BOOL_FIELDS = [
  ['cfg_run_macs2_callpeak', 'run_macs2_callpeak'],
  ['cfg_run_homer_findpeaks', 'run_homer_findpeaks'],
  ['cfg_run_merge_replicate_peaks', 'run_merge_replicate_peaks'],
  ['cfg_run_merge_master_peaks', 'run_merge_master_peaks'],
  ['cfg_run_homer_annotatepeaks', 'run_homer_annotatepeaks'],
  ['cfg_run_homer_diffpeaks', 'run_homer_diffpeaks'],
  ['cfg_run_deeptools_metapeak', 'run_deeptools_metapeak'],
  ['cfg_run_homer_findmotifs', 'run_homer_findmotifs'],
  ['cfg_run_meme_streme', 'run_meme_streme'],
  ['cfg_run_summary_plots', 'run_summary_plots'],
  ['cfg_macs2_broad', 'macs2_broad'],
];

export async function loadConfig() {
  try {
    const data = await apiFetch('/api/config');
    appState.currentConfig = data.config || {};
    const cfg = appState.currentConfig;

    for (const [elId, key, fallback] of STRING_FIELDS) {
      const el = document.getElementById(elId);
      if (el) el.value = cfg[key] ?? fallback;
    }
    for (const [elId, key, fallback] of NUMBER_FIELDS) {
      const el = document.getElementById(elId);
      if (el) el.value = cfg[key] ?? fallback;
    }
    for (const [elId, key] of BOOL_FIELDS) {
      const el = document.getElementById(elId);
      if (el) el.checked = Boolean(cfg[key]);
    }
    for (const { valueId, unitId, key, fallback, uppercaseUnit } of UNIT_FIELDS) {
      const valueEl = document.getElementById(valueId);
      const unitEl = document.getElementById(unitId);
      const { amount, unit } = splitValueAndUnit(cfg[key], fallback, uppercaseUnit);
      if (valueEl) valueEl.value = amount;
      if (unitEl && unit) {
        const hasOption = Array.from(unitEl.options).some((opt) => opt.value === unit);
        if (!hasOption) {
          unitEl.add(new Option(unit, unit));
        }
        unitEl.value = unit;
      }
    }

    appState.contrastRows = Array.isArray(cfg.diff_contrasts) ? cfg.diff_contrasts : [];
    renderContrasts();
  } catch (err) {
    console.error('Failed to load config', err);
    if (String(err.message || '').includes('experiment.config not found')) {
      appState.currentConfig = {};
      appState.contrastRows = [];
      renderContrasts();
      showToast('No experiment.config in this workspace yet. Use Switch/Initialize to set one up.', 'warning', 5000);
    } else {
      showToast(`Failed to load configuration: ${err.message}`, 'error');
    }
  }
}

export async function saveConfig(btn) {
  const form = document.getElementById('configForm');
  if (form && !form.checkValidity()) {
    const firstInvalid = form.querySelector(':invalid');
    form.querySelectorAll(':invalid').forEach((el) => el.setAttribute('aria-invalid', 'true'));
    const details = firstInvalid?.closest('details');
    if (details && !details.open) {
      details.open = true;
    }
    form.reportValidity();
    if (firstInvalid) firstInvalid.focus();
    return;
  }
  form?.querySelectorAll('[aria-invalid="true"]').forEach((el) => el.removeAttribute('aria-invalid'));

  const saveBtn = btn || document.getElementById('btnSaveConfig');
  setButtonState(saveBtn, 'loading');

  try {
    const updated = { ...appState.currentConfig };

    for (const [elId, key] of STRING_FIELDS) {
      const el = document.getElementById(elId);
      if (el) updated[key] = el.value.trim();
    }

    for (const [elId, key, , kind] of NUMBER_FIELDS) {
      const el = document.getElementById(elId);
      if (!el) continue;
      const parsed = kind === 'int' ? Number.parseInt(el.value, 10) : Number.parseFloat(el.value);
      if (Number.isNaN(parsed)) {
        setButtonState(saveBtn, 'error');
        el.setAttribute('aria-invalid', 'true');
        el.focus();
        showToast(`Invalid numeric value for ${key}`, 'error');
        return;
      }
      updated[key] = parsed;
    }

    for (const { valueId, unitId, key } of UNIT_FIELDS) {
      const valueEl = document.getElementById(valueId);
      const unitEl = document.getElementById(unitId);
      if (!valueEl || !unitEl) continue;
      const amount = Number.parseFloat(valueEl.value);
      if (!Number.isFinite(amount) || amount <= 0) {
        setButtonState(saveBtn, 'error');
        valueEl.setAttribute('aria-invalid', 'true');
        valueEl.focus();
        showToast(`Invalid positive value for ${key}`, 'error');
        return;
      }
      updated[key] = `${amount}.${unitEl.value}`;
    }

    for (const [elId, key] of BOOL_FIELDS) {
      const el = document.getElementById(elId);
      if (el) updated[key] = Boolean(el.checked);
    }

    updated.diff_contrasts = appState.contrastRows;

    const data = await apiFetch('/api/config', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(updated),
    });
    appState.currentConfig = data.config;
    setButtonState(saveBtn, 'success', '✓ Saved!');
    showToast('Configuration saved successfully!', 'success');
  } catch (err) {
    setButtonState(saveBtn, 'error');
    showToast(`Error saving configuration: ${err.message}`, 'error');
  }
}

