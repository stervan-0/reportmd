// 拡張機能の動作のテスト。VS Code の API の代わり（vscode-mock.js）の上で extension.js を動かし、
// 実際に reportmd を実行して、エラー・警告の表示・PDF の生成・監視を確かめる。
//   - Windows の Node.js で WSL のフォルダから実行した場合は、wsl.exe を通して WSL の reportmd を使う
//   - reportmd は、環境変数 REPORTMD_PATH（なければ PATH の reportmd）。実行できなければ飛ばす
const test = require('node:test');
const assert = require('node:assert');
const cp = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createMock, install } = require('./vscode-mock');
const { wslLocation, commandLine } = require('../lib/command');

// 一時ディレクトリ。WSL の reportmd を使う場合は、WSL の /tmp に作る
function tempRoot() {
  const wsl = process.platform === 'win32' && wslLocation(__dirname);
  return wsl ? `\\\\wsl.localhost\\${wsl.distro}\\tmp` : os.tmpdir();
}

function reportmdAvailable() {
  const line = commandLine(process.env.REPORTMD_PATH || 'reportmd', ['version'], tempRoot(), process.platform);
  const result = cp.spawnSync(line.command, line.args, { cwd: line.cwd, encoding: 'utf8', windowsHide: true });
  return result.status === 0;
}

// 0.2.0 以降（.reportmd を受け付ける）の reportmd があり、PDF を作れるか
function pdfAvailable() {
  const line = commandLine(process.env.REPORTMD_PATH || 'reportmd', ['doctor'], tempRoot(), process.platform);
  return cp.spawnSync(line.command, line.args, { cwd: line.cwd, windowsHide: true }).status === 0;
}

const available = reportmdAvailable();
const skip = available ? false : 'reportmd を実行できないため飛ばす（REPORTMD_PATH で指定できる）';

async function waitFor(condition, what, timeout = 60000) {
  const start = Date.now();
  while (!condition()) {
    if (Date.now() - start > timeout) throw new Error(`待ちきれませんでした: ${what}`);
    await new Promise((r) => setTimeout(r, 100));
  }
}

