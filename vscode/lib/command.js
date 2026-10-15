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
 * @param {string} executable reportmd のパス（設定 reportmd.path）
 * @param {string[]} args
 * @param {string} dir
 * @param {string} platform process.platform
 * @returns {{command: string, args: string[], cwd: string | undefined, wsl: boolean}}
 */
function commandLine(executable, args, dir, platform) {
  if (platform === 'win32') {
    const wsl = wslLocation(dir);
    if (wsl) {
      return {
        command: 'wsl.exe',
        args: ['-d', wsl.distro, '--cd', wsl.path, '-e', 'bash', '-lc', 'exec "$0" "$@"', executable, ...args],
        cwd: undefined,
        wsl: true,
      };
    }
  }
  return { command: executable, args, cwd: dir, wsl: false };
}

/**
 * resolveExecutable は、実行する reportmd を決める。
 * 設定 reportmd.path があればそれを使う。なければ「reportmd」（PATH から探す）だが、
 * Linux・macOS で PATH に見つからず、make install の既定の場所（~/.local/bin/reportmd）にあれば、そちらを使う。
 * VS Code は、ログインシェルの PATH を引き継がずに起動されることがあるため。
 * （Windows で WSL のフォルダを開いた場合は、WSL のログインシェルが PATH を設定するので、ここでは探さない）
 * @param {string | undefined} configured
 * @param {{platform: string, envPath: string, home: string, exists: (file: string) => boolean}} env
 * @returns {string}
 */
function resolveExecutable(configured, env) {
  if (configured && configured.trim() !== '') return configured;
  if (env.platform === 'win32') return 'reportmd';
  const inPath = (env.envPath || '').split(path.posix.delimiter).some((dir) => dir !== '' && env.exists(path.posix.join(dir, 'reportmd')));
  const fallback = path.posix.join(env.home, '.local', 'bin', 'reportmd');
  return !inPath && env.exists(fallback) ? fallback : 'reportmd';
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

module.exports = { wslLocation, commandLine, resolveExecutable, isNotFound };
