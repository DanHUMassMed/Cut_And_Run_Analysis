import { apiFetch } from './api.js';
import { closeModal, createEl, openModal, showToast } from './ui.js';

let lastWorkspaceState = null;
let browserState = null;
let browserEventsBound = false;

function setModalError(message) {
  const errEl = document.getElementById('workspaceModalError');
  if (!errEl) return;
  if (message) {
    errEl.textContent = message;
    errEl.style.display = 'block';
  } else {
    errEl.textContent = '';
    errEl.style.display = 'none';
  }
}

function renderHeaderWorkspace(state) {
  const pill = document.getElementById('workspacePill');
  const label = document.getElementById('workspaceBadgeLabel');
  if (!pill || !label || !state?.current) return;

  const { label: shortLabel, path, has_config: hasConfig } = state.current;
  label.textContent = hasConfig ? shortLabel : `${shortLabel} (no config)`;
  pill.title = path;
  pill.classList.toggle('workspace-pill-warning', !hasConfig);
}

function renderWorkspaceModalContent(state, onSwitch) {
  const currentPathEl = document.getElementById('workspaceCurrentPath');
  const currentBadgesEl = document.getElementById('workspaceCurrentBadges');
  const recentListEl = document.getElementById('workspaceRecentList');
  const pathInput = document.getElementById('workspacePathInput');

  const isUnconfiguredPipelineRoot = Boolean(
    state?.current && state.current.path === state.pipeline_dir && !state.current.has_config
  );

  if (currentPathEl && state?.current) {
    currentPathEl.textContent = isUnconfiguredPipelineRoot
      ? '(No experiment workspace selected yet)'
      : state.current.path;
  }
  if (pathInput && state?.current) {
    pathInput.value = isUnconfiguredPipelineRoot ? '' : state.current.path;
  }

  if (currentBadgesEl && state?.current) {
    currentBadgesEl.textContent = '';
    const checks = [
      ['experiment.config', state.current.has_config],
      ['samplesheet.csv', state.current.has_samplesheet],
      ['run.sh', state.current.has_run_sh],
    ];
    for (const [name, ok] of checks) {
      currentBadgesEl.appendChild(
        createEl('span', {
          className: ok ? 'badge-ok' : 'badge-warning',
          textContent: `${ok ? '✓' : 'Missing'} ${name}`,
        })
      );
    }
  }

  if (recentListEl) {
    recentListEl.textContent = '';
    const recent = state?.recent || [];
    if (recent.length === 0) {
      recentListEl.appendChild(
        createEl('div', {
          style: { fontSize: '0.84rem', color: 'var(--text-muted)', padding: '0.5rem 0' },
          textContent: 'No recent experiment folders recorded yet.',
        })
      );
      return;
    }

    for (const item of recent) {
      const isCurrent = item.path === state?.current?.path;
      const row = createEl(
        'button',
        {
          type: 'button',
          className: `workspace-recent-item${isCurrent ? ' active' : ''}`,
        },
        [
          createEl('div', { className: 'workspace-recent-main' }, [
            createEl('span', { className: 'workspace-recent-label', textContent: item.label }),
            createEl('span', { className: 'workspace-recent-path', textContent: item.path }),
          ]),
          createEl('span', {
            className: isCurrent ? 'step-tag' : item.has_config ? 'badge-ok' : 'badge-warning',
            textContent: isCurrent ? 'Active' : item.has_config ? 'Ready' : 'No config',
          }),
        ]
      );
      if (!isCurrent) {
        row.addEventListener('click', () => {
          onSwitch(item.path, { initialize: false, experimentName: null });
        });
      } else {
        row.disabled = true;
      }
      recentListEl.appendChild(row);
    }
  }
}

