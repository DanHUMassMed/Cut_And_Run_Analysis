import { apiFetch } from './api.js';
import { appState } from './state.js';
import { createEl, setButtonState, showToast } from './ui.js';
import { renderContrasts } from './contrasts.js';

export function getUniqueConditions() {
  const set = new Set();
  for (const r of appState.sampleRows) {
    if (r.condition && r.condition.trim()) set.add(r.condition.trim());
  }
  return Array.from(set);
}

export function getUniqueTargets() {
  const set = new Set();
  for (const r of appState.sampleRows) {
    if (r.target && r.target.trim() && r.target.trim() !== 'IgG') {
      set.add(r.target.trim());
    }
  }
  return Array.from(set);
}

function getIgGControls() {
  return appState.sampleRows
    .filter(
      (r) =>
        (r.target && r.target.trim().toLowerCase() === 'igg') ||
        (r.condition && r.condition.toLowerCase().includes('igg'))
    )
    .map((r) => r.sample_id)
    .filter(Boolean);
}

function inferPeakMode(target) {
  const t = (target || '').trim().toLowerCase();
  if (!t || t === 'igg') return '';
  if (t.includes('k27me3') || t.includes('k9me3') || t.includes('k36me3')) {
    return 'broad';
  }
  return 'narrow';
}

function populatePeakModeSelect(selectEl, row) {
  const isIgG = (row.target || '').trim().toLowerCase() === 'igg';
  selectEl.textContent = '';
  if (isIgG) {
    row.peak_mode = '';
    selectEl.disabled = true;
    selectEl.appendChild(
      createEl('option', {
        value: '',
        selected: true,
        textContent: '(IgG Control)',
      })
    );
    return;
  }

  selectEl.disabled = false;
  const current = (row.peak_mode || '').trim().toLowerCase() || inferPeakMode(row.target);
  row.peak_mode = current;
  for (const [val, label] of [
    ['narrow', 'narrow (Factor / Promoter)'],
    ['broad', 'broad (Histone Domain)'],
  ]) {
    selectEl.appendChild(
      createEl('option', {
        value: val,
        selected: current === val,
        textContent: label,
      })
    );
  }
  selectEl.value = current;
}

function populateControlSelect(selectEl, currentValue, iggOptions) {
  selectEl.textContent = '';
  selectEl.appendChild(
    createEl('option', {
      value: '',
      selected: !currentValue,
      textContent: '(None / Self Control)',
    })
  );

  const knownControls = new Set(iggOptions);
  if (currentValue && !knownControls.has(currentValue)) {
    knownControls.add(currentValue);
  }
  for (const cid of knownControls) {
    selectEl.appendChild(
      createEl('option', {
        value: cid,
        selected: currentValue === cid,
        textContent: cid,
      })
    );
  }
  selectEl.value = currentValue || '';
}

function refreshAllControlSelects() {
  const iggOptions = getIgGControls();
  document.querySelectorAll('#samplesTable tbody select[data-role="control-select"]').forEach((sel, idx) => {
    const row = appState.sampleRows[idx];
    if (row) {
      populateControlSelect(sel, row.control_id || '', iggOptions);
    }
  });
}

