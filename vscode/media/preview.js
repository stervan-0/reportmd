// PDF のプレビューの Webview の中で動くスクリプト。pdf.js で PDF のページを canvas に描く。
//   - 拡張機能から PDF のデータ（{type: 'pdf', data}）を受け取るたびに表示し直す。
//     表示していた位置と倍率は保ち、描き終わるまで前の絵を残す（ちらつかないように）
//   - 画面に見えているページだけを描く（ページの多い文書でも重くならないように）
import * as pdfjsLib from './pdfjs/pdf.min.mjs';

const vscode = acquireVsCodeApi();
const viewer = document.getElementById('viewer');
const zoomSelect = document.getElementById('zoom');
const pagesLabel = document.getElementById('pages');
const statusLabel = document.getElementById('status');
const messageBox = document.getElementById('message');

const GAP = 12; // ページの間隔（px）
const ZOOM_STEPS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];

// 再起動したときに元に戻すための状態（PDF のパスは拡張機能が HTML に書く）
const initial = JSON.parse(document.getElementById('initial-state').textContent);
const saved = vscode.getState() || {};
const state = {
  pdf: initial.pdf,
  zoom: saved.zoom || 'width', // 'width'（幅に合わせる）・'page'（ページ全体）・数値（倍率）
  position: saved.position || null, // 表示していた位置（ページと、ページの中の割合）
};

let doc = null; // 表示している PDF（pdf.js の PDFDocumentProxy）
let docTask = null; // doc を読み込んだタスク（前の PDF を片付けるのに使う）
let pages = []; // { div, width, height（倍率1のときの大きさ）, rendered（描いた倍率と版）, task }
let version = 0; // 読み込んだ PDF の版（新しい PDF を読んだら増える）
let loading = Promise.resolve();

// --- pdf.js の準備 ----------------------------------------------------------

// Webview では、別の場所のスクリプトから Worker を作れないので、Worker のスクリプトを読み込み、Blob から作る
const workerReady = (async () => {
  const url = new URL('./pdfjs/pdf.worker.min.mjs', import.meta.url);
  const text = await (await fetch(url)).text();
  const blob = URL.createObjectURL(new Blob([text], { type: 'text/javascript' }));
  pdfjsLib.GlobalWorkerOptions.workerPort = new Worker(blob, { type: 'module' });
})();

// --- 拡張機能とのやりとり ---------------------------------------------------

window.addEventListener('message', (event) => {
  const message = event.data;
  switch (message.type) {
    case 'pdf':
      loading = loading.then(() => load(message.data)).catch(showError);
      break;
    case 'missing':
      showMessage(message.text);
      break;
    case 'status':
      setStatus(message.kind, message.text);
      break;
  }
});

function save() {
  vscode.setState({ pdf: state.pdf, zoom: state.zoom, position: state.position });
}

function setStatus(kind, text) {
  statusLabel.textContent = text || '';
  statusLabel.className = kind || '';
}

function showMessage(text) {
  messageBox.textContent = text;
  messageBox.hidden = false;
  viewer.hidden = true;
}

function showError(error) {
  console.error(error);
  setStatus('error', `PDF を表示できません: ${error && error.message ? error.message : error}`);
}

// --- 読み込み -----------------------------------------------------------

async function load(data) {
  await workerReady;
  const task = pdfjsLib.getDocument({ data, isEvalSupported: false });
  const next = await task.promise;
  if (doc && pages.length > 0) state.position = currentPosition();

  // ページの大きさ（倍率1）を調べる
  const sizes = [];
  for (let i = 1; i <= next.numPages; i++) {
    const page = await next.getPage(i);
    const viewport = page.getViewport({ scale: 1 });
    sizes.push({ width: viewport.width, height: viewport.height });
  }

  const oldTask = docTask;
  doc = next;
  docTask = task;
  version++;
  messageBox.hidden = true;
  viewer.hidden = false;

  // ページの枠は使い回す（前の絵は、新しい絵を描き終わるまで残す）
  while (pages.length > sizes.length) pages.pop().div.remove();
  sizes.forEach((size, index) => {
    if (!pages[index]) {
      const div = document.createElement('div');
      div.className = 'page';
      div.dataset.index = String(index);
      viewer.appendChild(div);
      observer.observe(div);
      pages[index] = { div, rendered: null, task: null, visible: false };
    }
    Object.assign(pages[index], size);
  });
  layout();
  restorePosition();
  updatePageLabel();
  // 前の PDF を片付ける（描いている途中のページは、新しい PDF で描き直す）
  if (oldTask) oldTask.destroy();
  setStatus('ok', `更新 ${new Date().toLocaleTimeString()}`);
  renderVisible();
}

// --- 倍率と配置 -----------------------------------------------------------

function scale() {
  if (typeof state.zoom === 'number') return state.zoom;
  if (pages.length === 0) return 1;
  const widest = Math.max(...pages.map((p) => p.width));
  const available = viewer.clientWidth - 2 * GAP;
  if (state.zoom === 'page') {
    const tallest = Math.max(...pages.map((p) => p.height));
    return Math.max(0.1, Math.min(available / widest, (viewer.clientHeight - 2 * GAP) / tallest));
  }
  return Math.max(0.1, available / widest);
}

function layout() {
  const s = scale();
  for (const page of pages) {
    page.div.style.width = `${Math.floor(page.width * s)}px`;
    page.div.style.height = `${Math.floor(page.height * s)}px`;
  }
  updateZoomSelect(s);
}

