// reportmd の出力（エラー・警告）を読む。VS Code に依存しない部分なので、単体でテストできる。
'use strict';

// 「ファイル:行: 種類: メッセージ」と、行番号のない「ファイル: 種類: メッセージ」「種類: メッセージ」。
// Windows のパス（C:\...）の「:」で切れないように、ファイル名は「: 」の手前までを最短で取る。
const withLine = /^(.+?):(\d+): (error|warning): (.*)$/;
const withoutLine = /^(.+?): (error|warning): (.*)$/;
const bare = /^(error|warning): (.*)$/;

/**
 * parseDiagnostics は、reportmd の出力から、エラーと警告を取り出す。
 * 行番号がなければ line は 0、ファイル名がなければ file は ''。
 * 字下げされた続きの行（LaTeX のエラーの「原因の候補」など）は、直前のメッセージに付け足す。
 * @param {string} text
 * @returns {{file: string, line: number, severity: 'error' | 'warning', message: string}[]}
 */
function parseDiagnostics(text) {
  const result = [];
  let last = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, '');
    if (line === '') {
      last = null;
      continue;
    }
    let m;
    if ((m = withLine.exec(line))) {
      last = { file: m[1], line: Number(m[2]), severity: m[3], message: m[4] };
    } else if ((m = bare.exec(line))) {
      last = { file: '', line: 0, severity: m[1], message: m[2] };
    } else if ((m = withoutLine.exec(line))) {
      last = { file: m[1], line: 0, severity: m[2], message: m[3] };
    } else {
      if (last && /^\s/.test(line)) last.message += '\n' + line.trim();
      continue;
    }
    result.push(last);
  }
  return result;
}

/**
 * referencesIn は、メッセージに出てくる参照（@名前）の名前を返す。
 * 「参照先の図表・数式が見つかりません: @nothing」のように行番号のない警告を、
 * 文書の中の @nothing の位置に表示するために使う。
 * @param {string} message
 * @returns {string[]}
 */
function referencesIn(message) {
  const names = [];
  const pattern = /@([A-Za-z0-9_](?:[A-Za-z0-9_:.-]*[A-Za-z0-9_])?)/g;
  let m;
  while ((m = pattern.exec(message))) names.push(m[1]);
  return names;
}

/**
 * findReferences は、文書の中で @name が書かれている位置（0 から数えた行と桁）を返す。
 * コードブロックの中は除く。
 * @param {string} text
 * @param {string} name
 * @returns {{line: number, start: number, end: number}[]}
 */
function findReferences(text, name) {
  const found = [];
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // 名前の直後に英数字が続くものは、別の名前（@fig と @fig2）
  const pattern = new RegExp(`(?<![\\w@.])@${escaped}(?![A-Za-z0-9_]|[:.\\-][A-Za-z0-9_])`, 'g');
  let fence = null;
  text.split(/\r?\n/).forEach((line, index) => {
    const marker = /^\s*(`{3,}|~{3,})/.exec(line);
    if (marker) {
      if (fence === null) fence = marker[1][0];
      else if (marker[1][0] === fence) fence = null;
      return;
    }
    if (fence !== null) return;
    let m;
    while ((m = pattern.exec(line))) found.push({ line: index, start: m.index, end: m.index + m[0].length });
  });
  return found;
}

/**
 * settingKeyIn は、設定ファイルのエラー・警告のメッセージから、設定の項目（text.font_size など）を取り出す。
 * @param {string} message
 * @returns {string | null}
 */
function settingKeyIn(message) {
  const m = /(?:^設定 |設定キーを無視します: )([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/.exec(message);
  return m ? m[1] : null;
}

/**
 * findSettingKey は、設定ファイル（JSON）の中で、項目 keyPath（text.font_size など）のキーの位置を返す。
 * 上の階層のキーから順に、後ろへ向かって探す（厳密な JSON の解析はしない）。見つからなければ null。
 * @param {string} text
 * @param {string} keyPath
 * @returns {{line: number, start: number, end: number} | null}
 */
function findSettingKey(text, keyPath) {
  let from = 0;
  let found = null;
  for (const key of keyPath.split('.')) {
    const pattern = new RegExp(`"${key}"\\s*:`, 'g');
    pattern.lastIndex = from;
    const m = pattern.exec(text);
    if (!m) return null;
    found = { offset: m.index, length: key.length + 2 };
    from = m.index + m[0].length;
  }
  const before = text.slice(0, found.offset);
  const line = before.split('\n').length - 1;
  const start = found.offset - (before.lastIndexOf('\n') + 1);
  return { line, start, end: start + found.length };
}

module.exports = { parseDiagnostics, referencesIn, findReferences, settingKeyIn, findSettingKey };
