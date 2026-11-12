import { apiFetch } from './api.js';
import { createEl, showToast } from './ui.js';

const SUMMARY_ORDER = [
  '01_peak_counts',
  '02_genomic_features',
  '03_correlation_and_pca',
  '04_signal_distributions',
  '05_differential_plots',
];

const SUMMARY_LABELS = [
  ['01_peak_counts', 'Step i (QC 1: Counts)'],
  ['02_genomic_features', 'Step i (QC 2: Features)'],
  ['03_correlation_and_pca', 'Step i (QC 3: PCA / Correlation)'],
  ['04_signal_distributions', 'Step i (QC 4: Signal)'],
  ['05_differential_plots', 'Step i (QC 5: Differential Volcano / MA)'],
];

function encodeResultUrl(relPath) {
  return '/api/results/file/' + relPath.split('/').map(encodeURIComponent).join('/');
}

export function filterResultsCategory(cat, btn) {
  document.querySelectorAll('.results-subnav button').forEach((b) => b.classList.remove('active'));
  if (btn) btn.classList.add('active');

  const visibility = {
    section_summary_plots: cat === 'all' || cat === '15_summary_plots',
    section_metapeak_plots: cat === 'all' || cat === '13_metapeak_plots',
    section_motifs: cat === 'all' || cat === '14_motifs',
  };

  for (const [id, show] of Object.entries(visibility)) {
    const el = document.getElementById(id);
    if (el) el.style.display = show ? 'block' : 'none';
  }
}

export async function openResultsInFinder() {
  try {
    await apiFetch('/api/results/open-finder', { method: 'POST' });
    showToast('Opened results directory in Finder', 'success');
  } catch (err) {
    showToast(`Could not open Finder: ${err.message}`, 'error');
  }
}

export async function copyResultsPath() {
  const pathText = document.getElementById('resultsDirDisplay')?.textContent?.trim() || '';
  if (!pathText) return;
  try {
    await navigator.clipboard.writeText(pathText);
    showToast('Results path copied to clipboard!', 'success');
  } catch (err) {
    showToast(`Could not copy path: ${err}`, 'error');
  }
}

