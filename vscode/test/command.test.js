// reportmd を実行するコマンドラインの組み立てのテスト。
const test = require('node:test');
const assert = require('node:assert');
const { wslLocation, commandLine, resolveExecutable, isNotFound } = require('../lib/command');

test('WSL のフォルダを指す Windows のパス', () => {
  assert.deepStrictEqual(wslLocation('\\\\wsl.localhost\\Ubuntu\\home\\sou\\レポート'), { distro: 'Ubuntu', path: '/home/sou/レポート' });
  assert.deepStrictEqual(wslLocation('\\\\wsl$\\Ubuntu-22.04\\tmp\\'), { distro: 'Ubuntu-22.04', path: '/tmp' });
  assert.deepStrictEqual(wslLocation('\\\\WSL.LOCALHOST\\Ubuntu'), { distro: 'Ubuntu', path: '/' });
  assert.strictEqual(wslLocation('C:\\Users\\sou'), null);
  assert.strictEqual(wslLocation('/home/sou'), null);
  assert.strictEqual(wslLocation('\\\\server\\share\\x'), null);
});

test('Windows で WSL のフォルダを開いた場合は、wsl.exe を通して実行する', () => {
  const line = commandLine('reportmd', ['check', 'a b.reportmd'], '\\\\wsl.localhost\\Ubuntu\\home\\sou\\r', 'win32');
  assert.deepStrictEqual(line, {
    command: 'wsl.exe',
    args: ['-d', 'Ubuntu', '--cd', '/home/sou/r', '-e', 'bash', '-lc', 'exec "$0" "$@"', 'reportmd', 'check', 'a b.reportmd'],
    cwd: undefined,
    wsl: true,
  });
});

test('それ以外は、文書のフォルダでそのまま実行する', () => {
  assert.deepStrictEqual(commandLine('reportmd', ['build', 'a.reportmd'], '/home/sou/r', 'linux'), {
    command: 'reportmd',
    args: ['build', 'a.reportmd'],
    cwd: '/home/sou/r',
    wsl: false,
  });
  assert.deepStrictEqual(commandLine('C:\\bin\\reportmd.exe', ['build', 'a.reportmd'], 'C:\\r', 'win32').command, 'C:\\bin\\reportmd.exe');
});

test('実行する reportmd を決める', () => {
  const env = (files, envPath = '/usr/bin:/bin', platform = 'linux') => ({
    platform,
    envPath,
    home: '/home/sou',
    exists: (file) => files.includes(file),
  });
  // 設定があれば、それを使う
  assert.strictEqual(resolveExecutable('/opt/reportmd', env([])), '/opt/reportmd');
  // PATH にあれば reportmd
  assert.strictEqual(resolveExecutable('', env(['/usr/bin/reportmd', '/home/sou/.local/bin/reportmd'])), 'reportmd');
  // PATH になく、~/.local/bin にあれば、そちら
  assert.strictEqual(resolveExecutable(undefined, env(['/home/sou/.local/bin/reportmd'])), '/home/sou/.local/bin/reportmd');
  // どちらにもなければ reportmd（実行して、見つからないことを知らせる）
  assert.strictEqual(resolveExecutable('', env([])), 'reportmd');
  // Windows は探さない
  assert.strictEqual(resolveExecutable('', env(['/home/sou/.local/bin/reportmd'], '', 'win32')), 'reportmd');
});

test('reportmd が見つからないこと', () => {
  assert.ok(isNotFound({ errorCode: 'ENOENT', exitCode: null, wsl: false }));
  assert.ok(isNotFound({ exitCode: 127, wsl: true }));
  assert.ok(!isNotFound({ exitCode: 127, wsl: false }));
  assert.ok(!isNotFound({ exitCode: 1, wsl: true }));
});
