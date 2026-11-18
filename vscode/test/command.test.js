// reportmd を実行するコマンドラインの組み立てのテスト。
const test = require('node:test');
const assert = require('node:assert');
const { wslLocation, commandLine, findInPath, resolveExecutable, wslExecutable, isNotFound } = require('../lib/command');

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

test('WSL のフォルダでは、指定した wsl.exe のパスで起動する', () => {
  const line = commandLine('reportmd', ['check', 'a.reportmd'], '\\\\wsl$\\Ubuntu\\r', 'win32', 'C:\\Windows\\System32\\wsl.exe');
  assert.strictEqual(line.command, 'C:\\Windows\\System32\\wsl.exe');
});

// files にあるファイルだけが「ある」環境（Windows の名前は、大文字・小文字を区別しない）
const env = (files, envPath, platform = 'linux', extra = {}) => ({
  platform,
  envPath,
  home: '/home/sou',
  isExecutable: (file) => files.some((f) => (platform === 'win32' ? f.toLowerCase() === file.toLowerCase() : f === file)),
  ...extra,
});

test('Linux・macOS で実行する reportmd を決める', () => {
  const linux = (files, envPath = '/usr/bin:/bin') => env(files, envPath);
  // 設定がパスなら、それを使う
  assert.strictEqual(resolveExecutable('/opt/reportmd', '/home/sou/r', linux([])), '/opt/reportmd');
  assert.strictEqual(resolveExecutable(' /opt/reportmd ', '/home/sou/r', linux([])), '/opt/reportmd');
  // PATH にあれば、その絶対パス（~/.local/bin より PATH が先）
  assert.strictEqual(resolveExecutable('', '/home/sou/r', linux(['/bin/reportmd', '/home/sou/.local/bin/reportmd'])), '/bin/reportmd');
  // PATH になく、~/.local/bin にあれば、そちら
  assert.strictEqual(resolveExecutable(undefined, '/home/sou/r', linux(['/home/sou/.local/bin/reportmd'])), '/home/sou/.local/bin/reportmd');
  // どちらにもなければ null（起動しない）
  assert.strictEqual(resolveExecutable('', '/home/sou/r', linux([])), null);
  // 設定が名前だけなら、PATH から探す（~/.local/bin は使わない）
  assert.strictEqual(resolveExecutable('reportmd2', '/home/sou/r', linux(['/usr/bin/reportmd2'])), '/usr/bin/reportmd2');
  assert.strictEqual(resolveExecutable('reportmd2', '/home/sou/r', linux(['/home/sou/.local/bin/reportmd2'])), null);
});

test('Linux・macOS で、文書のフォルダ（PATH の空の項目・相対パス）からは探さない', () => {
  const files = ['/home/sou/r/reportmd', '/home/sou/r/bin/reportmd'];
  for (const envPath of [':/usr/bin', '/usr/bin:', '/usr/bin::/bin', '.:/usr/bin', 'bin:/usr/bin', '']) {
    assert.strictEqual(resolveExecutable('', '/home/sou/r', env(files, envPath)), null, `PATH=${envPath}`);
  }
});

test('Windows で実行する reportmd を決める', () => {
  const win = (files, envPath = 'C:\\Windows\\System32;C:\\Tools', pathExt = '.COM;.EXE;.BAT;.CMD') => env(files, envPath, 'win32', { pathExt });
  // PATH にあれば、その絶対パス
  assert.strictEqual(resolveExecutable('', 'C:\\r', win(['C:\\Tools\\reportmd.exe'])), 'C:\\Tools\\reportmd.exe');
  // 引用符で囲まれた PATH の項目
  assert.strictEqual(
    resolveExecutable('', 'C:\\r', win(['C:\\Program Files\\reportmd\\reportmd.exe'], '"C:\\Program Files\\reportmd";C:\\Tools')),
    'C:\\Program Files\\reportmd\\reportmd.exe',
  );
  // PATHEXT の順（.COM が .EXE より先）。.bat・.cmd は spawn で直接起動できないので使わない
  assert.strictEqual(resolveExecutable('', 'C:\\r', win(['C:\\Tools\\reportmd.exe', 'C:\\Tools\\reportmd.com'])), 'C:\\Tools\\reportmd.com');
  assert.strictEqual(resolveExecutable('', 'C:\\r', win(['C:\\Tools\\reportmd.cmd', 'C:\\Tools\\reportmd.bat'])), null);
  // PATHEXT がなければ既定の値
  assert.strictEqual(resolveExecutable('', 'C:\\r', win(['C:\\Tools\\reportmd.exe'], 'C:\\Tools', undefined)), 'C:\\Tools\\reportmd.exe');
  // 設定が名前だけなら PATH から探す。拡張子まで書いてあれば、そのままの名前も探す
  assert.strictEqual(resolveExecutable('reportmd.exe', 'C:\\r', win(['C:\\Tools\\reportmd.exe'])), 'C:\\Tools\\reportmd.exe');
  // 設定がパスなら、それを使う
  assert.strictEqual(resolveExecutable('D:\\bin\\reportmd.exe', 'C:\\r', win([])), 'D:\\bin\\reportmd.exe');
  // ~/.local/bin は使わない。どこにもなければ null（起動しない）
  assert.strictEqual(resolveExecutable('', 'C:\\r', win(['/home/sou/.local/bin/reportmd'])), null);
});

