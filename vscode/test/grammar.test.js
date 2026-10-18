// 色分け（TextMate の文法）のテスト。
// VS Code が実際に使うライブラリ（vscode-textmate）で .reportmd を字句に分け、
// 独自構文に期待どおりの scope が付くことを確かめる。
// Markdown の文法は VS Code 本体に入っているものを使うので、VS Code が見つからなければ飛ばす。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const vscodeExtensions = findVSCodeExtensions();

// VS Code の組み込み拡張機能のディレクトリを探す（環境変数 VSCODE_EXTENSIONS_DIR で指定もできる）
function findVSCodeExtensions() {
  const candidates = [];
  if (process.env.VSCODE_EXTENSIONS_DIR) candidates.push(process.env.VSCODE_EXTENSIONS_DIR);
  const roots = [
    process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs', 'Microsoft VS Code'),
    'C:\\Program Files\\Microsoft VS Code',
    '/usr/share/code',
    '/Applications/Visual Studio Code.app/Contents',
  ].filter(Boolean);
  for (const root of roots) {
    candidates.push(path.join(root, 'resources', 'app', 'extensions'));
    // 新しい VS Code は、バージョンごとのディレクトリの下にある
    try {
      for (const entry of fs.readdirSync(root)) {
        candidates.push(path.join(root, entry, 'resources', 'app', 'extensions'));
      }
    } catch {}
  }
  return candidates.find((dir) => fs.existsSync(path.join(dir, 'markdown-basics')));
}

// builtinGrammars は、VS Code の組み込み拡張機能の文法を、scopeName → ファイルの表にする。
function builtinGrammars() {
  const table = {};
  for (const name of fs.readdirSync(vscodeExtensions)) {
    const manifest = path.join(vscodeExtensions, name, 'package.json');
    if (!fs.existsSync(manifest)) continue;
    const grammars = (JSON.parse(fs.readFileSync(manifest, 'utf8')).contributes || {}).grammars || [];
    for (const g of grammars) {
      table[g.scopeName] = path.join(vscodeExtensions, name, g.path);
    }
  }
  return table;
}

async function loadRegistry() {
  const vsctm = require('vscode-textmate');
  const oniguruma = require('vscode-oniguruma');
  const wasm = fs.readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm'));
  await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));

  // VS Code の組み込みの文法（Markdown・YAML・LaTeX など。include される文法が欠けると、
  // その規則ごと働かなくなるので、すべて読めるようにする）と、この拡張機能の文法
  const grammars = builtinGrammars();
  grammars['text.reportmd'] = path.join(__dirname, '..', 'syntaxes', 'reportmd.tmLanguage.json');
  grammars['text.reportmd.inline'] = path.join(__dirname, '..', 'syntaxes', 'reportmd.injection.tmLanguage.json');
  return new vsctm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (s) => new oniguruma.OnigString(s),
    }),
    loadGrammar: async (scopeName) => {
      const file = grammars[scopeName];
      if (!file || !fs.existsSync(file)) return null;
      return vsctm.parseRawGrammar(fs.readFileSync(file, 'utf8'), file);
    },
    getInjections: (scopeName) => (scopeName === 'text.reportmd' ? ['text.reportmd.inline'] : []),
  });
}

let grammar;

// tokenize は、文書を行ごとの字句（text と scopes）に分ける。
function tokenize(source) {
  const vsctm = require('vscode-textmate');
  let state = vsctm.INITIAL; // 最初の行（\A が一致する）
  return source.split('\n').map((line) => {
    const result = grammar.tokenizeLine(line, state);
    state = result.ruleStack;
    return result.tokens.map((t) => ({ text: line.slice(t.startIndex, t.endIndex), scopes: t.scopes }));
  });
}

// scopesAt は、行 lineIndex の中で、文字列 needle の先頭を含む字句の scope を返す。
function scopesAt(lines, lineIndex, needle) {
  const line = lines[lineIndex];
  const full = line.map((t) => t.text).join('');
  const at = full.indexOf(needle);
  assert.ok(at >= 0, `${lineIndex + 1} 行目に「${needle}」がない: ${full}`);
  let offset = 0;
  for (const token of line) {
    if (at < offset + token.text.length) return token.scopes;
    offset += token.text.length;
  }
  throw new Error('unreachable');
}

function hasScope(lines, lineIndex, needle, scope) {
  const scopes = scopesAt(lines, lineIndex, needle);
  assert.ok(
    scopes.some((s) => s === scope || s.startsWith(scope + '.')),
    `「${needle}」（${lineIndex + 1} 行目）に ${scope} がない: ${scopes.join(' ')}`,
  );
}

function lacksScope(lines, lineIndex, needle, scope) {
  const scopes = scopesAt(lines, lineIndex, needle);
  assert.ok(
    !scopes.some((s) => s === scope || s.startsWith(scope + '.')),
    `「${needle}」（${lineIndex + 1} 行目）に ${scope} があってはいけない: ${scopes.join(' ')}`,
  );
}

