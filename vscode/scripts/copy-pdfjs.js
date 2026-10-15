// pdf.js（PDF を表示するライブラリ。npm の pdfjs-dist）のうち、プレビューに使うファイルを media/pdfjs にコピーする。
// npm install のあと（postinstall）と、.vsix を作る前（vscode:prepublish）に実行する。
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const source = path.dirname(require.resolve('pdfjs-dist/package.json'));
const target = path.join(__dirname, '..', 'media', 'pdfjs');
fs.mkdirSync(target, { recursive: true });
for (const file of ['build/pdf.min.mjs', 'build/pdf.worker.min.mjs', 'LICENSE']) {
  fs.copyFileSync(path.join(source, file), path.join(target, path.basename(file)));
}
const version = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8')).version;
console.log(`pdf.js ${version} を media/pdfjs にコピーしました`);