test('拡張機能', { skip }, async (t) => {
  const mock = createMock();
  install(mock.vscode);
  if (process.env.REPORTMD_PATH) mock.settings.path = process.env.REPORTMD_PATH;
  mock.settings.openPdf = 'none';
  const extension = require('../extension');
  const subscriptions = [];
  extension.activate({ subscriptions, extensionUri: mock.vscode.Uri.file(path.join(__dirname, '..')) });

  const dir = fs.mkdtempSync(path.join(tempRoot(), 'reportmd-vscode-'));
  t.after(() => {
    extension.deactivate();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const write = (name, text) => {
    fs.writeFileSync(path.join(dir, name), text);
    return path.join(dir, name);
  };
  const open = async (file) => {
    const doc = new mock.TextDocument(file);
    mock.vscode.workspace.textDocuments.push(doc);
    mock.vscode.window.activeTextEditor = { document: doc };
    await mock.events.open.fire(doc);
    await mock.events.activeEditor.fire(mock.vscode.window.activeTextEditor);
    return doc;
  };
  const diagnosticsOf = (file) => (mock.diagnostics.get(file) || []).map((d) => ({
    line: d.range.start.line,
    character: d.range.start.character,
    severity: d.severity,
    message: d.message.split('\n')[0],
  }));

  await t.test('開いたときと保存したときに、エラー・警告を表示する', async () => {
    const file = write('ref.reportmd', '#1 はじめに\n\n本文で @missing と @ok を参照。\n\n![f:図](a.png){#ok}\n');
    const doc = await open(file);
    assert.deepStrictEqual(diagnosticsOf(file), [
      { line: 2, character: 4, severity: 1, message: '参照先の図表・数式が見つかりません: @missing（{#missing} で名前を付けてください）' },
    ]);

    // 直して保存すると、消える
    write('ref.reportmd', '#1 はじめに\n\n本文で @ok を参照。\n\n![f:図](a.png){#ok}\n');
    await mock.events.save.fire(doc);
    assert.deepStrictEqual(diagnosticsOf(file), []);

    // 構文の誤りは、その行に表示する
    write('ref.reportmd', '本文\n\n![t:表がない]\n\n本文\n');
    await mock.events.save.fire(doc);
    const [d] = diagnosticsOf(file);
    assert.strictEqual(d.line, 2);
    assert.strictEqual(d.severity, 0);
  });

  await t.test('設定ファイルの誤りは、設定ファイルの項目の位置に表示する', async () => {
    const report = write('ref.reportmd', '本文\n');
    const setting = write('setting.json', '{\n  "text": {\n    "font_size": "99pt"\n  },\n  "unknown": 1\n}\n');
    await mock.events.save.fire(new mock.TextDocument(setting, 'json'));
    const found = diagnosticsOf(setting);
    assert.strictEqual(found.length, 1, JSON.stringify(found));
    assert.deepStrictEqual([found[0].line, found[0].character, found[0].severity], [2, 4, 0]);
    assert.match(found[0].message, /text\.font_size/);

    // 直せば、両方とも消える（未知のキーは警告）
    write('setting.json', '{\n  "text": {\n    "font_size": "11pt"\n  },\n  "unknown": 1\n}\n');
    await mock.events.save.fire(new mock.TextDocument(setting, 'json'));
    assert.deepStrictEqual(diagnosticsOf(setting).map((d) => [d.line, d.severity]), [[4, 1]]);
    assert.deepStrictEqual(diagnosticsOf(report), []);
    fs.rmSync(setting);
  });

  await t.test('ステータスバーのボタンと、監視の状態', async () => {
    await mock.events.activeEditor.fire(mock.vscode.window.activeTextEditor);
    assert.strictEqual(mock.contexts['reportmd.watching'], false);
  });

  await t.test('PDF を生成する', { skip: pdfAvailable() ? false : 'PDF を生成できない環境のため飛ばす' }, async () => {
    const file = write('build.reportmd', '#1 はじめに\n\n本文\n');
    await open(file);
    await mock.commands.get('reportmd.build')();
    assert.ok(fs.existsSync(path.join(dir, 'build.pdf')), JSON.stringify(mock.record.messages));
    assert.ok(mock.record.messages.some((m) => m.kind === 'status' && m.text.includes('build.pdf を出力しました')));
  });

  await t.test('監視して、保存のたびに生成し直し、止める', { skip: pdfAvailable() ? false : 'PDF を生成できない環境のため飛ばす' }, async () => {
    const file = write('watch.reportmd', '本文\n');
    const doc = await open(file);
    await mock.commands.get('reportmd.watch')();
    const { watches } = extension._test;
    assert.ok(watches.has(file));
    assert.strictEqual(mock.contexts['reportmd.watching'], true);
    const output = () => mock.record.output.join('');
    await waitFor(() => output().includes('watch.pdf を出力しました'), '最初の生成');

    // 誤りのある内容にすると、監視の出力から、エラーを表示する
    write('watch.reportmd', '本文\n\n![t:表がない]\n\n本文\n');
    await waitFor(() => diagnosticsOf(file).length === 1, '誤りの表示');
    assert.strictEqual(diagnosticsOf(file)[0].line, 2);
    // 直すと消える
    write('watch.reportmd', '直した本文\n');
    await waitFor(() => diagnosticsOf(file).length === 0, '誤りの表示が消える');

    const child = watches.get(file).process;
    await mock.commands.get('reportmd.stopWatch')();
    assert.ok(!watches.has(file));
    assert.strictEqual(mock.contexts['reportmd.watching'], false);
    await waitFor(() => child.exitCode !== null || child.signalCode !== null, '監視のプロセスの終了', 10000);
    assert.ok(doc);
  });

  await t.test('プレビュー：横に表示し、監視して、生成し直すたびに表示し直す', { skip: pdfAvailable() ? false : 'PDF を生成できない環境のため飛ばす' }, async () => {
    const file = write('preview.reportmd', '#1 はじめに\n\n本文\n');
    const pdf = path.join(dir, 'preview.pdf');
    await open(file);
    await mock.commands.get('reportmd.preview')();
    const panel = mock.record.panels.at(-1);
    assert.strictEqual(panel.title, 'プレビュー: preview.pdf');
    assert.match(panel.webview.html, /Content-Security-Policy/);
    assert.match(panel.webview.html, /media\/preview\.js|media\\preview\.js/);

    // Webview の準備ができると、PDF を送る（まだなければ、ないことを知らせる）
    await panel.receive({ type: 'ready' });
    const { watches } = extension._test;
    assert.ok(watches.has(file), 'プレビューを開くと監視を始める');
    const pdfMessages = () => panel.messages.filter((m) => m.type === 'pdf');
    await waitFor(() => pdfMessages().length >= 1, '最初の PDF');
    const first = pdfMessages()[0].data;
    assert.strictEqual(Buffer.from(first.subarray(0, 4)).toString('latin1'), '%PDF');

    // 書き直すと、監視が生成し直し、プレビューに新しい PDF を送る
    const count = pdfMessages().length;
    write('preview.reportmd', '#1 はじめに\n\n書き直した本文\n\n^\n\n2ページ目\n');
    await waitFor(() => pdfMessages().length > count, '生成し直した PDF');
    assert.ok(panel.messages.some((m) => m.type === 'status' && m.kind === 'building'), '生成中であることを知らせる');

    // 誤りがあると、プレビューにエラーを表示する（PDF は前のまま）
    write('preview.reportmd', '本文\n\n![t:表がない]\n');
    await waitFor(() => panel.messages.some((m) => m.type === 'status' && m.kind === 'error'), 'エラーの表示');

    // PDF のファイルが変わったら（ほかで生成した場合も）、表示し直す
    const before = pdfMessages().length;
    mock.record.watchers.find((w) => w.pattern.pattern === 'preview.pdf').change();
    await waitFor(() => pdfMessages().length > before, 'ファイルの変更での表示し直し', 5000);

    // 同じ PDF のプレビューは、もう1つ作らずに前に出す
    await mock.commands.get('reportmd.preview')();
    assert.strictEqual(mock.record.panels.filter((p) => p.title === 'プレビュー: preview.pdf').length, 1);
    assert.ok(panel.revealed >= 1);

    // プレビューを閉じると、プレビューから始めた監視も止まる
    const child = watches.get(file).process;
    panel.dispose();
    assert.ok(!watches.has(file));
    await waitFor(() => child.exitCode !== null || child.signalCode !== null, '監視のプロセスの終了', 10000);
    assert.ok(fs.existsSync(pdf));
  });

  await t.test('プレビュー：PDF を生成すると、プレビューに表示する（openPdf が preview のとき）', { skip: pdfAvailable() ? false : 'PDF を生成できない環境のため飛ばす' }, async () => {
    mock.settings.openPdf = 'preview';
    const file = write('built.reportmd', '本文\n');
    await open(file);
    await mock.commands.get('reportmd.build')();
    const panel = mock.record.panels.find((p) => p.title === 'プレビュー: built.pdf');
    assert.ok(panel, 'プレビューを開く');
    await panel.receive({ type: 'ready' });
    await waitFor(() => panel.messages.some((m) => m.type === 'pdf'), 'PDF');
    assert.ok(!extension._test.watches.has(file), 'PDF を生成するだけでは、監視は始めない');
    panel.dispose();
    mock.settings.openPdf = 'none';
  });
});