test('Windows で、文書のフォルダにある reportmd.exe は起動しない', () => {
  // リポジトリに置かれた reportmd.exe（PATH の reportmd はない）
  const planted = ['C:\\repo\\reportmd.exe', 'C:\\repo\\reportmd.com', 'C:\\repo\\bin\\reportmd.exe'];
  for (const envPath of ['C:\\Windows\\System32', 'C:\\Windows\\System32;', ';C:\\Windows\\System32', '.;C:\\Windows', 'bin;C:\\Windows', '\\repo;C:\\Windows', 'C:repo', '']) {
    assert.strictEqual(resolveExecutable('', 'C:\\repo', env(planted, envPath, 'win32')), null, `PATH=${envPath}`);
  }
  // PATH にもあるときは、PATH のもの
  assert.strictEqual(
    resolveExecutable('', 'C:\\repo', env([...planted, 'C:\\Tools\\reportmd.exe'], '.;C:\\Tools', 'win32')),
    'C:\\Tools\\reportmd.exe',
  );
  // UNC の PATH の項目は使う
  assert.strictEqual(resolveExecutable('', 'C:\\repo', env(['\\\\server\\tools\\reportmd.exe'], '\\\\server\\tools', 'win32')), '\\\\server\\tools\\reportmd.exe');
});

test('Windows で WSL のフォルダを開いた場合は、Windows の PATH から探さない', () => {
  const win = env([], 'C:\\Windows\\System32', 'win32');
  assert.strictEqual(resolveExecutable('', '\\\\wsl.localhost\\Ubuntu\\home\\sou\\r', win), 'reportmd');
  assert.strictEqual(resolveExecutable('/home/sou/.local/bin/reportmd', '\\\\wsl.localhost\\Ubuntu\\home\\sou\\r', win), '/home/sou/.local/bin/reportmd');
});

test('名前を PATH から探す', () => {
  assert.strictEqual(findInPath('reportmd', env(['/a/reportmd', '/b/reportmd'], '/a:/b')), '/a/reportmd');
  assert.strictEqual(findInPath('reportmd', env([], '/a:/b')), null);
  assert.strictEqual(findInPath('reportmd', env(['/a/reportmd'], undefined)), null);
});

test('wsl.exe の場所', () => {
  // PATH にあれば、その絶対パス
  assert.strictEqual(wslExecutable(env(['C:\\Windows\\System32\\wsl.exe'], 'C:\\Windows\\System32', 'win32')), 'C:\\Windows\\System32\\wsl.exe');
  // 文書のフォルダの wsl.exe は使わず、SystemRoot の System32 のもの
  assert.strictEqual(wslExecutable(env(['C:\\repo\\wsl.exe'], '.', 'win32', { systemRoot: 'D:\\Win' })), 'D:\\Win\\System32\\wsl.exe');
  assert.strictEqual(wslExecutable(env([], '', 'win32')), 'C:\\Windows\\System32\\wsl.exe');
});

test('reportmd が見つからないこと', () => {
  assert.ok(isNotFound({ errorCode: 'ENOENT', exitCode: null, wsl: false }));
  assert.ok(isNotFound({ exitCode: 127, wsl: true }));
  assert.ok(!isNotFound({ exitCode: 127, wsl: false }));
  assert.ok(!isNotFound({ exitCode: 1, wsl: true }));
});
