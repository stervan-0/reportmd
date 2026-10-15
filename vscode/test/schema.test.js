// setting.json のスキーマのテスト。VS Code と同じ JSON の検査（vscode-json-languageservice）で、
// 既定の設定が通り、誤った値には印が付くことを確かめる。
// （スキーマの項目と既定値が reportmd 本体と合っていることは、Go のテスト internal/config/schema_test.go で確かめる）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { getLanguageService, TextDocument } = require('vscode-json-languageservice');

const schemaPath = path.join(__dirname, '..', 'schemas', 'setting.schema.json');
const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const service = getLanguageService({});
service.configure({ validate: true, schemas: [{ uri: 'reportmd://setting.schema.json', fileMatch: ['setting.json'], schema }] });

async function validate(text) {
  const doc = TextDocument.create('file:///r/setting.json', 'json', 1, text);
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
    '  "colour": 1',
    '}',
  ].join('\n');
  const lines = (await validate(text)).map((d) => d.line);
  for (const line of [1, 2, 3, 4, 5, 6, 7]) {
    assert.ok(lines.includes(line), `${line + 1} 行目に印がない: ${JSON.stringify(await validate(text))}`);
  }
  // 正しい値（null・false・長さ）には印を付けない
  const ok = '{ "table": { "font_size": null, "rules": { "rows": false, "vertical": "0.4pt" } }, "text": { "font_size": "11pt" } }';
  assert.deepStrictEqual(await validate(ok), []);
});

test('項目と値を補完する', async () => {
  assert.deepStrictEqual((await complete('{ }', 2)).sort(), ['caption', 'document', 'equation', 'font', 'heading', 'page', 'table', 'text']);
  const text = '{ "table": { "width": } }';
  const values = await complete(text, text.indexOf(':', text.indexOf('width')) + 2);
  assert.deepStrictEqual(values.sort(), ['"auto"', '"full"']);
});