function updateZoomSelect(s) {
  const value = typeof state.zoom === 'number' ? String(state.zoom) : state.zoom;
  const option = [...zoomSelect.options].find((o) => o.value === value && !o.hidden);
  if (option) {
    zoomSelect.value = value;
  } else {
    const custom = zoomSelect.querySelector('option[value="custom"]');
    custom.textContent = `${Math.round(s * 100)}%`;
    zoomSelect.value = 'custom';
  }
}

function setZoom(zoom) {
  const position = currentPosition();
  state.zoom = zoom;
  layout();
  state.position = position;
  restorePosition();
  save();
  renderVisible();
}

function stepZoom(direction) {
  const current = scale();
  const next =
    direction > 0
      ? ZOOM_STEPS.find((z) => z > current + 0.001) || ZOOM_STEPS[ZOOM_STEPS.length - 1]
      : [...ZOOM_STEPS].reverse().find((z) => z < current - 0.001) || ZOOM_STEPS[0];
  setZoom(next);
}

// currentPosition は、画面の上端にあるページと、そのページの中の位置（割合）を返す。
function currentPosition() {
  const top = viewer.scrollTop;
  for (let i = 0; i < pages.length; i++) {
    const div = pages[i].div;
    if (div.offsetTop + div.offsetHeight + GAP > top) {
      return { page: i, offset: Math.max(0, (top - div.offsetTop) / div.offsetHeight), left: viewer.scrollLeft };
    }
  }
  return null;
}

function restorePosition() {
  const p = state.position;
  if (!p || pages.length === 0) return;
  const div = pages[Math.min(p.page, pages.length - 1)].div;
  viewer.scrollTop = div.offsetTop + p.offset * div.offsetHeight;
  viewer.scrollLeft = p.left || 0;
}

// --- 描画 ---------------------------------------------------------------

// 画面に入ったページ（と、その前後少し）を描く
const observer = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      const page = pages[Number(entry.target.dataset.index)];
      if (page) page.visible = entry.isIntersecting;
    }
    renderVisible();
  },
  { root: viewer, rootMargin: '100% 0px' },
);

function renderVisible() {
  const s = scale();
  pages.forEach((page, index) => {
    if (page.visible) renderPage(index, s);
  });
}

async function renderPage(index, s) {
  const page = pages[index];
  const key = `${version}@${s}`;
  if (page.rendered === key || (page.task && page.task.key === key)) return;
  if (page.task) page.task.cancel();

  const ratio = window.devicePixelRatio || 1;
  const pdfPage = await doc.getPage(index + 1);
  const viewport = pdfPage.getViewport({ scale: s * ratio });
  const canvas = document.createElement('canvas');
  canvas.width = Math.floor(viewport.width);
  canvas.height = Math.floor(viewport.height);
  canvas.style.width = `${Math.floor(page.width * s)}px`;
  canvas.style.height = `${Math.floor(page.height * s)}px`;

  const task = pdfPage.render({ canvas, viewport });
  task.key = key;
  page.task = task;
  try {
    await task.promise;
  } catch (error) {
    if (error && error.name === 'RenderingCancelledException') return;
    throw error;
  } finally {
    if (page.task === task) page.task = null;
  }
  // 描き終わってから、前の絵と入れ替える
  page.div.replaceChildren(canvas);
  page.rendered = key;
}

// --- 操作 ---------------------------------------------------------------

zoomSelect.addEventListener('change', () => {
  const value = zoomSelect.value;
  if (value === 'custom') return;
  setZoom(value === 'width' || value === 'page' ? value : Number(value));
});
document.getElementById('zoom-in').addEventListener('click', () => stepZoom(1));
document.getElementById('zoom-out').addEventListener('click', () => stepZoom(-1));

// Ctrl（Mac は Cmd）+ マウスホイールで拡大・縮小
viewer.addEventListener(
  'wheel',
  (event) => {
    if (!event.ctrlKey && !event.metaKey) return;
    event.preventDefault();
    stepZoom(event.deltaY < 0 ? 1 : -1);
  },
  { passive: false },
);

// Ctrl + / Ctrl - / Ctrl 0 でも拡大・縮小
window.addEventListener('keydown', (event) => {
  if (!event.ctrlKey && !event.metaKey) return;
  if (event.key === '+' || event.key === '=' || event.key === ';') stepZoom(1);
  else if (event.key === '-') stepZoom(-1);
  else if (event.key === '0') setZoom('width');
  else return;
  event.preventDefault();
});

let scrollTimer = null;
viewer.addEventListener('scroll', () => {
  clearTimeout(scrollTimer);
  scrollTimer = setTimeout(() => {
    state.position = currentPosition();
    save();
    updatePageLabel();
  }, 100);
});

// updatePageLabel は、「今のページ / ページ数」を表示する。
function updatePageLabel() {
  const position = currentPosition();
  const current = position ? position.page + 1 : 1;
  pagesLabel.textContent = pages.length > 0 ? `${current} / ${pages.length} ページ` : '';
}

// 幅に合わせる・ページ全体のときは、パネルの大きさが変わったら倍率も変える
new ResizeObserver(() => {
  if (typeof state.zoom === 'number' || pages.length === 0) return;
  const position = currentPosition();
  layout();
  state.position = position;
  restorePosition();
  renderVisible();
}).observe(viewer);

save();
vscode.postMessage({ type: 'ready' });
