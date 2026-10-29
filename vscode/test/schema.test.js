// setting.json のスキーマのテスト。VS Code と同じ JSON の検査（vscode-json-languageservice）で、
// 既定の設定が通り、誤った値には印が付くことを確かめる。
// （スキーマの項目と既定値が reportmd 本体と合っていることは、Go のテスト internal/config/schema_test.go で確かめる）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { getLanguageService, TextDocument } = require('vscode-json-languageservice');

const readSchema = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'schemas', name), 'utf8'));
const service = getLanguageService({});
service.configure({
  validate: true,
  schemas: [
    { uri: 'reportmd://setting.schema.json', fileMatch: ['setting.json', 'setting.docx.json'], schema: readSchema('setting.schema.json') },
    { uri: 'reportmd://setting.pptx.schema.json', fileMatch: ['setting.pptx.json'], schema: readSchema('setting.pptx.schema.json') },
  ],
});

async function validate(text, name = 'setting.json') {
  const doc = TextDocument.create('file:///r/' + name, 'json', 1, text);
  const json = service.parseJSONDocument(doc);
  const list = await service.doValidation(doc, json);
  return list.map((d) => ({ line: d.range.start.line, message: d.message }));
}

async function complete(text, offset) {
  const doc = TextDocument.create('file:///r/setting.json', 'json', 1, text);
  const json = service.parseJSONDocument(doc);
  const result = await service.doComplete(doc, doc.positionAt(offset), json);
  return result.items.map((i) => i.label);
}

test('reportmd 本体の既定の設定（reportmd init の setting.json）は、そのまま通る', async () => {
  const defaults = fs.readFileSync(path.join(__dirname, '..', '..', 'internal', 'config', 'default.json'), 'utf8');
  assert.deepStrictEqual(await validate(defaults), []);
});

test('誤った値と未知のキーに印を付ける', async () => {
  const text = [
    '{',
    '  "document": { "paper": "a3" },',
    '  "page": { "margin": { "top": "25" } },',
    '  "text": { "line_spacing": 5, "font_size": "11px" },',
    '  "font": { "main": "My_Font" },',
    '  "heading": { "sizes": ["14pt", "12pt"] },',
    '  "table": { "rules": { "rows": true }, "font_size": null },',
    '  "slide": { "title": { "color": "red" } },',
    '  "colour": 1',
    '}',
  ].join('\n');
  const lines = (await validate(text)).map((d) => d.line);
  for (const line of [1, 2, 3, 4, 5, 6, 7, 8]) {
    assert.ok(lines.includes(line), `${line + 1} 行目に印がない: ${JSON.stringify(await validate(text))}`);
  }
  // 正しい値（null・false・長さ）には印を付けない
  const ok = '{ "table": { "font_size": null, "rules": { "rows": false, "vertical": "0.4pt" } }, "text": { "font_size": "11pt" } }';
  assert.deepStrictEqual(await validate(ok), []);
});

test('PowerPoint の設定（setting.pptx.json）を調べる', async () => {
  const defaults = fs.readFileSync(path.join(__dirname, '..', '..', 'internal', 'config', 'default.pptx.json'), 'utf8');
  assert.deepStrictEqual(await validate(defaults, 'setting.pptx.json'), []);
  assert.deepStrictEqual(await validate('{ "title": { "color": "#c00000", "rule": false } }', 'setting.pptx.json'), []);
  const text = [
    '{',
    '  "title": { "color": "navy" },',
    '  "text": { "size": "20" },',
    '  "page": {}',
    '}',
  ].join('\n');
  const lines = (await validate(text, 'setting.pptx.json')).map((d) => d.line);
  for (const line of [1, 2, 3]) {
    assert.ok(lines.includes(line), `${line + 1} 行目に印がない: ${JSON.stringify(await validate(text, 'setting.pptx.json'))}`);
  }
  // 形式ごとの上書き（setting.docx.json）は、setting.json と同じ項目
  assert.deepStrictEqual(await validate('{ "font": { "main": "Yu Mincho" } }', 'setting.docx.json'), []);
});

test('表紙のレイアウトの項目を調べる', async () => {
  const ok = '{ "cover": { "layout": [ { "space": "fill" }, { "text": "{{ {title} }}", "align": "left", "size": "32pt", "bold": true }, { "fields": [["氏名", "{author}"]] } ] } }';
  assert.deepStrictEqual(await validate(ok), []);
  const text = [
    '{ "cover": { "layout": [',
    '  { "text": "{title" },',
    '  { "space": "10" },',
    '  { "fields": [["氏名"]] },',
    '  { "text": "a", "space": "fill" },',
    '  { "text": "a", "align": "top" },',
    '  { "size": "12pt" }',
    '] } }',
  ].join('\n');
  const lines = (await validate(text)).map((d) => d.line);
  for (const line of [1, 2, 3, 4, 5, 6]) {
    assert.ok(lines.includes(line), `${line + 1} 行目に印がない: ${JSON.stringify(await validate(text))}`);
  }
});

test('項目と値を補完する', async () => {
  assert.deepStrictEqual((await complete('{ }', 2)).sort(), ['caption', 'cover', 'document', 'equation', 'font', 'heading', 'page', 'table', 'text']);
  const text = '{ "table": { "width": } }';
  const values = await complete(text, text.indexOf(':', text.indexOf('width')) + 2);
  assert.deepStrictEqual(values.sort(), ['"auto"', '"full"']);
});
