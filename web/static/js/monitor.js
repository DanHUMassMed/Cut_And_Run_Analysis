import { apiFetch } from './api.js';
import { appState } from './state.js';
import { closeModal, createEl, openModal, showToast, switchTab } from './ui.js';

const MAX_LOG_LINES = 3000;
let logLinesBuffer = [];
let pipelineTimerInterval = null;
let pipelineStartTime = null;
let pipelineEndTime = null;
let isPipelineRunning = false;
let activeEventSource = null;
let serverStopped = false;
let consecutivePollFailures = 0;

function formatDuration(ms) {
  if (!ms && ms !== 0) return '-';
  if (ms < 1000) return `${ms}ms`;
  const sec = Number((ms / 1000).toFixed(1));
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  const remSec = Math.round(sec % 60);
  return `${min}m ${remSec}s`;
}

function formatElapsedTime(ms) {
  if (!ms || ms < 0 || Number.isNaN(ms)) ms = 0;
  const totalSecs = Math.floor(ms / 1000);
  const hours = Math.floor(totalSecs / 3600);
  const minutes = Math.floor((totalSecs % 3600) / 60);
  const seconds = totalSecs % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
}

export function startElapsedTimer(startTimeMs) {
  if (startTimeMs) {
    pipelineStartTime = Number(startTimeMs);
  } else if (!pipelineStartTime) {
    pipelineStartTime = Date.now();
  }
  pipelineEndTime = null;
  isPipelineRunning = true;

  const timerEl = document.getElementById('monitorElapsedTime');
  const containerEl = document.getElementById('monitorElapsedTimer');
  if (containerEl) containerEl.classList.add('running');

  const updateTick = () => {
    if (!isPipelineRunning) return;
    const elapsed = Math.max(0, Date.now() - pipelineStartTime);
    if (timerEl) timerEl.textContent = formatElapsedTime(elapsed);
  };

  updateTick();
  if (pipelineTimerInterval) clearInterval(pipelineTimerInterval);
  pipelineTimerInterval = setInterval(updateTick, 1000);
}

export function stopElapsedTimer(endTimeMs) {
  isPipelineRunning = false;
  if (pipelineTimerInterval) {
    clearInterval(pipelineTimerInterval);
    pipelineTimerInterval = null;
  }
  if (endTimeMs) {
    pipelineEndTime = Number(endTimeMs);
  } else if (!pipelineEndTime && pipelineStartTime) {
    pipelineEndTime = Date.now();
  }

  const timerEl = document.getElementById('monitorElapsedTime');
  const containerEl = document.getElementById('monitorElapsedTimer');
  if (containerEl) containerEl.classList.remove('running');

  if (pipelineStartTime && pipelineEndTime && timerEl) {
    const finalElapsed = Math.max(0, pipelineEndTime - pipelineStartTime);
    timerEl.textContent = formatElapsedTime(finalElapsed);
  }
}

export function updateStatsUI(stats, runName) {
  if (!stats) return;
  const total = stats.total || 0;
  const running = stats.running || 0;
  const completed = stats.completed || 0;
  const cached = stats.cached || 0;
  const failed = stats.failed || 0;
  const percent = stats.percent !== undefined ? stats.percent : 0;

  const setText = (id, val) => {
    const el = document.getElementById(id);
    if (el) el.textContent = String(val);
  };

  setText('statTotal', total);
  setText('statRunning', running);
  setText('statCompleted', completed);
  setText('statCached', cached);
  setText('statFailed', failed);
  setText('progressPercentText', `${percent}%`);

  const progressBarFill = document.getElementById('progressBarFill');
  if (progressBarFill) progressBarFill.style.width = `${percent}%`;

  const taskCountSummary = document.getElementById('taskCountSummary');
  if (taskCountSummary) {
    const cachedNote = cached > 0 ? ` (${cached} cached)` : '';
    taskCountSummary.textContent = `${completed} of ${total} tasks finished (${percent}%)${cachedNote}`;
  }

  const runBadge = document.getElementById('monitorRunBadge');
  const rName = runName || stats.run_name;
  if (runBadge && rName) {
    runBadge.style.display = 'inline-block';
    runBadge.textContent = `Run: ${rName}`;
  }
}

