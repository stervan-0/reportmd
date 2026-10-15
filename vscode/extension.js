// reportmd の VS Code 拡張機能。
//   - 保存するたびに reportmd check を実行し、エラー・警告を波線と「問題」パネルに表示する
//   - PDF の生成（build）と、保存のたびに生成し直す監視（watch）を、ボタンとコマンドから実行する
//   - 生成した PDF を、VS Code の中のプレビュー（preview.js）に表示する
// reportmd 本体（コマンド）を呼び出すだけで、文書の変換はすべて本体が行う。
'use strict';

const vscode = require('vscode');
const cp = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { parseDiagnostics, referencesIn, findReferences, settingKeyIn, findSettingKey } = require('./lib/output');
const { commandLine, resolveExecutable, isNotFound } = require('./lib/command');
const { Preview, VIEW_TYPE } = require('./preview');

const SETTING_FILE = 'setting.json';

let output; // 出力パネル（reportmd の出力をそのまま表示する）
let diagnostics; // エラー・警告
let buildItem; // ステータスバーの「PDF」ボタン
let watchItem; // ステータスバーの「監視」ボタン

const checks = new Map(); // 文書のパス → 実行中の check
const watches = new Map(); // 文書のパス → 実行中の watch（{ process, buffer }）
const reported = new Map(); // 文書のパス → その文書の結果を表示したファイルの URI（次の結果で消す）
let notFoundShown = false;

function activate(context) {
  output = vscode.window.createOutputChannel('reportmd');
  diagnostics = vscode.languages.createDiagnosticCollection('reportmd');
  Preview.extensionUri = context.extensionUri;

  buildItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  buildItem.command = 'reportmd.build';
  watchItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 99);

  context.subscriptions.push(
    output,
    diagnostics,
    buildItem,
    watchItem,
    vscode.commands.registerCommand('reportmd.build', (uri) => withDocument(uri, build)),
    vscode.commands.registerCommand('reportmd.watch', (uri) => withDocument(uri, startWatch)),
    vscode.commands.registerCommand('reportmd.stopWatch', (uri) => withDocument(uri, (doc) => stopWatch(doc.uri.fsPath))),
    vscode.commands.registerCommand('reportmd.check', (uri) => withDocument(uri, (doc) => check(doc, true))),
    vscode.commands.registerCommand('reportmd.preview', (uri) => withDocument(uri, preview)),
    vscode.window.registerWebviewPanelSerializer(VIEW_TYPE, {
      deserializeWebviewPanel: async (panel, state) => Preview.revive(panel, state),
    }),
    vscode.commands.registerCommand('reportmd.showOutput', () => output.show(true)),
    vscode.workspace.onDidOpenTextDocument((doc) => isReport(doc) && checkOnSave() && check(doc)),
    vscode.workspace.onDidSaveTextDocument(onSave),
    vscode.workspace.onDidCloseTextDocument(onClose),
    vscode.window.onDidChangeActiveTextEditor(updateStatusBar),
    { dispose: () => [...watches.keys()].forEach(stopWatch) },
  );

  vscode.workspace.textDocuments.filter(isReport).forEach((doc) => checkOnSave() && check(doc));
  updateStatusBar();
}

function deactivate() {
  [...watches.keys()].forEach(stopWatch);
  checks.forEach((child) => child.kill());
}

// --- 文書 -----------------------------------------------------------------

function isReport(doc) {
  return doc.languageId === 'reportmd' && doc.uri.scheme === 'file';
}

function config() {
  return vscode.workspace.getConfiguration('reportmd');
}

function checkOnSave() {
  return config().get('checkOnSave', true);
}

// withDocument は、コマンドの対象の文書（エクスプローラーから選んだファイル、なければ開いている文書）で action を実行する。
async function withDocument(uri, action) {
  let doc;
  if (uri instanceof vscode.Uri) {
    doc = await vscode.workspace.openTextDocument(uri);
  } else {
    doc = vscode.window.activeTextEditor && vscode.window.activeTextEditor.document;
  }
  if (!doc || doc.uri.scheme !== 'file' || !/\.(reportmd|rmd)$/i.test(doc.uri.fsPath)) {
    vscode.window.showWarningMessage('reportmd の文書（.reportmd）を開いてから実行してください');
    return;
  }
  return action(doc);
}