async function loadDirectoryBrowser(targetPath = null) {
  setModalError('');
  const currentEl = document.getElementById('workspaceBrowserCurrent');
  const listEl = document.getElementById('workspaceBrowserList');
  const upBtn = document.getElementById('btnBrowserUp');
  const pathInput = document.getElementById('workspacePathInput');

  if (listEl) {
    listEl.textContent = '';
    listEl.appendChild(
      createEl('div', {
        style: { padding: '0.75rem', fontSize: '0.82rem', color: 'var(--text-muted)' },
        textContent: 'Loading folders...',
      })
    );
  }

  try {
    const query = targetPath ? `?path=${encodeURIComponent(targetPath)}` : '';
    const data = await apiFetch(`/api/workspace/list-dirs${query}`);
    browserState = data;

    if (currentEl) currentEl.textContent = data.current;
    if (pathInput) pathInput.value = data.current;
    if (upBtn) upBtn.disabled = !data.parent;
    if (data.error) setModalError(data.error);

    if (!listEl) return;
    listEl.textContent = '';
    if (!data.directories || data.directories.length === 0) {
      listEl.appendChild(
        createEl('div', {
          style: { padding: '0.75rem', fontSize: '0.82rem', color: 'var(--text-muted)' },
          textContent: 'No subfolders in this directory.',
        })
      );
      return;
    }

    for (const dir of data.directories) {
      const badge = dir.has_config
        ? createEl('span', { className: 'badge-ok', textContent: 'Ready' })
        : null;
      const item = createEl('button', { type: 'button', className: 'workspace-browser-item' }, [
        createEl('span', { textContent: `📁 ${dir.name}` }),
        badge,
      ]);
      item.addEventListener('click', () => {
        loadDirectoryBrowser(dir.path);
      });
      listEl.appendChild(item);
    }
  } catch (err) {
    setModalError(`Could not browse directory: ${err.message}`);
    if (listEl) listEl.textContent = '';
  }
}

function bindBrowserToolbarOnce() {
  if (browserEventsBound) return;
  browserEventsBound = true;

  document.getElementById('btnBrowserUp')?.addEventListener('click', () => {
    if (browserState?.parent) loadDirectoryBrowser(browserState.parent);
  });
  document.getElementById('btnBrowserHome')?.addEventListener('click', () => {
    if (browserState?.home) loadDirectoryBrowser(browserState.home);
  });
  document.getElementById('btnBrowserRepoParent')?.addEventListener('click', () => {
    if (browserState?.pipeline_parent) loadDirectoryBrowser(browserState.pipeline_parent);
  });
}

export async function loadWorkspaceState() {
  try {
    const state = await apiFetch('/api/workspace');
    lastWorkspaceState = state;
    renderHeaderWorkspace(state);
    return state;
  } catch (err) {
    console.error('Failed to load workspace state', err);
    return null;
  }
}

export async function openWorkspaceModal(onSwitch) {
  bindBrowserToolbarOnce();
  setModalError('');
  const browserPanel = document.getElementById('workspaceBrowserPanel');
  if (browserPanel) browserPanel.style.display = 'none';

  const state = (await loadWorkspaceState()) || lastWorkspaceState;
  renderWorkspaceModalContent(state, onSwitch);
  const initCheck = document.getElementById('workspaceInitCheck');
  const expWrap = document.getElementById('workspaceExpNameWrap');
  if (initCheck && expWrap) {
    initCheck.checked = false;
    expWrap.style.display = 'none';
  }
  openModal('workspaceModal');
}

export async function browseWorkspaceFolder() {
  bindBrowserToolbarOnce();
  const panel = document.getElementById('workspaceBrowserPanel');
  const pathInput = document.getElementById('workspacePathInput');
  if (!panel) return;

  const isVisible = panel.style.display !== 'none';
  if (isVisible) {
    panel.style.display = 'none';
    return;
  }

  panel.style.display = 'block';
  const typedPath = pathInput?.value?.trim() || '';
  await loadDirectoryBrowser(typedPath || null);
}

export async function switchWorkspace(targetPath, options, onReloadAll) {
  setModalError('');
  const confirmBtn = document.getElementById('btnConfirmWorkspace');
  if (confirmBtn) {
    confirmBtn.disabled = true;
    confirmBtn.textContent = 'Switching...';
  }
  try {
    const state = await apiFetch('/api/workspace/select', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        path: targetPath,
        initialize: Boolean(options?.initialize),
        experiment_name: options?.experimentName || null,
      }),
    });
    lastWorkspaceState = state;
    renderHeaderWorkspace(state);
    closeModal('workspaceModal');
    if (typeof onReloadAll === 'function') {
      await onReloadAll();
    }
    showToast(`Switched workspace to ${state.current?.label || targetPath}`, 'success');
  } catch (err) {
    setModalError(`Could not switch workspace: ${err.message}`);
  } finally {
    if (confirmBtn) {
      confirmBtn.disabled = false;
      confirmBtn.textContent = 'Open Workspace';
    }
  }
}