function renderTaskRow(task) {
  const tbody = document.getElementById('taskTableBody');
  if (!tbody) return;

  const noTasksRow = document.getElementById('noTasksRow');
  if (noTasksRow) noTasksRow.remove();

  const rawKey = String(task.hash || task.key || task.task_id || '');
  const rowKey = rawKey.replace(/[^a-zA-Z0-9_-]/g, '_');
  let row = document.getElementById(`task-row-${rowKey}`);
  if (!row) {
    row = createEl('tr', { id: `task-row-${rowKey}` });
    tbody.appendChild(row);
  }

  const status = task.status || 'SUBMITTED';
  const statusLabel =
    status === 'RUNNING'
      ? 'Running'
      : status === 'COMPLETED'
        ? 'Completed'
        : status === 'CACHED'
          ? '⚡ Cached'
          : status === 'FAILED'
            ? 'Failed'
            : status === 'ABORTED'
              ? 'Aborted'
              : 'Submitted';
  const durationText =
    status === 'CACHED'
      ? 'Cached'
      : task.duration || task.realtime_fmt || formatDuration(task.realtime);
  const displayIndex = Array.from(tbody.children).indexOf(row) + 1;

  row.textContent = '';
  row.appendChild(
    createEl('td', { style: { fontWeight: '600', color: '#64748b' }, textContent: displayIndex })
  );
  row.appendChild(
    createEl('td', {
      style: { fontWeight: '600', color: '#1e293b' },
      textContent: task.process_short || task.process || '',
    })
  );
  row.appendChild(
    createEl('td', {}, createEl('span', { className: 'task-tag-pill', textContent: task.tag || '-' }))
  );
  row.appendChild(
    createEl(
      'td',
      {},
      createEl('span', {
        className: `task-status-badge task-status-${status}`,
        textContent: statusLabel,
      })
    )
  );
  row.appendChild(
    createEl('td', { style: { color: '#64748b', fontSize: '0.82rem' }, textContent: durationText })
  );
  row.appendChild(
    createEl('td', { className: 'mono-muted', textContent: task.hash || '-' })
  );
}

function appendLogLine(line) {
  const box = document.getElementById('logOutput');
  if (!box) return;
  const autoScroll = document.getElementById('autoScrollLogs');

  logLinesBuffer.push(line);
  if (logLinesBuffer.length > MAX_LOG_LINES) {
    logLinesBuffer = logLinesBuffer.slice(-MAX_LOG_LINES);
  }
  box.textContent = logLinesBuffer.join('');

  if (autoScroll && autoScroll.checked) {
    box.scrollTop = box.scrollHeight;
  }
}

export function clearLogsView() {
  logLinesBuffer = [];
  const box = document.getElementById('logOutput');
  if (box) box.textContent = '';
}

export async function copyLogsToClipboard() {
  const box = document.getElementById('logOutput');
  if (!box) return;
  try {
    await navigator.clipboard.writeText(box.textContent || '');
    showToast('Execution logs copied to clipboard!', 'success');
  } catch (err) {
    showToast(`Could not copy logs: ${err}`, 'error');
  }
}

function updateStatusBadges(status) {
  const text = `Status: ${status}`;
  const cls = `status-badge status-${status}`;
  const headerBadge = document.getElementById('pipelineStatusBadge');
  if (headerBadge) {
    headerBadge.className = cls;
    headerBadge.textContent = text;
  }
  const progressBadge = document.getElementById('monitorProgressBadge');
  if (progressBadge) {
    progressBadge.className = cls;
    progressBadge.textContent = text;
  }
}