// onSave は、保存した文書を調べ直す（終わるのを待てるように Promise を返す）。
function onSave(doc) {
  if (!checkOnSave()) return;
  let targets = [];
  if (isReport(doc)) {
    targets = [doc];
  } else if (path.basename(doc.uri.fsPath) === SETTING_FILE) {
    // 設定ファイルを保存したら、同じフォルダの文書を調べ直す
    const dir = path.dirname(doc.uri.fsPath);
    targets = vscode.workspace.textDocuments.filter((d) => isReport(d) && path.dirname(d.uri.fsPath) === dir);
  }
  // 監視中は watch が生成し直してエラーを表示するので、check は実行しない
  return Promise.all(targets.filter((d) => !watches.has(d.uri.fsPath)).map((d) => check(d)));
}

function onClose(doc) {
  if (!isReport(doc)) return;
  const file = doc.uri.fsPath;
  // 監視は、文書を閉じても続ける（PDF のための監視なので）。check だけ止めて、表示を消す
  if (checks.has(file)) checks.get(file).kill();
  if (!watches.has(file)) clearReported(file);
}

// --- reportmd の実行 ------------------------------------------------------

// spawnReportmd は、文書のフォルダ dir で reportmd を実行する。
function spawnReportmd(args, dir) {
  const executable = resolveExecutable(config().get('path'), {
    platform: process.platform,
    envPath: process.env.PATH,
    home: os.homedir(),
    exists: (file) => fs.existsSync(file),
  });
  const line = commandLine(executable, args, dir, process.platform);
  return { child: cp.spawn(line.command, line.args, { cwd: line.cwd, windowsHide: true }), wsl: line.wsl };
}

// run は、reportmd を実行し、終わるまでの出力（標準出力と標準エラー出力をまとめたもの）を返す。
function run(args, dir, onStart) {
  return new Promise((resolve) => {
    const { child, wsl } = spawnReportmd(args, dir);
    if (onStart) onStart(child);
    const chunks = [];
    child.stdout.on('data', (d) => chunks.push(d));
    child.stderr.on('data', (d) => chunks.push(d));
    let failed = null;
    child.on('error', (err) => (failed = err));
    child.on('close', (code, signal) => {
      const result = {
        text: Buffer.concat(chunks).toString('utf8'),
        exitCode: code,
        errorCode: failed && failed.code,
        wsl,
        killed: signal !== null,
      };
      if (isNotFound(result)) showNotFound();
      resolve(result);
    });
  });
}

function showNotFound() {
  if (notFoundShown) return;
  notFoundShown = true;
  const open = '設定を開く';
  vscode.window
    .showErrorMessage(
      'reportmd コマンドが見つかりません。reportmd をインストール（make install）するか、設定 reportmd.path に reportmd のパスを書いてください。',
      open,
    )
    .then((choice) => choice === open && vscode.commands.executeCommand('workbench.action.openSettings', 'reportmd.path'));
}

// log は、出力パネルに、実行したコマンドと結果を書く。
function log(title, text) {
  output.appendLine(`[${new Date().toLocaleTimeString()}] ${title}`);
  if (text.trim() !== '') output.appendLine(text.replace(/\s+$/, ''));
}

// --- エラー・警告の表示 ---------------------------------------------------

