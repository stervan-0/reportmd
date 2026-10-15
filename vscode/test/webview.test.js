// プレビューの画面（media/preview.js）のテスト。Webview の代わりに、ヘッドレスの Chrome（または Edge）で
// 実際の HTML（preview.js が作るもの）を開き、pdf.js で PDF のページが描かれることを確かめる。
// Chrome が見つからなければ飛ばす（環境変数 CHROME_PATH で指定できる）。
const test = require('node:test');
const assert = require('node:assert');
const cp = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { createMock, install } = require('./vscode-mock');

const root = path.join(__dirname, '..');

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  return candidates.find((file) => fs.existsSync(file));
}

// samplePdf は、色の付いた四角を1つずつ描いたページ（青・赤）からなる PDF を作る（フォントを使わない）。
function samplePdf(colors) {
  const objects = [];
  const pageIds = colors.map((_, i) => 3 + i * 2);
  objects[1] = '<< /Type /Catalog /Pages 2 0 R >>';
  objects[2] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${colors.length} >>`;
  colors.forEach((rgb, i) => {
    const content = `${rgb} rg 0 0 300 400 re f`;
    objects[3 + i * 2] = `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents ${4 + i * 2} 0 R >>`;
    objects[4 + i * 2] = `<< /Length ${content.length} >>\nstream\n${content}\nendstream`;
  });
  let out = '%PDF-1.4\n';
  const offsets = [];
  for (let id = 1; id < objects.length; id++) {
    offsets[id] = out.length;
    out += `${id} 0 obj\n${objects[id]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objects.length}\n0000000000 65535 f \n`;
  for (let id = 1; id < objects.length; id++) out += `${String(offsets[id]).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objects.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}

const chromePath = findChrome();
const pdfjsReady = fs.existsSync(path.join(root, 'media', 'pdfjs', 'pdf.min.mjs'));
const skip = !chromePath
  ? 'Chrome が見つからないため飛ばす（CHROME_PATH で指定できる）'
  : !pdfjsReady
    ? 'media/pdfjs がないため飛ばす（npm install で用意される）'
    : false;

test('プレビューの画面', { skip, timeout: 60000 }, async (t) => {
  const mock = createMock();
  install(mock.vscode);
  const { Preview, _html } = require('../preview');
  Preview.extensionUri = mock.vscode.Uri.file(root);

  // Webview の HTML を、Webview の代わりの小さなサーバーから配る。
  // acquireVsCodeApi の代わりを先に置き、拡張機能からのメッセージは window.postMessage で送る
  const pdfs = [samplePdf(['0 0 1', '1 0 0']), samplePdf(['0 1 0', '1 0 0', '0 0 1'])];
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    if (url === '/') {
      const origin = `http://localhost:${server.address().port}`;
      const webview = {
        cspSource: origin,
        asWebviewUri: (uri) => origin + '/' + path.relative(root, uri.fsPath).split(path.sep).join('/'),
      };
      let page = _html(webview, '/r/report.pdf');
      const nonce = /nonce-([^']+)'/.exec(page)[1];
      const stub = `<script nonce="${nonce}">
        window.received = [];
        window.acquireVsCodeApi = () => ({
          postMessage: (m) => window.received.push(m),
          getState: () => null,
          setState: (s) => (window.savedState = s),
        });
      </script>`;
      page = page.replace('<script nonce', stub + '\n<script nonce');
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      return res.end(page);
    }
    const m = /^\/pdf(\d)$/.exec(url);
    if (m) {
      res.writeHead(200, { 'content-type': 'application/pdf' });
      return res.end(pdfs[Number(m[1])]);
    }
    const file = path.join(root, url);
    if (!file.startsWith(path.join(root, 'media')) || !fs.existsSync(file)) {
      res.writeHead(404);
      return res.end();
    }
    const type = /\.m?js$/.test(file) ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'application/octet-stream';
    res.writeHead(200, { 'content-type': type });
    res.end(fs.readFileSync(file));
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => server.close());

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'reportmd-chrome-'));
  const chrome = cp.spawn(chromePath, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    '--window-size=600,800',
    'about:blank',
  ]);
  t.after(() => {
    chrome.kill();
    setTimeout(() => fs.rmSync(profile, { recursive: true, force: true }), 1000);
  });

  // DevTools の接続先（標準エラー出力に表示される）
  const wsUrl = await new Promise((resolve, reject) => {
    let text = '';
    chrome.stderr.on('data', (d) => {
      text += d;
      const m = /DevTools listening on (ws:\S+)/.exec(text);
      if (m) resolve(m[1]);
    });
    chrome.on('exit', () => reject(new Error('Chrome が終了しました: ' + text)));
  });
  const browser = new WebSocket(wsUrl);
  await new Promise((r) => browser.addEventListener('open', r));
  let id = 0;
  const pending = new Map();
  const errors = [];
  browser.addEventListener('message', (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    } else if (m.method === 'Runtime.exceptionThrown') {
      errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    } else if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') {
      errors.push(m.params.args.map((a) => a.value ?? a.description).join(' '));
    }
  });
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve) => {
      const n = ++id;
      pending.set(n, resolve);
      browser.send(JSON.stringify({ id: n, method, params, sessionId }));
    });
  const { result } = await send('Target.createTarget', { url: 'about:blank' });
  const { result: attached } = await send('Target.attachToTarget', { targetId: result.targetId, flatten: true });
  const session = attached.sessionId;
  t.after(() => browser.close());
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, session);
    return r.result.result.value;
  };
  const waitUntil = async (expression, what, timeout = 20000) => {
    const start = Date.now();
    for (;;) {
      if (await evaluate(expression)) return;
      if (Date.now() - start > timeout) throw new Error(`待ちきれませんでした: ${what}（${errors.join(' / ')}）`);
      await new Promise((r) => setTimeout(r, 100));
    }
  };
  await send('Runtime.enable', {}, session);
  await send('Page.enable', {}, session);
  await send('Page.navigate', { url: `http://localhost:${server.address().port}/` }, session);

  // 拡張機能へ「準備ができた」と知らせる
  await waitUntil(`window.received && window.received.some((m) => m.type === 'ready')`, 'ready');

  // PDF を送ると、ページの数だけ枠ができ、見えているページが描かれる
  const sendPdf = (n) =>
    evaluate(`fetch('/pdf${n}').then((r) => r.arrayBuffer()).then((b) => { window.postMessage({ type: 'pdf', data: new Uint8Array(b) }, '*'); return true; })`);
  await sendPdf(0);
  await waitUntil(`document.querySelectorAll('.page canvas').length === 2`, '2ページの描画');
  // 1ページ目の真ん中は青（PDF のとおりに描けている）
  const color = (index) =>
    evaluate(`(() => {
      const c = document.querySelectorAll('.page')[${index}].querySelector('canvas');
      const d = c.getContext('2d').getImageData(c.width / 2, c.height / 2, 1, 1).data;
      return [d[0], d[1], d[2]].join(',');
    })()`);
  assert.strictEqual(await color(0), '0,0,255');
  assert.strictEqual(await color(1), '255,0,0');
  assert.match(await evaluate(`document.getElementById('pages').textContent`), /1 \/ 2 ページ/);
  assert.match(await evaluate(`document.getElementById('status').textContent`), /^更新/);

  // 少し下へ動かしてから、別の PDF（3ページ）を送ると、位置を保ったまま描き直す
  await evaluate(`document.getElementById('viewer').scrollTop = 300; true`);
  await new Promise((r) => setTimeout(r, 300));
  const before = await evaluate(`document.getElementById('viewer').scrollTop`);
  await sendPdf(1);
  await waitUntil(`document.querySelectorAll('.page').length === 3 && document.querySelectorAll('.page canvas').length >= 2`, '3ページの描画');
  await waitUntil(`(() => { const c = document.querySelector('.page canvas'); const d = c.getContext('2d').getImageData(c.width/2, c.height/2, 1, 1).data; return d[1] === 255 && d[0] === 0; })()`, '1ページ目が緑に変わる');
  assert.strictEqual(await evaluate(`document.getElementById('viewer').scrollTop`), before);

  // 倍率を変える（＋ボタン）と、ページが大きくなり、状態に保存される
  const width = await evaluate(`document.querySelector('.page').getBoundingClientRect().width`);
  await evaluate(`document.getElementById('zoom-in').click(); true`);
  await waitUntil(`document.querySelector('.page').getBoundingClientRect().width > ${width}`, '拡大');
  assert.strictEqual(typeof (await evaluate(`window.savedState.zoom`)), 'number');
  assert.strictEqual(await evaluate(`window.savedState.pdf`), '/r/report.pdf');

  // 状態（生成中・エラー）と、PDF がないことの表示
  await evaluate(`window.postMessage({ type: 'status', kind: 'error', text: 'PDF を生成できませんでした' }, '*'); true`);
  await waitUntil(`document.getElementById('status').className === 'error'`, 'エラーの表示');
  await evaluate(`window.postMessage({ type: 'missing', text: 'まだありません' }, '*'); true`);
  await waitUntil(`!document.getElementById('message').hidden && document.getElementById('viewer').hidden`, 'PDF がないことの表示');

  assert.deepStrictEqual(errors, []);
});