function syncTasks(tasks) {
  if (!Array.isArray(tasks) || tasks.length === 0) return;
  for (const t of tasks) {
    const key = t.hash || t.key || t.task_id;
    const prev = appState.activeTasksMap.get(key);
    const changed =
      !prev ||
      prev.status !== t.status ||
      prev.duration !== t.duration ||
      prev.realtime !== t.realtime ||
      prev.exit !== t.exit;
    appState.activeTasksMap.set(key, t);
    if (changed) {
      renderTaskRow(t);
    }
  }
}

export function initLogStream() {
  if (activeEventSource) {
    activeEventSource.close();
  }
  const evtSource = new EventSource('/api/pipeline/stream');
  activeEventSource = evtSource;

  evtSource.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'init_state') {
        logLinesBuffer = [];
        if (data.stats) updateStatsUI(data.stats, data.run_name);
        if (data.tasks && data.tasks.length > 0) {
          const tbody = document.getElementById('taskTableBody');
          if (tbody) tbody.textContent = '';
          appState.activeTasksMap.clear();
          syncTasks(data.tasks);
        }
        if (data.status) {
          updateStatusBadges(data.status);
          if (data.status === 'running') {
            startElapsedTimer(data.start_time ? data.start_time * 1000 : Date.now());
          } else if (['completed', 'failed', 'cancelled'].includes(data.status) && data.start_time) {
            pipelineStartTime = data.start_time * 1000;
            stopElapsedTimer(data.end_time ? data.end_time * 1000 : undefined);
          }
        }
      } else if (data.type === 'task_update') {
        if (data.task) syncTasks([data.task]);
        if (data.stats) updateStatsUI(data.stats, data.run_name);
      } else if (data.type === 'run_started') {
        appState.activeTasksMap.clear();
        const tbody = document.getElementById('taskTableBody');
        if (tbody) {
          tbody.textContent = '';
          tbody.appendChild(
            createEl(
              'tr',
              { id: 'noTasksRow' },
              createEl('td', {
                colspan: '6',
                style: { textAlign: 'center', color: 'var(--text-muted)', padding: '1.5rem' },
                textContent: 'Pipeline run starting...',
              })
            )
          );
        }
        if (data.stats) updateStatsUI(data.stats, data.run_name);
        updateStatusBadges('running');
        startElapsedTimer(data.start_time ? data.start_time * 1000 : Date.now());
      } else if (data.type === 'run_completed' || data.type === 'process_exit') {
        syncTasks(data.tasks || []);
        if (data.stats) updateStatsUI(data.stats);
        if (data.status) updateStatusBadges(data.status);
        stopElapsedTimer(data.end_time ? data.end_time * 1000 : Date.now());
      } else if (data.type === 'log') {
        appendLogLine(data.line || '');
      }
    } catch (err) {
      console.error('Error handling SSE message:', err);
    }
  };

  evtSource.onerror = () => {
    const subtitle = document.getElementById('monitorSubtitle');
    if (subtitle) {
      subtitle.textContent = 'Event stream reconnecting... (polling active)';
    }
  };
}

export async function pollStatus() {
  if (serverStopped) return;
  try {
    const data = await apiFetch('/api/pipeline/status');
    consecutivePollFailures = 0;
    updateStatusBadges(data.status);

    if (data.stats) {
      updateStatsUI(data.stats, data.run_name);
    }
    syncTasks(data.tasks || []);

    const btnStart = document.getElementById('btnStartPipeline');
    const btnStop = document.getElementById('btnStopPipeline');

    if (data.status === 'running') {
      if (btnStart) btnStart.style.display = 'none';
      if (btnStop) btnStop.style.display = 'inline-flex';
      const serverStartMs = data.start_time ? data.start_time * 1000 : null;
      if (!isPipelineRunning || (serverStartMs && Math.abs(serverStartMs - (pipelineStartTime || 0)) > 1000)) {
        startElapsedTimer(serverStartMs || Date.now());
      }
    } else {
      if (btnStart) btnStart.style.display = 'inline-flex';
      if (btnStop) btnStop.style.display = 'none';
      if (isPipelineRunning) {
        stopElapsedTimer(data.end_time ? data.end_time * 1000 : Date.now());
      } else if (data.start_time) {
        pipelineStartTime = data.start_time * 1000;
        stopElapsedTimer(data.end_time ? data.end_time * 1000 : undefined);
      }
    }
  } catch {
    consecutivePollFailures += 1;
    if (consecutivePollFailures >= 2) {
      const badge = document.getElementById('pipelineStatusBadge');
      if (badge) {
        badge.className = 'status-badge status-failed';
        badge.textContent = 'Server Offline';
      }
      const subtitle = document.getElementById('monitorSubtitle');
      if (subtitle) {
        subtitle.textContent = 'Control Center server is not reachable.';
      }
    }
  }
}

