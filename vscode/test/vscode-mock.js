// テスト用の、VS Code の API（extension.js が使う部分だけ）の代わり。
// 呼ばれた内容（表示したメッセージ・エラーと警告など）を記録し、テストから調べられるようにする。
'use strict';

const fs = require('node:fs');

class Emitter {
  constructor() {
    this.listeners = [];
    this.event = (listener) => {
      this.listeners.push(listener);
      return { dispose: () => (this.listeners = this.listeners.filter((l) => l !== listener)) };
    };
  }
  fire(value) {
    return Promise.all(this.listeners.map((l) => l(value)));
  }
}

class Uri {
  constructor(fsPath) {
    this.fsPath = fsPath;
    this.scheme = 'file';
  }
  static file(fsPath) {
    return new Uri(fsPath);
  }
  static joinPath(base, ...parts) {
    return new Uri(require('node:path').join(base.fsPath, ...parts));
  }
  toString() {
    return 'file://' + this.fsPath;
  }
}

class Range {
  constructor(startLine, startCharacter, endLine, endCharacter) {
    this.start = { line: startLine, character: startCharacter };
    this.end = { line: endLine, character: endCharacter };
  }
}

class Diagnostic {
  constructor(range, message, severity) {
    this.range = range;
    this.message = message;
    this.severity = severity;
  }
}

// TextDocument の代わり。内容はファイルから読む
class TextDocument {
  constructor(fsPath, languageId = 'reportmd') {
    this.uri = Uri.file(fsPath);
    this.languageId = languageId;
    this.isDirty = false;
    this.text = null; // 保存していない内容（null ならファイルの内容）
  }
  getText() {
    return this.text !== null ? this.text : fs.readFileSync(this.uri.fsPath, 'utf8');
  }
  async save() {
    if (this.text !== null) fs.writeFileSync(this.uri.fsPath, this.text);
    this.text = null;
    this.isDirty = false;
    return true;
  }
}

// WebviewPanel の代わり。拡張機能が送ったメッセージを messages に記録する。
// receive で、Webview から拡張機能へのメッセージを送れる
class WebviewPanel {
  constructor(viewType, title) {
    this.viewType = viewType;
    this.title = title;
    this.messages = [];
    this.revealed = 0;
    this.disposed = false;
    this.receiveEvent = new Emitter();
    this.disposeEvent = new Emitter();
    this.webview = {
      html: '',
      options: {},
      cspSource: 'vscode-webview://test',
      asWebviewUri: (uri) => 'vscode-webview://test' + uri.fsPath,
      postMessage: async (message) => {
        this.messages.push(message);
        return true;
      },
      onDidReceiveMessage: this.receiveEvent.event,
    };
    this.onDidDispose = this.disposeEvent.event;
  }
  reveal() {
    this.revealed++;
  }
  receive(message) {
    return this.receiveEvent.fire(message);
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.disposeEvent.fire();
  }
}

class RelativePattern {
  constructor(base, pattern) {
    this.base = base;
    this.pattern = pattern;
  }
}

function createMock() {
  const events = {
    open: new Emitter(),
    save: new Emitter(),
    change: new Emitter(),
    close: new Emitter(),
    activeEditor: new Emitter(),
  };
  const record = { messages: [], executed: [], output: [], panels: [], watchers: [] };
  const diagnostics = new Map(); // fsPath → Diagnostic[]
  const commands = new Map();
  const settings = {};
  const contexts = {};

  const statusBarItem = () => ({ text: '', tooltip: '', command: undefined, visible: false, show() { this.visible = true; }, hide() { this.visible = false; }, dispose() {} });
  const message = (kind) => (text, ...items) => {
    record.messages.push({ kind, text });
    return Promise.resolve(undefined);
  };

  const vscode = {
    Uri,
    Range,
    RelativePattern,
    Diagnostic,
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    StatusBarAlignment: { Left: 1, Right: 2 },
    ProgressLocation: { SourceControl: 1, Window: 10, Notification: 15 },
    ViewColumn: { Active: -1, Beside: -2 },
    window: {
      activeTextEditor: undefined,
      createOutputChannel: () => ({
        append: (text) => record.output.push(text),
        appendLine: (text) => record.output.push(text + '\n'),
        show() {},
        dispose() {},
      }),
      createStatusBarItem: statusBarItem,
      showInformationMessage: message('info'),
      showWarningMessage: message('warning'),
      showErrorMessage: message('error'),
      setStatusBarMessage: (text) => {
        record.messages.push({ kind: 'status', text });
        return { dispose() {} };
      },
      withProgress: (options, task) => task({ report() {} }),
      createWebviewPanel: (viewType, title) => {
        const panel = new WebviewPanel(viewType, title);
        record.panels.push(panel);
        return panel;
      },
      registerWebviewPanelSerializer: () => ({ dispose() {} }),
      onDidChangeActiveTextEditor: events.activeEditor.event,
    },
    languages: {
      createDiagnosticCollection: () => ({
        set: (uri, list) => diagnostics.set(uri.fsPath, list),
        delete: (uri) => diagnostics.delete(uri.fsPath),
        dispose() {},
      }),
    },
    workspace: {
      textDocuments: [],
      getConfiguration: () => ({ get: (key, fallback) => (key in settings ? settings[key] : fallback) }),
      openTextDocument: async (uri) => new TextDocument(uri.fsPath),
      // ファイルの変更の監視の代わり。テストから change を呼んで、変更を知らせる
      createFileSystemWatcher: (pattern) => {
        const change = new Emitter();
        const watcher = {
          pattern,
          onDidChange: change.event,
          onDidCreate: change.event,
          change: () => change.fire(),
          disposed: false,
          dispose() {
            this.disposed = true;
          },
        };
        record.watchers.push(watcher);
        return watcher;
      },
      onDidOpenTextDocument: events.open.event,
      onDidSaveTextDocument: events.save.event,
      onDidChangeTextDocument: events.change.event,
      onDidCloseTextDocument: events.close.event,
    },
    commands: {
      registerCommand: (name, fn) => {
        commands.set(name, fn);
        return { dispose() {} };
      },
      executeCommand: async (name, ...args) => {
        if (name === 'setContext') {
          contexts[args[0]] = args[1];
          return;
        }
        if (commands.has(name)) return commands.get(name)(...args);
        record.executed.push({ name, args });
      },
    },
  };

  return { vscode, events, record, diagnostics, commands, settings, contexts, TextDocument, WebviewPanel };
}

// install は、require('vscode') が、この代わりを返すようにする。
function install(vscode) {
  const Module = require('node:module');
  const load = Module._load;
  Module._load = function (request, ...rest) {
    if (request === 'vscode') return vscode;
    return load.call(this, request, ...rest);
  };
}

module.exports = { createMock, install };
