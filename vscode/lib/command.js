// reportmd を実行するためのコマンドラインを組み立てる。VS Code に依存しない部分。
'use strict';

const path = require('node:path');

// Windows の VS Code で WSL のフォルダ（\\wsl.localhost\Ubuntu\home\... や \\wsl$\Ubuntu\...）を
// 直接開いた場合のパス
const wslUNC = /^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)((?:\\.*)?)$/i;

/**
 * wslLocation は、WSL のフォルダを指す Windows のパスを、ディストリビューション名と Linux のパスにする。
 * WSL のパスでなければ null。
 * @param {string} windowsPath
 * @returns {{distro: string, path: string} | null}
 */
function wslLocation(windowsPath) {
  const m = wslUNC.exec(windowsPath);
  if (!m) return null;
  const rest = m[2].replace(/\\/g, '/').replace(/\/+$/, '');
  return { distro: m[1], path: rest === '' ? '/' : rest };
}

/**
 * commandLine は、ディレクトリ dir で「reportmd args...」を実行するためのコマンドラインを返す。
 *   - Linux・macOS（WSL に接続した VS Code を含む）: そのまま実行する
 *   - Windows で WSL のフォルダを開いた場合: wsl.exe を通して、WSL の中の reportmd を実行する。
 *     ログインシェル（bash -l）を使うのは、~/.local/bin を PATH に入れる ~/.profile を読むため
 *   - Windows のそのほかのフォルダ: Windows の reportmd（reportmd.exe）を実行する
 * @param {string} executable reportmd のパス（resolveExecutable で決めたもの）
 * @param {string[]} args
 * @param {string} dir
 * @param {string} platform process.platform
 * @param {string} [wslCommand] wsl.exe のパス（wslExecutable で決めたもの）
 * @returns {{command: string, args: string[], cwd: string | undefined, wsl: boolean}}
 */
function commandLine(executable, args, dir, platform, wslCommand = 'wsl.exe') {
  if (platform === 'win32') {
    const wsl = wslLocation(dir);
    if (wsl) {
      return {
        command: wslCommand,
        args: ['-d', wsl.distro, '--cd', wsl.path, '-e', 'bash', '-lc', 'exec "$0" "$@"', executable, ...args],
        cwd: undefined,
        wsl: true,
      };
    }
  }
  return { command: executable, args, cwd: dir, wsl: false };
}

// spawn が（シェルを通さずに）直接起動できる拡張子。.bat・.cmd は cmd.exe を通さないと起動できない
const windowsDirectExtensions = ['.exe', '.com'];
const windowsDefaultPathExt = '.COM;.EXE;.BAT;.CMD';

/**
 * @typedef {object} LookupEnv
 * @property {string} platform process.platform
 * @property {string | undefined} envPath 環境変数 PATH
 * @property {string | undefined} [pathExt] 環境変数 PATHEXT（Windows のみ）
 * @property {string} [home] ホームディレクトリ
 * @property {(file: string) => boolean} isExecutable そのファイルがあって、実行できるか
 */

/**
 * hasDirectory は、コマンドの指定がフォルダを含む（名前だけではない）かどうか。
 * @param {string} command
 * @param {string} platform
 * @returns {boolean}
 */
function hasDirectory(command, platform) {
  return platform === 'win32' ? /[\\/]|^[a-zA-Z]:/.test(command) : command.includes('/');
}

/**
 * isAbsoluteDir は、PATH の項目が絶対パスかどうか。
 * Windows では、ドライブ名から始まるもの（C:\...）と UNC（\\server\share\...）だけを絶対パスとする
 * （\bin のような「今のドライブ」からのパスや、C:bin のような「そのドライブの今のフォルダ」からのパスは使わない）。
 * @param {string} dir
 * @param {string} platform
 * @returns {boolean}
 */
function isAbsoluteDir(dir, platform) {
  return platform === 'win32' ? /^(?:[a-zA-Z]:[\\/]|[\\/]{2}[^\\/])/.test(dir) : dir.startsWith('/');
}

