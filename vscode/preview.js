// PDF のプレビュー。VS Code の Webview の中で、pdf.js で PDF を表示する。
// PDF が書き換わったら（reportmd の build・watch が生成し直したら）、表示している位置と倍率のまま表示し直す。
'use strict';

const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const VIEW_TYPE = 'reportmd.preview';

class Preview {
  /** @type {Map<string, Preview>} PDF のパス → プレビュー */
  static panels = new Map();
  static extensionUri;

  // show は、PDF のプレビューを表示する（既にあれば、それを前に出して表示し直す）。
  static show(pdf, { preserveFocus = true } = {}) {
    const existing = Preview.panels.get(pdf);
    if (existing) {
      existing.panel.reveal(undefined, preserveFocus);
      existing.reload();
      return existing;
    }
    const panel = vscode.window.createWebviewPanel(
      VIEW_TYPE,
      title(pdf),
      { viewColumn: vscode.ViewColumn.Beside, preserveFocus },
      webviewOptions(),
    );
    return new Preview(panel, pdf);
  }

  // revive は、VS Code を再起動したときに、前回のプレビューを元に戻す。
  static revive(panel, state) {
    if (!state || !state.pdf) {
      panel.dispose();
      return;
    }
    panel.webview.options = webviewOptions();
    new Preview(panel, state.pdf);
  }

  // reloadIfOpen は、PDF のプレビューを開いていれば表示し直す。
  static reloadIfOpen(pdf) {
    const preview = Preview.panels.get(pdf);
    if (preview) preview.reload();
  }

  // setStatus は、プレビューの上の欄に、生成の状態（生成中・エラー）を表示する。
  static setStatus(pdf, kind, text) {
    const preview = Preview.panels.get(pdf);
    if (preview) preview.panel.webview.postMessage({ type: 'status', kind, text });
  }

  constructor(panel, pdf) {
    this.panel = panel;
    this.pdf = pdf;
    this.ready = false;
    this.timer = null;
    this.onDispose = [];
    Preview.panels.set(pdf, this);

    panel.title = title(pdf);
    panel.iconPath = vscode.Uri.joinPath(Preview.extensionUri, 'media', 'preview-icon.svg');
    panel.webview.html = html(panel.webview, pdf);
    panel.webview.onDidReceiveMessage((message) => {
      if (message.type === 'ready') {
        this.ready = true;
        this.reload();
      }
    });

    // PDF が書き換わったら表示し直す（書き込みの途中で読まないよう、少し待つ）
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(vscode.Uri.file(path.dirname(pdf)), path.basename(pdf)),
    );
    const changed = () => this.reloadSoon();
    watcher.onDidChange(changed);
    watcher.onDidCreate(changed);
    this.watcher = watcher;

    panel.onDidDispose(() => {
      Preview.panels.delete(pdf);
      watcher.dispose();
      clearTimeout(this.timer);
      this.onDispose.forEach((fn) => fn());
    });
  }

  reloadSoon() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.reload(), 300);
  }

  async reload() {
    if (!this.ready) return;
    let data;
    try {
      data = await fs.promises.readFile(this.pdf);
    } catch {
      this.panel.webview.postMessage({
        type: 'missing',
        text: `${path.basename(this.pdf)} がまだありません。PDF を生成すると、ここに表示します`,
      });
      return;
    }
    // PDF の先頭（%PDF）でなければ、書き込みの途中なので、少し待って読み直す
    if (data.length < 5 || data.subarray(0, 4).toString('latin1') !== '%PDF') {
      this.reloadSoon();
      return;
    }
    this.panel.webview.postMessage({ type: 'pdf', data: new Uint8Array(data.buffer, data.byteOffset, data.length) });
  }
}

function title(pdf) {
  return `プレビュー: ${path.basename(pdf)}`;
}

function webviewOptions() {
  return {
    enableScripts: true,
    retainContextWhenHidden: true,
    localResourceRoots: [vscode.Uri.joinPath(Preview.extensionUri, 'media')],
  };
}

// html は、プレビューの Webview の HTML を返す。スクリプトは media/preview.js（pdf.js を使う）。
function html(webview, pdf) {
  const media = (file) => webview.asWebviewUri(vscode.Uri.joinPath(Preview.extensionUri, 'media', file));
  const nonce = crypto.randomBytes(16).toString('base64');
  const csp = [
    "default-src 'none'",
    `img-src ${webview.cspSource} data: blob:`,
    `style-src ${webview.cspSource}`,
    `script-src 'nonce-${nonce}' ${webview.cspSource}`,
    `connect-src ${webview.cspSource}`,
    'worker-src blob:',
    `font-src ${webview.cspSource} data:`,
  ].join('; ');
  const state = JSON.stringify({ pdf }).replace(/</g, '\\u003c');
  return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${media('preview.css')}">
</head>
<body>
<div id="toolbar">
  <button id="zoom-out" title="縮小（Ctrl+マウスホイールでも変えられる）">−</button>
  <select id="zoom" title="倍率">
    <option value="width">幅に合わせる</option>
    <option value="page">ページ全体</option>
    <option value="0.5">50%</option>
    <option value="0.75">75%</option>
    <option value="1">100%</option>
    <option value="1.25">125%</option>
    <option value="1.5">150%</option>
    <option value="2">200%</option>
    <option value="custom" hidden></option>
  </select>
  <button id="zoom-in" title="拡大">＋</button>
  <span id="pages"></span>
  <span id="status"></span>
</div>
<div id="viewer"></div>
<div id="message" hidden></div>
<script nonce="${nonce}" id="initial-state" type="application/json">${state}</script>
<script nonce="${nonce}" type="module" src="${media('preview.js')}"></script>
</body>
</html>`;
}

// _html は、テストで Webview の HTML を作るためのもの
module.exports = { Preview, VIEW_TYPE, _html: html };