// report は、文書 file を対象にした reportmd の出力を、エラー・警告として表示する。
// 前回その文書で表示したものは消す。表示したエラーの数を返す。
function report(file, text) {
  clearReported(file);
  const dir = path.dirname(file);
  const byFile = new Map();
  let errors = 0;
  for (const d of parseDiagnostics(text)) {
    // ファイル名は、文書のフォルダからの相対パス（reportmd を文書のフォルダで実行するため）
    let target = d.file === '' ? file : path.resolve(dir, d.file.replace(/\//g, path.sep));
    if (!fs.existsSync(target)) target = file;
    for (const range of rangesFor(target, file, d)) {
      const diagnostic = new vscode.Diagnostic(
        range,
        d.message,
        d.severity === 'error' ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning,
      );
      diagnostic.source = 'reportmd';
      if (!byFile.has(target)) byFile.set(target, []);
      byFile.get(target).push(diagnostic);
    }
    if (d.severity === 'error') errors++;
  }
  const uris = [];
  for (const [target, list] of byFile) {
    const uri = vscode.Uri.file(target);
    diagnostics.set(uri, list);
    uris.push(uri);
  }
  reported.set(file, uris);
  return errors;
}

function clearReported(file) {
  for (const uri of reported.get(file) || []) diagnostics.delete(uri);
  reported.delete(file);
}

// rangesFor は、エラー・警告を表示する範囲を返す。
// 行番号があればその行。なければ、メッセージの @名前 を文書の中で探し、見つからなければ先頭の行。
function rangesFor(target, file, d) {
  const text = documentText(target);
  const lines = text.split(/\r?\n/);
  const lineRange = (index) => {
    const content = lines[index] || '';
    const start = content.length - content.trimStart().length;
    return new vscode.Range(index, start, index, Math.max(content.length, start + 1));
  };
  if (d.line > 0) return [lineRange(Math.min(d.line, Math.max(lines.length, 1)) - 1)];
  if (target === file) {
    const found = referencesIn(d.message).flatMap((name) => findReferences(text, name));
    if (found.length > 0) return found.map((r) => new vscode.Range(r.line, r.start, r.line, r.end));
  } else {
    // 設定ファイルのエラーは、その項目のキーの位置
    const key = settingKeyIn(d.message);
    const found = key && findSettingKey(text, key);
    if (found) return [new vscode.Range(found.line, found.start, found.line, found.end)];
  }
  return [lineRange(0)];
}

function documentText(file) {
  const open = vscode.workspace.textDocuments.find((doc) => doc.uri.fsPath === file);
  if (open) return open.getText();
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

// --- check ----------------------------------------------------------------

// check は、reportmd check で誤りを調べて表示する。manual なら、結果を通知でも知らせる。
async function check(doc, manual = false) {
  const file = doc.uri.fsPath;
  if (manual && doc.isDirty) await doc.save();
  if (checks.has(file)) checks.get(file).kill(); // 前回の check が終わっていなければ止める
  let me;
  const result = await run(['check', path.basename(file)], path.dirname(file), (child) => {
    me = child;
    checks.set(file, child);
  });
  if (checks.get(file) === me) checks.delete(file);
  if (result.killed || isNotFound(result)) return;
  const errors = report(file, result.text);
  if (manual) {
    log(`reportmd check ${path.basename(file)}`, result.text);
    const warnings = parseDiagnostics(result.text).length - errors;
    if (errors === 0 && warnings === 0) vscode.window.showInformationMessage('問題は見つかりませんでした');
    else vscode.window.showWarningMessage(`エラー ${errors} 件・警告 ${warnings} 件（「問題」パネルに表示しています）`);
  }
}

// --- build ----------------------------------------------------------------

async function build(doc) {
  const file = doc.uri.fsPath;
  if (doc.isDirty) await doc.save();
  const args = ['build', path.basename(file)];
  if (openMode() === 'external') args.push('--open');
  const pdf = pdfPath(file);

  buildItem.text = '$(sync~spin) PDF を生成中';
  Preview.setStatus(pdf, 'building', 'PDF を生成しています…');
  const result = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Window, title: 'reportmd: PDF を生成しています' },
    () => run(args, path.dirname(file)),
  );
  updateStatusBar();
  if (isNotFound(result)) return;
  log(`reportmd ${args.join(' ')}`, result.text);
  const errors = report(file, result.text);
  if (result.exitCode === 0) {
    vscode.window.setStatusBarMessage(`$(check) ${path.basename(pdf)} を出力しました`, 5000);
    if (openMode() === 'preview') Preview.show(pdf);
  } else {
    Preview.setStatus(pdf, 'error', 'PDF を生成できませんでした（「問題」パネルを確認してください）');
    const show = '出力を表示';
    const message = errors > 0 ? `PDF を生成できませんでした（エラー ${errors} 件）` : 'PDF を生成できませんでした';
    vscode.window.showErrorMessage(message, show).then((choice) => choice === show && output.show(true));
  }
}

// openMode は、生成した PDF を開く場所（設定 reportmd.openPdf）。
// 'preview'（VS Code の中のプレビュー）・'external'（OS の PDF ビューア）・'none'
function openMode() {
  const mode = config().get('openPdf', 'preview');
  return mode === 'vscode' ? 'preview' : mode; // 'vscode' は以前の名前
}

function pdfPath(file) {
  return path.join(path.dirname(file), path.basename(file, path.extname(file)) + '.pdf');
}

// --- preview --------------------------------------------------------------

// preview は、PDF のプレビューを横に開き、監視を始める（保存のたびに生成し直して、プレビューも更新する）。
// プレビューから始めた監視は、プレビューを閉じると止める。
function preview(doc) {
  const file = doc.uri.fsPath;
  const panel = Preview.show(pdfPath(file));
  if (!watches.has(file)) {
    startWatch(doc, { fromPreview: true });
    const watch = watches.get(file);
    panel.onDispose.push(() => {
      if (watches.get(file) === watch) stopWatch(file);
    });
  }
}

// --- watch ----------------------------------------------------------------

// startWatch は、reportmd watch を起動する。fromPreview（プレビューから始めた）なら、PDF をほかで開かない。
function startWatch(doc, { fromPreview = false } = {}) {
  const file = doc.uri.fsPath;
  if (watches.has(file)) {
    vscode.window.showInformationMessage(`${path.basename(file)} は監視中です`);
    return;
  }
  if (doc.isDirty) doc.save();
  const args = ['watch', path.basename(file)];
  if (!fromPreview && openMode() === 'external') args.push('--open');
  const pdf = pdfPath(file);

  const { child, wsl } = spawnReportmd(args, path.dirname(file));
  const watch = { process: child, buffer: '', opened: fromPreview, wsl };
  watches.set(file, watch);
  if (checks.has(file)) checks.get(file).kill();
  log(`reportmd ${args.join(' ')}`, '');
  // プレビューがあれば、出力パネルは前に出さない（プレビューに状態を表示する）
  if (!fromPreview && openMode() !== 'preview') output.show(true);
  Preview.setStatus(pdf, 'building', 'PDF を生成しています…');

  const onData = (data) => {
    const text = data.toString('utf8');
    output.append(text);
    watch.buffer += text;
    // 「変更を検出しました」から先が、新しい生成の出力
    const restart = watch.buffer.lastIndexOf('変更を検出しました');
    if (restart >= 0) {
      watch.buffer = watch.buffer.slice(watch.buffer.indexOf('\n', restart) + 1);
      Preview.setStatus(pdf, 'building', 'PDF を生成しています…');
    }
    const errors = report(file, watch.buffer);
    if (/を出力しました/.test(text)) {
      if (openMode() === 'preview' && !watch.opened) {
        watch.opened = true;
        Preview.show(pdf);
      } else {
        Preview.reloadIfOpen(pdf);
      }
    } else if (errors > 0) {
      Preview.setStatus(pdf, 'error', `PDF を生成できませんでした（エラー ${errors} 件。「問題」パネルを確認してください）`);
    }
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  child.on('error', (err) => {
    if (err.code === 'ENOENT') showNotFound();
  });
  child.on('close', (code) => {
    if (watches.get(file) !== watch) return;
    watches.delete(file);
    if (isNotFound({ exitCode: code, wsl })) showNotFound();
    output.appendLine(`[${new Date().toLocaleTimeString()}] ${path.basename(file)} の監視を終了しました`);
    updateStatusBar();
  });
  updateStatusBar();
}

function stopWatch(file) {
  const watch = watches.get(file);
  if (!watch) return;
  watches.delete(file);
  watch.process.kill();
  output.appendLine(`[${new Date().toLocaleTimeString()}] ${path.basename(file)} の監視を終了しました`);
  updateStatusBar();
}

// --- ステータスバー -------------------------------------------------------

function updateStatusBar() {
  const editor = vscode.window.activeTextEditor;
  const doc = editor && editor.document;
  const watching = !!doc && watches.has(doc.uri.fsPath);
  vscode.commands.executeCommand('setContext', 'reportmd.watching', watching);
  if (!doc || !isReport(doc)) {
    buildItem.hide();
    watchItem.hide();
    return;
  }
  buildItem.text = '$(file-pdf) PDF';
  buildItem.tooltip = 'PDF を生成する（reportmd build）';
  buildItem.show();
  if (watching) {
    watchItem.text = '$(eye) 監視中';
    watchItem.tooltip = '保存のたびに PDF を生成し直しています。クリックで監視を止める';
    watchItem.command = 'reportmd.stopWatch';
  } else {
    watchItem.text = '$(eye-closed) 監視';
    watchItem.tooltip = '保存のたびに PDF を生成し直す（reportmd watch）';
    watchItem.command = 'reportmd.watch';
  }
  watchItem.show();
}

// _test は、テストから監視の状態を調べるためのもの
module.exports = { activate, deactivate, _test: { watches } };