export async function checkPreflight() {
  openModal('preflightModal');
  const banner = document.getElementById('preflightModalBanner');
  const list = document.getElementById('preflightModalList');
  const launchBtn = document.getElementById('preflightLaunchBtn');

  if (banner) {
    banner.className = 'preflight-banner';
    banner.textContent = 'Running pre-flight environment validation...';
  }
  if (list) {
    list.textContent = '';
    list.appendChild(
      createEl('div', {
        style: { padding: '1.5rem', textAlign: 'center', color: '#64748b' },
        textContent: 'Checking Nextflow engine, input paths, BAM alignment files, and dependencies...',
      })
    );
  }
  if (launchBtn) launchBtn.style.display = 'none';

  try {
    const data = await apiFetch('/api/preflight', { method: 'POST' });
    if (banner) {
      if (data.ready) {
        banner.className = 'preflight-banner ready';
        banner.textContent = '✓ All pre-flight checks passed! Pipeline is ready to execute.';
      } else {
        banner.className = 'preflight-banner error';
        banner.textContent = '✕ Pre-flight validation found issues. Please review and resolve below:';
      }
    }
    if (launchBtn) {
      launchBtn.style.display = data.ready ? 'inline-flex' : 'none';
    }

    if (list) {
      list.textContent = '';
      for (const check of data.checks || []) {
        let badgeClass = 'badge-failed';
        let badgeIcon = 'FAIL';
        if (check.status === 'ok') {
          badgeClass = 'badge-ok';
          badgeIcon = 'OK';
        } else if (check.status === 'warning') {
          badgeClass = 'badge-warning';
          badgeIcon = 'WARN';
        }

        const item = createEl('div', { className: 'checklist-item' }, [
          createEl('div', { className: 'checklist-item-top' }, [
            createEl('span', {
              style: { fontWeight: '600', fontSize: '0.88rem', color: '#0f172a' },
              textContent: check.name,
            }),
            createEl('span', {
              className: badgeClass,
              style: { fontSize: '0.75rem' },
              textContent: badgeIcon,
            }),
          ]),
          createEl('div', {
            style: { fontSize: '0.8rem', color: '#475569' },
            textContent: check.detail,
          }),
        ]);
        list.appendChild(item);
      }
    }
  } catch (err) {
    if (banner) {
      banner.className = 'preflight-banner error';
      banner.textContent = `Failed to execute pre-flight checks: ${err.message}`;
    }
  }
}

export function openLaunchModal() {
  const expEl = document.getElementById('modalExpName');
  const callerEl = document.getElementById('modalActiveCaller');
  const sampleEl = document.getElementById('modalSampleCount');
  const contrastEl = document.getElementById('modalContrastCount');

  if (expEl) expEl.textContent = appState.currentConfig.experiment || '-';
  if (callerEl) callerEl.textContent = appState.currentConfig.active_peak_caller || 'MACS2';
  if (sampleEl) sampleEl.textContent = `${appState.sampleRows.length} sample(s)`;
  if (contrastEl) contrastEl.textContent = `${appState.contrastRows.length} contrast(s)`;

  openModal('launchModal');
}

