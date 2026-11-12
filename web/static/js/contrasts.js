import { apiFetch } from './api.js';
import { appState } from './state.js';
import { createEl, setButtonState, showToast } from './ui.js';
import { getUniqueConditions, getUniqueTargets } from './samplesheet.js';

function buildSelect(options, selectedValue, ariaLabel, onChange) {
  const select = createEl('select', { 'aria-label': ariaLabel, onchange: onChange });
  const optionSet = new Set(options);
  if (selectedValue && !optionSet.has(selectedValue)) {
    select.appendChild(
      createEl('option', {
        value: selectedValue,
        selected: true,
        textContent: selectedValue,
      })
    );
  }
  for (const opt of options) {
    select.appendChild(
      createEl('option', {
        value: opt,
        selected: selectedValue === opt,
        textContent: opt,
      })
    );
  }
  if (selectedValue) {
    select.value = selectedValue;
  }
  return select;
}

export function renderContrasts() {
  const tbody = document.querySelector('#contrastsTable tbody');
  if (!tbody) return;
  tbody.textContent = '';

  const conditions = getUniqueConditions();
  const targets = getUniqueTargets();

  appState.contrastRows.forEach((contrast, idx) => {
    const idInput = createEl('input', {
      type: 'text',
      id: `contrast_id_${idx}`,
      value: contrast.id || '',
      'aria-label': `Contrast ID row ${idx + 1}`,
      oninput: (e) => {
        contrast.id = e.target.value;
      },
    });

    const syncContrastId = () => {
      if (contrast.treatment && contrast.background) {
        contrast.id = `${contrast.treatment}_vs_${contrast.background}`;
        idInput.value = contrast.id;
      }
    };

    const treatSelect = buildSelect(
      conditions,
      contrast.treatment || '',
      `Treatment condition row ${idx + 1}`,
      (e) => {
        contrast.treatment = e.target.value;
        syncContrastId();
      }
    );

    const bgSelect = buildSelect(
      conditions,
      contrast.background || '',
      `Background condition row ${idx + 1}`,
      (e) => {
        contrast.background = e.target.value;
        syncContrastId();
      }
    );

    const targetSelect = buildSelect(
      targets,
      contrast.target || '',
      `Target row ${idx + 1}`,
      (e) => {
        contrast.target = e.target.value;
      }
    );

    const removeBtn = createEl('button', {
      type: 'button',
      className: 'btn btn-danger btn-sm',
      'aria-label': `Remove contrast row ${idx + 1}`,
      textContent: '✕',
      onclick: () => {
        appState.contrastRows.splice(idx, 1);
        renderContrasts();
      },
    });

    tbody.appendChild(
      createEl('tr', {}, [
        createEl('td', {}, idInput),
        createEl('td', {}, treatSelect),
        createEl('td', {}, bgSelect),
        createEl('td', {}, targetSelect),
        createEl('td', {}, removeBtn),
      ])
    );
  });
}

export function addContrastRow() {
  const conditions = getUniqueConditions();
  const targets = getUniqueTargets();
  const defaultTreat = conditions[0] || 'Treatment';
  const defaultBg = conditions[1] || conditions[0] || 'Background';
  const defaultTgt = targets[0] || 'H3K4me3';

  appState.contrastRows.push({
    id: `${defaultTreat}_vs_${defaultBg}`,
    treatment: defaultTreat,
    background: defaultBg,
    target: defaultTgt,
  });
  renderContrasts();
}

export async function saveContrasts(btn) {
  const saveBtn = btn || document.getElementById('btnSaveContrasts');
  setButtonState(saveBtn, 'loading');
  try {
    const data = await apiFetch('/api/config/contrasts', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ diff_contrasts: appState.contrastRows }),
    });
    appState.contrastRows = data.diff_contrasts || appState.contrastRows;
    appState.currentConfig.diff_contrasts = appState.contrastRows;
    setButtonState(saveBtn, 'success', '✓ Contrasts Saved!');
    showToast('Contrasts updated and saved to config!', 'success');
  } catch (err) {
    setButtonState(saveBtn, 'idle');
    showToast(`Error saving contrasts: ${err.message}`, 'error');
  }
}