export async function loadResultsGallery() {
  const summaryGrid = document.getElementById('summaryPlotsGrid');
  const metapeakGrid = document.getElementById('metapeakGrid');
  const motifsGrid = document.getElementById('motifsGrid');
  if (!summaryGrid || !metapeakGrid || !motifsGrid) return;

  summaryGrid.textContent = '';
  summaryGrid.appendChild(createEl('p', { style: { color: '#64748b' }, textContent: 'Loading summary plots...' }));
  metapeakGrid.textContent = '';
  metapeakGrid.appendChild(createEl('p', { style: { color: '#64748b' }, textContent: 'Loading metapeak files...' }));
  motifsGrid.textContent = '';
  motifsGrid.appendChild(createEl('p', { style: { color: '#64748b' }, textContent: 'Loading motifs...' }));

  try {
    const data = await apiFetch('/api/results/files');
    const dirDisplay = document.getElementById('resultsDirDisplay');
    if (dirDisplay) dirDisplay.textContent = data.results_dir || 'Directory not found';

    if (!data.exists || !data.files.length) {
      summaryGrid.textContent = '';
      summaryGrid.appendChild(
        createEl('p', { style: { color: '#64748b' }, textContent: 'No results found yet in results directory.' })
      );
      metapeakGrid.textContent = '';
      motifsGrid.textContent = '';
      return;
    }

    // 1. 15_summary_plots (PNG)
    const summaryImages = data.files.filter(
      (f) => f.category === '15_summary_plots' && f.name.endsWith('.png')
    );
    summaryImages.sort((a, b) => {
      const orderA = SUMMARY_ORDER.findIndex((prefix) => a.path.includes(prefix));
      const orderB = SUMMARY_ORDER.findIndex((prefix) => b.path.includes(prefix));
      if (orderA !== orderB) return (orderA === -1 ? 99 : orderA) - (orderB === -1 ? 99 : orderB);
      return a.name.localeCompare(b.name);
    });

    const summaryBadge = document.getElementById('summaryCountBadge');
    if (summaryBadge) summaryBadge.textContent = `${summaryImages.length} figures`;
    summaryGrid.textContent = '';

    if (!summaryImages.length) {
      summaryGrid.appendChild(
        createEl('p', { style: { color: '#64748b' }, textContent: 'No PNG summary plots found.' })
      );
    } else {
      for (const f of summaryImages) {
        const fileUrl = encodeResultUrl(f.path);
        const labelMatch = SUMMARY_LABELS.find(([prefix]) => f.path.includes(prefix));
        const stepLabel = labelMatch ? labelMatch[1] : 'Summary QC Plot';

        const card = createEl('div', { className: 'qc-plot-card' }, [
          createEl(
            'a',
            {
              href: fileUrl,
              target: '_blank',
              rel: 'noopener',
              className: 'qc-plot-img-container',
              title: 'Click to view full size',
            },
            createEl('img', { src: fileUrl, alt: f.name, loading: 'lazy' })
          ),
          createEl('div', { className: 'qc-plot-info' }, [
            createEl('div', {}, [
              createEl('div', { className: 'qc-plot-title', textContent: f.name }),
              createEl('div', { className: 'qc-plot-subtitle', textContent: stepLabel }),
            ]),
            createEl('a', {
              href: fileUrl,
              target: '_blank',
              rel: 'noopener',
              className: 'btn btn-secondary btn-sm',
              textContent: 'Open',
            }),
          ]),
        ]);
        summaryGrid.appendChild(card);
      }
    }

    // 2. 13_metapeak_plots (PDF)
    const metapeakPdfs = data.files
      .filter((f) => f.category === '13_metapeak_plots' && f.name.endsWith('.pdf'))
      .sort((a, b) => a.name.localeCompare(b.name));

    const metapeakBadge = document.getElementById('metapeakCountBadge');
    if (metapeakBadge) metapeakBadge.textContent = `${metapeakPdfs.length} PDF report(s)`;
    metapeakGrid.textContent = '';

    if (!metapeakPdfs.length) {
      metapeakGrid.appendChild(
        createEl('p', { style: { color: '#64748b' }, textContent: 'No metapeak PDFs found.' })
      );
    } else {
      for (const f of metapeakPdfs) {
        metapeakGrid.appendChild(
          createEl(
            'a',
            {
              className: 'file-card-clickable',
              href: encodeResultUrl(f.path),
              target: '_blank',
              rel: 'noopener',
            },
            [
              createEl('div', { className: 'file-icon-badge badge-pdf', textContent: 'PDF' }),
              createEl('div', { className: 'file-card-details' }, [
                createEl('div', { className: 'file-card-name', textContent: f.name }),
                createEl('div', {
                  className: 'file-card-sub',
                  textContent: 'deepTools Metapeak Heatmap & Signal Matrix',
                }),
              ]),
            ]
          )
        );
      }
    }

    // 3. 14_motifs (Primary HTML reports)
    const motifHtmls = data.files
      .filter(
        (f) =>
          f.category === '14_motifs' &&
          (f.name === 'homerResults.html' || f.name === 'knownResults.html' || f.name === 'streme.html')
      )
      .sort((a, b) => a.path.localeCompare(b.path));

    const motifsBadge = document.getElementById('motifsCountBadge');
    if (motifsBadge) motifsBadge.textContent = `${motifHtmls.length} primary HTML report(s)`;
    motifsGrid.textContent = '';

    if (!motifHtmls.length) {
      motifsGrid.appendChild(
        createEl('p', { style: { color: '#64748b' }, textContent: 'No primary motif HTML reports found.' })
      );
    } else {
      for (const f of motifHtmls) {
        const subLabel =
          f.name === 'homerResults.html'
            ? 'HOMER De Novo Motifs HTML Report'
            : f.name === 'knownResults.html'
              ? 'HOMER Known Transcription Factor Motifs'
              : 'MEME STREME De Novo Motifs HTML Report';
        const folderTag = f.subfolder ? f.subfolder.split('/').pop() : '';
        const title = folderTag ? `${f.name} (${folderTag})` : f.name;

        motifsGrid.appendChild(
          createEl(
            'a',
            {
              className: 'file-card-clickable',
              href: encodeResultUrl(f.path),
              target: '_blank',
              rel: 'noopener',
            },
            [
              createEl('div', { className: 'file-icon-badge badge-html', textContent: 'HTML' }),
              createEl('div', { className: 'file-card-details' }, [
                createEl('div', { className: 'file-card-name', textContent: title }),
                createEl('div', { className: 'file-card-sub', textContent: subLabel }),
              ]),
            ]
          )
        );
      }
    }
  } catch (err) {
    summaryGrid.textContent = '';
    summaryGrid.appendChild(
      createEl('p', { style: { color: 'var(--danger)' }, textContent: `Failed to load results: ${err.message}` })
    );
  }
}

