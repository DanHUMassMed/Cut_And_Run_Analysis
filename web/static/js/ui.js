export function createEl(tag, attrs = {}, children = []) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null) continue;
    if (key === 'className') {
      el.className = value;
    } else if (key === 'textContent') {
      el.textContent = String(value);
    } else if (key === 'value') {
      el.value = String(value);
    } else if (key === 'checked') {
      el.checked = Boolean(value);
    } else if (key === 'selected') {
      el.selected = Boolean(value);
    } else if (key === 'style' && typeof value === 'object') {
      Object.assign(el.style, value);
    } else if (key.startsWith('on') && typeof value === 'function') {
      el.addEventListener(key.slice(2).toLowerCase(), value);
    } else {
      el.setAttribute(key, String(value));
    }
  }

  const childList = Array.isArray(children) ? children : [children];
  for (const child of childList) {
    if (child === undefined || child === null) continue;
    if (typeof child === 'string' || typeof child === 'number') {
      el.appendChild(document.createTextNode(String(child)));
    } else {
      el.appendChild(child);
    }
  }
  return el;
}

export function showToast(message, type = 'success', duration = 3200) {
  const container = document.getElementById('toastContainer');
  if (!container) return;

  let icon = '✓';
  if (type === 'error') icon = '✕';
  else if (type === 'warning') icon = '⚠';
  else if (type === 'info') icon = 'ℹ';

  const closeBtn = createEl('button', {
    type: 'button',
    className: 'toast-close-btn',
    'aria-label': 'Dismiss notification',
    textContent: '✕',
  });

  const toast = createEl('div', { className: `toast-item toast-${type}` }, [
    createEl('span', { style: { fontWeight: '700', fontSize: '1rem' }, textContent: icon }),
    createEl('span', { style: { flex: '1' }, textContent: message }),
    closeBtn,
  ]);

  closeBtn.addEventListener('click', () => toast.remove());
  container.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('show'));

  setTimeout(() => {
    toast.classList.remove('show');
    setTimeout(() => toast.remove(), 260);
  }, duration);
}

export function setButtonState(btn, state, successText = '✓ Saved!') {
  if (!btn) return;
  if (state === 'loading') {
    if (!btn.dataset.origText) {
      btn.dataset.origText = btn.textContent || 'Save';
    }
    btn.disabled = true;
    btn.textContent = 'Saving...';
  } else if (state === 'success') {
    btn.disabled = false;
    btn.textContent = successText;
    btn.classList.add('btn-success');
    btn.classList.remove('btn-primary');
    setTimeout(() => {
      btn.textContent = btn.dataset.origText || 'Save';
      btn.classList.remove('btn-success');
      btn.classList.add('btn-primary');
    }, 1500);
  } else {
    btn.disabled = false;
    btn.textContent = btn.dataset.origText || 'Save';
    btn.classList.remove('btn-success');
    btn.classList.add('btn-primary');
  }
}

export function openModal(id) {
  const dialog = document.getElementById(id);
  if (dialog && typeof dialog.showModal === 'function' && !dialog.open) {
    dialog.showModal();
  }
}

export function closeModal(id) {
  const dialog = document.getElementById(id);
  if (dialog && typeof dialog.close === 'function' && dialog.open) {
    dialog.close();
  }
}

export function initDialogLightDismissFallback() {
  // Progressive enhancement fallback for browsers lacking <dialog closedby="any"> (e.g., Safari)
  if (!('closedBy' in HTMLDialogElement.prototype)) {
    const outside = (e, dialog) => {
      const r = dialog.getBoundingClientRect();
      return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
    };
    for (const dialog of document.querySelectorAll('dialog[closedby="any"]')) {
      let pressedOutside = false;
      dialog.addEventListener('pointerdown', (e) => {
        pressedOutside = outside(e, dialog);
      });
      dialog.addEventListener('pointerup', (e) => {
        if (pressedOutside && outside(e, dialog)) dialog.close();
      });
    }
  }
}

export function switchTab(tabId, tabButton, onResultsTab) {
  document.querySelectorAll('.tab-content').forEach((t) => t.classList.remove('active'));
  document.querySelectorAll('nav.tabs button').forEach((b) => b.classList.remove('active'));

  const target = document.getElementById(tabId);
  if (target) target.classList.add('active');
  if (tabButton) tabButton.classList.add('active');
  if (tabId === 'resultsTab' && typeof onResultsTab === 'function') {
    onResultsTab();
  }
}