export function renderSamples() {
  const tbody = document.querySelector('#samplesTable tbody');
  if (!tbody) return;
  tbody.textContent = '';
  const iggOptions = getIgGControls();

  appState.sampleRows.forEach((row, idx) => {
    const sampleIdInput = createEl('input', {
      type: 'text',
      value: row.sample_id || '',
      'aria-label': `Sample ID row ${idx + 1}`,
      oninput: (e) => {
        row.sample_id = e.target.value;
      },
      onchange: (e) => {
        row.sample_id = e.target.value;
        refreshAllControlSelects();
        renderContrasts();
      },
    });

    const sampleNameInput = createEl('input', {
      type: 'text',
      value: row.sample_name || '',
      'aria-label': `Sample Name row ${idx + 1}`,
      oninput: (e) => {
        row.sample_name = e.target.value;
      },
    });

    const conditionInput = createEl('input', {
      type: 'text',
      value: row.condition || '',
      'aria-label': `Condition row ${idx + 1}`,
      oninput: (e) => {
        row.condition = e.target.value;
      },
      onchange: () => {
        refreshAllControlSelects();
        renderContrasts();
      },
    });

    const peakModeSelect = createEl('select', {
      'data-role': 'peak-mode-select',
      'aria-label': `Peak Mode row ${idx + 1}`,
      onchange: (e) => {
        row.peak_mode = e.target.value;
      },
    });
    populatePeakModeSelect(peakModeSelect, row);

    const targetInput = createEl('input', {
      type: 'text',
      value: row.target || '',
      'aria-label': `Target row ${idx + 1}`,
      oninput: (e) => {
        row.target = e.target.value;
      },
      onchange: () => {
        row.peak_mode = inferPeakMode(row.target);
        populatePeakModeSelect(peakModeSelect, row);
        refreshAllControlSelects();
        renderContrasts();
      },
    });

    const replicateInput = createEl('input', {
      type: 'number',
      value: row.replicate || '1',
      min: '1',
      style: { maxWidth: '80px' },
      'aria-label': `Replicate row ${idx + 1}`,
      oninput: (e) => {
        row.replicate = e.target.value;
      },
    });

    const controlSelect = createEl('select', {
      'data-role': 'control-select',
      'aria-label': `Control ID row ${idx + 1}`,
      onchange: (e) => {
        row.control_id = e.target.value;
        renderContrasts();
      },
    });
    populateControlSelect(controlSelect, row.control_id || '', iggOptions);

    const removeBtn = createEl('button', {
      type: 'button',
      className: 'btn btn-danger btn-sm',
      'aria-label': `Remove sample row ${idx + 1}`,
      textContent: '✕',
      onclick: () => {
        appState.sampleRows.splice(idx, 1);
        renderSamples();
        renderContrasts();
      },
    });

    const tr = createEl('tr', {}, [
      createEl('td', {}, sampleIdInput),
      createEl('td', {}, sampleNameInput),
      createEl('td', {}, conditionInput),
      createEl('td', {}, targetInput),
      createEl('td', {}, peakModeSelect),
      createEl('td', {}, replicateInput),
      createEl('td', {}, controlSelect),
      createEl('td', {}, removeBtn),
    ]);
    tbody.appendChild(tr);
  });
}

export async function loadSamplesheet() {
  try {
    const data = await apiFetch('/api/samplesheet');
    appState.sampleRows = Array.isArray(data.rows) ? data.rows : [];
    renderSamples();
  } catch (err) {
    console.error('Failed to load samplesheet', err);
    showToast(`Failed to load samplesheet: ${err.message}`, 'error');
  }
}

export function addSampleRow() {
  appState.sampleRows.push({
    sample_id: '',
    sample_name: '',
    condition: '',
    target: 'H3K4me3',
    peak_mode: 'narrow',
    replicate: '1',
    control_id: '',
  });
  renderSamples();
}

export async function saveSamplesheet(btn) {
  const saveBtn = btn || document.getElementById('btnSaveSamplesheet');
  setButtonState(saveBtn, 'loading');

  try {
    await apiFetch('/api/samplesheet', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rows: appState.sampleRows }),
    });
    setButtonState(saveBtn, 'success', '✓ Saved!');
    showToast('Samplesheet saved successfully!', 'success');
    renderContrasts();
  } catch (err) {
    setButtonState(saveBtn, 'error');
    showToast(`Error saving samplesheet: ${err.message}`, 'error');
  }
}

export async function discoverSamples() {
  try {
    const data = await apiFetch('/api/samplesheet/discover', { method: 'POST' });
    if (data.discovered && data.discovered.length) {
      let added = 0;
      for (const id of data.discovered) {
        if (!appState.sampleRows.some((r) => r.sample_id === id)) {
          const isIgG = id.toLowerCase().includes('igg');
          const target = isIgG ? 'IgG' : 'H3K4me3';
          appState.sampleRows.push({
            sample_id: id,
            sample_name: id,
            condition: id,
            target,
            peak_mode: inferPeakMode(target),
            replicate: '1',
            control_id: '',
          });
          added++;
        }
      }
      renderSamples();
      renderContrasts();
      showToast(`Discovered and added ${added} new BAM sample(s)!`, 'success');
    } else {
      showToast(data.error || 'No new BAM samples found.', 'info');
    }
  } catch (err) {
    showToast(`Failed to discover samples: ${err.message}`, 'error');
  }
}