export async function confirmLaunch() {
  const resume = Boolean(document.getElementById('launchResumeCheck')?.checked);
  const launchBtn = document.getElementById('btnConfirmLaunch');
  if (launchBtn) {
    launchBtn.disabled = true;
    launchBtn.textContent = 'Launching...';
  }

  try {
    const resData = await apiFetch('/api/pipeline/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ resume }),
    });
    closeModal('launchModal');
    const startMs = resData.start_time ? resData.start_time * 1000 : Date.now();
    startElapsedTimer(startMs);
    showToast(
      resume ? 'Pipeline started with cached resume (-resume)!' : 'Pipeline started fresh!',
      'success'
    );
    const logsTabBtn = document.querySelector('nav.tabs button[data-tab="logsTab"]');
    switchTab('logsTab', logsTabBtn);
  } catch (err) {
    closeModal('launchModal');
    showToast(`Could not start pipeline: ${err.message}`, 'error');
  } finally {
    if (launchBtn) {
      launchBtn.disabled = false;
      launchBtn.textContent = '🚀 Start Execution';
    }
  }
}

export async function confirmStop() {
  const stopBtn = document.getElementById('btnConfirmStop');
  if (stopBtn) {
    stopBtn.disabled = true;
    stopBtn.textContent = 'Stopping...';
  }
  try {
    await apiFetch('/api/pipeline/stop', { method: 'POST' });
    closeModal('stopModal');
    stopElapsedTimer(Date.now());
    showToast('Stop signal (SIGINT) sent to Nextflow pipeline', 'info');
  } catch (err) {
    closeModal('stopModal');
    showToast(`Failed to stop pipeline: ${err.message}`, 'error');
  } finally {
    if (stopBtn) {
      stopBtn.disabled = false;
      stopBtn.textContent = 'Stop Pipeline';
    }
  }
}

export function resetMonitorForWorkspaceSwitch() {
  logLinesBuffer = [];
  isPipelineRunning = false;
  pipelineStartTime = null;
  pipelineEndTime = null;
  appState.activeTasksMap.clear();
  const logOutput = document.getElementById('monitorLogOutput');
  if (logOutput) logOutput.textContent = '';
  const tbody = document.getElementById('taskTableBody');
  if (tbody) {
    tbody.textContent = '';
    tbody.appendChild(
      createEl(
        'tr',
        { id: 'noTasksRow' },
        createEl('td', {
          colspan: '6',
          style: { textAlign: 'center', color: 'var(--text-muted)', padding: '1.5rem' },
          textContent: 'No active or recorded pipeline tasks for this workspace.',
        })
      )
    );
  }
  const timerEl = document.getElementById('monitorElapsedTime');
  if (timerEl) timerEl.textContent = '00:00:00';
  initLogStream();
}

export function openQuitServerModal() {
  const warningEl = document.getElementById('quitServerRunningWarning');
  if (warningEl) {
    warningEl.style.display = isPipelineRunning ? 'block' : 'none';
  }
  openModal('quitServerModal');
}

export async function confirmQuitServer() {
  const quitBtn = document.getElementById('btnConfirmQuitServer');
  if (quitBtn) {
    quitBtn.disabled = true;
    quitBtn.textContent = 'Stopping...';
  }
  try {
    await apiFetch('/api/server/shutdown', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ force: isPipelineRunning }),
    });
    serverStopped = true;
    if (activeEventSource) {
      activeEventSource.close();
      activeEventSource = null;
    }
    stopElapsedTimer(Date.now());
    closeModal('quitServerModal');

    const badge = document.getElementById('pipelineStatusBadge');
    if (badge) {
      badge.className = 'status-badge status-idle';
      badge.textContent = 'Server Stopped';
    }
    const subtitle = document.getElementById('monitorSubtitle');
    if (subtitle) {
      subtitle.textContent = 'Control Center server stopped. You may close this browser tab.';
    }
    showToast('Control Center server stopped. You may close this tab.', 'info', 8000);
  } catch (err) {
    closeModal('quitServerModal');
    showToast(`Failed to stop server: ${err.message}`, 'error');
  } finally {
    if (quitBtn) {
      quitBtn.disabled = false;
      quitBtn.textContent = 'Quit Server';
    }
  }
}

