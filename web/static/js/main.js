import { loadConfig, saveConfig } from './config.js';
import { addContrastRow, saveContrasts } from './contrasts.js';
import {
  checkPreflight,
  clearLogsView,
  confirmLaunch,
  confirmQuitServer,
  confirmStop,
  copyLogsToClipboard,
  initLogStream,
  openLaunchModal,
  openQuitServerModal,
  pollStatus,
  resetMonitorForWorkspaceSwitch,
} from './monitor.js';
import {
  copyResultsPath,
  filterResultsCategory,
  loadResultsGallery,
  openResultsInFinder,
} from './results.js';
import { addSampleRow, discoverSamples, loadSamplesheet, saveSamplesheet } from './samplesheet.js';
import { closeModal, initDialogLightDismissFallback, openModal, switchTab } from './ui.js';
import {
  browseWorkspaceFolder,
  loadWorkspaceState,
  openWorkspaceModal,
  switchWorkspace,
} from './workspace.js';

async function reloadAllWorkspaceViews() {
  resetMonitorForWorkspaceSwitch();
  await Promise.all([loadConfig(), loadSamplesheet(), pollStatus()]);
  const resultsTab = document.getElementById('resultsTab');
  if (resultsTab?.classList.contains('active')) {
    await loadResultsGallery();
  }
}

window.addEventListener('DOMContentLoaded', () => {
  initDialogLightDismissFallback();

  const handleWorkspaceSwitch = (targetPath, options) =>
    switchWorkspace(targetPath, options, reloadAllWorkspaceViews);

  // Header actions
  document.getElementById('workspacePill')?.addEventListener('click', () => {
    openWorkspaceModal(handleWorkspaceSwitch);
  });
  document.getElementById('btnPreflight')?.addEventListener('click', checkPreflight);
  document.getElementById('btnStartPipeline')?.addEventListener('click', openLaunchModal);
  document.getElementById('btnStopPipeline')?.addEventListener('click', () => openModal('stopModal'));
  document.getElementById('btnQuitServer')?.addEventListener('click', openQuitServerModal);

  // Navigation tabs
  document.querySelectorAll('nav.tabs button[data-tab]').forEach((btn) => {
    btn.addEventListener('click', () => {
      switchTab(btn.dataset.tab, btn, loadResultsGallery);
    });
  });

  // Configuration form
  const configForm = document.getElementById('configForm');
  configForm?.addEventListener('submit', (e) => {
    e.preventDefault();
    saveConfig(document.getElementById('btnSaveConfig'));
  });
  configForm?.addEventListener('input', (e) => {
    const target = e.target;
    if (target instanceof HTMLElement && target.getAttribute('aria-invalid') === 'true') {
      if ('checkValidity' in target && target.checkValidity()) {
        target.removeAttribute('aria-invalid');
      }
    }
  });

  // Samplesheet controls
  document.getElementById('btnDiscoverSamples')?.addEventListener('click', discoverSamples);
  document.getElementById('btnAddSampleRow')?.addEventListener('click', addSampleRow);
  document.getElementById('btnSaveSamplesheet')?.addEventListener('click', (e) => {
    saveSamplesheet(e.currentTarget);
  });

  // Contrasts controls
  document.getElementById('btnAddContrastRow')?.addEventListener('click', addContrastRow);
  document.getElementById('btnSaveContrasts')?.addEventListener('click', (e) => {
    saveContrasts(e.currentTarget);
  });

  // Monitor / log controls
  document.getElementById('btnCopyLogs')?.addEventListener('click', copyLogsToClipboard);
  document.getElementById('btnClearLogs')?.addEventListener('click', clearLogsView);

  // Results controls
  document.getElementById('btnRefreshResults')?.addEventListener('click', loadResultsGallery);
  document.getElementById('btnOpenFinder')?.addEventListener('click', openResultsInFinder);
  document.getElementById('btnCopyResultsPath')?.addEventListener('click', copyResultsPath);
  document.querySelectorAll('.results-subnav button[data-category]').forEach((btn) => {
    btn.addEventListener('click', () => filterResultsCategory(btn.dataset.category, btn));
  });

  // Dialog close buttons & modal actions
  document.querySelectorAll('[data-close-dialog]').forEach((btn) => {
    btn.addEventListener('click', () => closeModal(btn.dataset.closeDialog));
  });
  document.getElementById('btnConfirmLaunch')?.addEventListener('click', confirmLaunch);
  document.getElementById('btnConfirmStop')?.addEventListener('click', confirmStop);
  document.getElementById('btnConfirmQuitServer')?.addEventListener('click', confirmQuitServer);
  document.getElementById('btnBrowseWorkspace')?.addEventListener('click', browseWorkspaceFolder);
  document.getElementById('workspaceInitCheck')?.addEventListener('change', (e) => {
    const expWrap = document.getElementById('workspaceExpNameWrap');
    if (expWrap) expWrap.style.display = e.target.checked ? 'block' : 'none';
  });
  document.getElementById('btnConfirmWorkspace')?.addEventListener('click', () => {
    const targetPath = document.getElementById('workspacePathInput')?.value?.trim() || '';
    const initialize = Boolean(document.getElementById('workspaceInitCheck')?.checked);
    const experimentName = document.getElementById('workspaceExpNameInput')?.value?.trim() || null;
    if (!targetPath) return;
    handleWorkspaceSwitch(targetPath, { initialize, experimentName });
  });
  document.getElementById('preflightLaunchBtn')?.addEventListener('click', () => {
    closeModal('preflightModal');
    openLaunchModal();
  });

  // Initial data load & live status streams
  loadWorkspaceState().then((wsState) => {
    if (wsState?.current && !wsState.current.has_config) {
      openWorkspaceModal(handleWorkspaceSwitch);
    }
  });
  loadConfig();
  loadSamplesheet();
  initLogStream();
  pollStatus();
  setInterval(pollStatus, 2000);
});