/**
 * findInPath は、コマンドの名前 name を、環境変数 PATH の絶対パスのフォルダだけから探し、見つかったファイルの絶対パスを返す。
 * 見つからなければ null。
 * 名前だけを spawn に渡すと、Windows（libuv）は PATH より先に作業フォルダ（spawn の cwd。ここでは文書のフォルダ）を探し、
 * Linux・macOS も PATH の空の項目や「.」を作業フォルダとして探す。文書のフォルダに置かれた reportmd を起動しないよう、
 * 作業フォルダを指す項目（空・相対パス）は使わない。
 * Windows では、PATHEXT の順に拡張子を付けて探す（spawn が直接起動できる .exe・.com だけ）。
 * @param {string} name
 * @param {LookupEnv} env
 * @returns {string | null}
 */
function findInPath(name, env) {
  const win = env.platform === 'win32';
  const p = win ? path.win32 : path.posix;
  let names = [name];
  if (win) {
    const exts = (env.pathExt || windowsDefaultPathExt)
      .split(';')
      .map((ext) => ext.trim().toLowerCase())
      .filter((ext) => windowsDirectExtensions.includes(ext));
    // 拡張子まで書いてあれば、まずそのまま探す（Windows のコマンドの探し方と同じ）
    names = windowsDirectExtensions.includes(path.win32.extname(name).toLowerCase()) ? [name] : [];
    names.push(...exts.map((ext) => name + ext));
  }
  for (const item of (env.envPath || '').split(p.delimiter)) {
    // Windows の PATH の項目は、"C:\Program Files\x" のように引用符で囲まれていることがある
    const dir = win ? item.trim().replace(/^"(.*)"$/, '$1') : item;
    if (!isAbsoluteDir(dir, env.platform)) continue;
    for (const n of names) {
      const file = p.join(dir, n);
      if (env.isExecutable(file)) return file;
    }
  }
  return null;
}

/**
 * resolveExecutable は、ディレクトリ dir の文書に対して実行する reportmd を決める。
 * 実行できる reportmd が見つからなければ null（起動せずに、見つからないことを知らせる）。
 *   - Windows で WSL のフォルダを開いた場合: 設定 reportmd.path（なければ「reportmd」）を、そのまま WSL に渡す。
 *     WSL の中のログインシェルが、WSL の PATH から探す
 *   - 設定 reportmd.path がフォルダを含むパスなら、それを使う
 *   - 設定が名前だけ（または空で「reportmd」）なら、PATH から探して絶対パスにする（findInPath）。
 *     名前のまま spawn に渡すと、文書のフォルダにある同じ名前のファイルを起動することがあるため
 *   - 設定が空で、Linux・macOS の PATH に見つからず、make install の既定の場所（~/.local/bin/reportmd）にあれば、
 *     そちらを使う。VS Code は、ログインシェルの PATH を引き継がずに起動されることがあるため
 * @param {string | undefined} configured 設定 reportmd.path
 * @param {string} dir 文書のフォルダ
 * @param {LookupEnv} env
 * @returns {string | null}
 */
function resolveExecutable(configured, dir, env) {
  const setting = (configured || '').trim();
  if (env.platform === 'win32' && wslLocation(dir)) return setting || 'reportmd';
  if (setting !== '' && hasDirectory(setting, env.platform)) return setting;
  const found = findInPath(setting || 'reportmd', env);
  if (found) return found;
  if (setting === '' && env.platform !== 'win32' && env.home) {
    const fallback = path.posix.join(env.home, '.local', 'bin', 'reportmd');
    if (env.isExecutable(fallback)) return fallback;
  }
  return null;
}

/**
 * wslExecutable は、Windows で WSL のフォルダの reportmd を実行するときに使う wsl.exe の絶対パスを返す。
 * PATH から探し、なければ Windows のフォルダ（環境変数 SystemRoot）の System32 の wsl.exe とする。
 * @param {LookupEnv & {systemRoot?: string}} env
 * @returns {string}
 */
function wslExecutable(env) {
  return findInPath('wsl', { ...env, platform: 'win32' }) || path.win32.join(env.systemRoot || 'C:\\Windows', 'System32', 'wsl.exe');
}

/**
 * isNotFound は、実行の結果が「reportmd が見つからない」ことを表しているかどうか。
 * 直接実行した場合は spawn の ENOENT、WSL を通した場合はシェルの終了コード 127。
 * @param {{errorCode?: string, exitCode: number | null, wsl: boolean}} result
 * @returns {boolean}
 */
function isNotFound(result) {
  return result.errorCode === 'ENOENT' || (result.wsl && result.exitCode === 127);
}

module.exports = { wslLocation, commandLine, findInPath, resolveExecutable, wslExecutable, isNotFound };