test('色分け', { skip: vscodeExtensions ? false : 'VS Code が見つからないため飛ばす' }, async (t) => {
  const registry = await loadRegistry();
  grammar = await registry.loadGrammar('text.reportmd');

  await t.test('改ページ・右揃え・中央揃え', () => {
    const lines = tokenize('^\n\n--> 2026年10月12日\n<-> **題名**\n> --> 引用の中\n-->\n^ ではない\n-> 新しい記号\n- -> リストの中\n->text');
    hasScope(lines, 0, '^', 'keyword.control.page-break.reportmd');
    hasScope(lines, 2, '-->', 'keyword.operator.align.reportmd');
    hasScope(lines, 2, '2026', 'meta.align.reportmd');
    hasScope(lines, 3, '<->', 'keyword.operator.align.reportmd');
    hasScope(lines, 3, '題名', 'markup.bold');
    hasScope(lines, 4, '-->', 'keyword.operator.align.reportmd');
    hasScope(lines, 5, '-->', 'keyword.operator.align.reportmd');
    lacksScope(lines, 6, '^', 'keyword.control.page-break.reportmd');
    hasScope(lines, 7, '->', 'keyword.operator.align.reportmd');
    hasScope(lines, 8, '->', 'keyword.operator.align.reportmd');
    lacksScope(lines, 9, '->', 'keyword.operator.align.reportmd');
  });

  await t.test('番号付き見出しと、通常の見出し', () => {
    const lines = tokenize('#1 はじめに\n\n#2 方法と $x$\n\n# 番号なし\n\n#12 ではない');
    hasScope(lines, 0, '#1', 'punctuation.definition.heading.reportmd');
    hasScope(lines, 0, 'はじめに', 'entity.name.section.reportmd');
    hasScope(lines, 2, 'x', 'markup.math.inline.reportmd');
    hasScope(lines, 4, '番号なし', 'markup.heading');
    lacksScope(lines, 6, '#12', 'markup.heading.reportmd');
  });

  await t.test('図と表の見出し', () => {
    const lines = tokenize('![f:処理の流れ](images/a.png){#flow width=90%}\n\n![t:結果]{#result}\n| a | b |\n|---|---|\n\n![t:結果] 余計');
    hasScope(lines, 0, 'f', 'keyword.other.figure.reportmd');
    hasScope(lines, 0, '処理の流れ', 'string.other.caption.reportmd');
    hasScope(lines, 0, 'images/a.png', 'markup.underline.link.image.markdown');
    hasScope(lines, 0, 'flow', 'entity.name.label.reportmd');
    hasScope(lines, 0, 'width', 'entity.other.attribute-name.reportmd');
    hasScope(lines, 2, 't', 'keyword.other.table.reportmd');
    hasScope(lines, 2, 'result', 'entity.name.label.reportmd');
    hasScope(lines, 6, ' 余計', 'invalid.illegal.reportmd');
  });

  await t.test('数式と参照', () => {
    const source = [
      '本文の $E = mc^2$ と @energy を参照。@fig1に示す。',
      '',
      '$$',
      '\\frac{1}{2} m v^2',
      '$$ {#energy}',
      '',
      '運動エネルギーは',
      '$$',
      'K',
      '$$ {-}',
      'で表される。mail@example.com',
    ].join('\n');
    const lines = tokenize(source);
    hasScope(lines, 0, 'E = mc', 'markup.math.inline.reportmd');
    hasScope(lines, 0, '@energy', 'variable.other.reference.reportmd');
    hasScope(lines, 0, 'fig1', 'variable.other.reference.reportmd');
    lacksScope(lines, 0, 'に示す', 'variable.other.reference.reportmd');
    hasScope(lines, 2, '$$', 'punctuation.definition.math.begin.reportmd');
    hasScope(lines, 3, '\\frac', 'meta.embedded.math.reportmd');
    hasScope(lines, 4, 'energy', 'entity.name.label.reportmd');
    // 段落の途中から始まる数式
    hasScope(lines, 8, 'K', 'markup.math.block.reportmd');
    hasScope(lines, 9, '-', 'keyword.other.unnumbered.reportmd');
    // メールアドレスは参照ではない
    lacksScope(lines, 10, '@example', 'variable.other.reference.reportmd');
  });

  await t.test('コードブロック・フロントマターの中は色分けしない', () => {
    const lines = tokenize('---\ntitle: @x\n---\n\n```\n#1 コード\n--> コード\n@ref\n```\n\n`@ref` と `$x$`');
    lacksScope(lines, 1, '@x', 'variable.other.reference.reportmd');
    lacksScope(lines, 5, '#1', 'markup.heading.reportmd');
    lacksScope(lines, 6, '-->', 'keyword.operator.align.reportmd');
    lacksScope(lines, 7, '@ref', 'variable.other.reference.reportmd');
    lacksScope(lines, 10, '@ref', 'variable.other.reference.reportmd');
    lacksScope(lines, 10, 'x', 'markup.math.inline.reportmd');
  });
});
