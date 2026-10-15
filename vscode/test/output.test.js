// reportmd の出力（エラー・警告）の読み取りのテスト。出力の例は、reportmd 本体が実際に出すもの。
const test = require('node:test');
const assert = require('node:assert');
const { parseDiagnostics, referencesIn, findReferences, settingKeyIn, findSettingKey } = require('../lib/output');

test('行番号つき・行番号なし・ファイル名なしのエラーと警告を読む', () => {
  const text = [
    'report.reportmd:3: warning: 見出し #3 の前に #2 がありません',
    'report.reportmd: warning: 参照先の図表・数式が見つかりません: @missing（{#missing} で名前を付けてください）',
    'setting.json: error: 設定 text.font_size の値が不正です: "99pt"（"6pt"〜"24pt"）',
    'error: 入力ファイルを1つ指定してください（例: reportmd build report.reportmd）',
    'report.reportmd: エラーはありません（警告を確認してください）',
    '（Pandoc が見つからないため、図表・数式の参照は調べていません）',
  ].join('\n');
  assert.deepStrictEqual(parseDiagnostics(text), [
    { file: 'report.reportmd', line: 3, severity: 'warning', message: '見出し #3 の前に #2 がありません' },
    {
      file: 'report.reportmd',
      line: 0,
      severity: 'warning',
      message: '参照先の図表・数式が見つかりません: @missing（{#missing} で名前を付けてください）',
    },
    { file: 'setting.json', line: 0, severity: 'error', message: '設定 text.font_size の値が不正です: "99pt"（"6pt"〜"24pt"）' },
    { file: '', line: 0, severity: 'error', message: '入力ファイルを1つ指定してください（例: reportmd build report.reportmd）' },
  ]);
});

test('LaTeX のエラーの続きの行（字下げされた行）を、メッセージに付け足す', () => {
  const text = [
    'b.reportmd:2: error: 文書の生成に失敗しました（pandoc の終了コード: 43）',
    '  原因の候補: 定義されていない命令（\\ で始まる語）があります。',
    '  ! Undefined control sequence.',
    '',
    '  字下げされていても、空行のあとは付け足さない',
  ].join('\r\n');
  const [d, ...rest] = parseDiagnostics(text);
  assert.strictEqual(d.line, 2);
  assert.strictEqual(
    d.message,
    '文書の生成に失敗しました（pandoc の終了コード: 43）\n原因の候補: 定義されていない命令（\\ で始まる語）があります。\n! Undefined control sequence.',
  );
  assert.deepStrictEqual(rest, []);
});

test('Windows のパス（C:\\...）の「:」で切らない', () => {
  assert.deepStrictEqual(parseDiagnostics('C:\\r\\a.reportmd:7: error: x\nC:\\r\\setting.json: warning: y'), [
    { file: 'C:\\r\\a.reportmd', line: 7, severity: 'error', message: 'x' },
    { file: 'C:\\r\\setting.json', line: 0, severity: 'warning', message: 'y' },
  ]);
});

test('メッセージの中の参照（@名前）', () => {
  assert.deepStrictEqual(referencesIn('参照先の図表・数式が見つかりません: @fig:a.b（{#fig:a.b} で…）'), ['fig:a.b']);
  assert.deepStrictEqual(referencesIn('参照はありません'), []);
});

test('文書の中の @名前 の位置（コードブロックの中と、別の名前は除く）', () => {
  const text = ['@sys に示す。@sysに示す', '@system と mail@sys.jp', '```', '@sys', '```', '[@sys; @a]'].join('\n');
  assert.deepStrictEqual(findReferences(text, 'sys'), [
    { line: 0, start: 0, end: 4 },
    { line: 0, start: 9, end: 13 },
    { line: 5, start: 1, end: 5 },
  ]);
});

test('設定ファイルのエラーの項目と、そのキーの位置', () => {
  assert.strictEqual(settingKeyIn('設定 text.font_size の値が不正です: "99pt"'), 'text.font_size');
  assert.strictEqual(settingKeyIn('未知の設定キーを無視します: table.rules.foo'), 'table.rules.foo');
  assert.strictEqual(settingKeyIn('設定ファイルがJSONとして不正です'), null);

  const json = ['{', '  "font_size": 1,', '  "text": {', '    "line_spacing": 1.5,', '    "font_size": "99pt"', '  }', '}'].join('\n');
  assert.deepStrictEqual(findSettingKey(json, 'text.font_size'), { line: 4, start: 4, end: 15 });
  assert.deepStrictEqual(findSettingKey(json, 'font_size'), { line: 1, start: 2, end: 13 });
  assert.strictEqual(findSettingKey(json, 'page.margin'), null);
});
