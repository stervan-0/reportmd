# reportmd for VS Code

reportmd（Markdown で大学のレポートを書いて PDF にするツール）を、VS Code で使いやすくする拡張機能です。

- **色分け**：`.reportmd` の独自記法（`^` `-->` `<->` `#1` `![f:…]` `![t:…]` `$$ … $$ {#名前}` `@名前`）に色を付けます。そのほかは Markdown と同じ色分けです。
- **エラーの表示**：開いたときと保存するたびに `reportmd check` を実行し、誤りの箇所に波線を引きます（「問題」パネルにも一覧が出ます）。
  - 見つからない参照（`@名前`）は、その `@名前` の位置に表示します。
  - `setting.json` の誤りは、`setting.json` のその項目の位置に表示します。
- **PDF の生成**：エディタの右上のボタン、ステータスバー、コマンドパレット（`reportmd:` で始まるコマンド）から実行できます。
  - 「PDF を生成」：`reportmd build` を1回実行します。
  - 「監視」：`reportmd watch` を実行し、保存するたびに PDF を作り直します。もう一度押すと止まります。監視中は、生成したときのエラー（LaTeX のエラーを含む）を表示します。
- **setting.json の補完と検査**：項目と値の候補・説明を表示し、誤った値に印を付けます。

## 必要なもの

- reportmd 本体（`make install` で入れたもの）。拡張機能は `reportmd` コマンドを呼び出します。
- WSL のフォルダを使う場合は、次のどちらでも動きます。
  - **WSL に接続した VS Code**（左下が「WSL: Ubuntu」の状態。おすすめ）：拡張機能は WSL の中で動きます。
  - Windows の VS Code で `\\wsl.localhost\...` のフォルダを直接開いた場合：`wsl.exe` を通して WSL の中の reportmd を実行します。

## インストール

```bash
cd vscode
npm run package     # reportmd-0.1.0.vsix ができる（Node.js が必要。リポジトリの最上位で make vscode でも可）
```

VS Code の拡張機能ビューの「…」メニュー →「VSIX からのインストール...」で、できた `.vsix` を選びます。WSL に接続した VS Code で行うと、WSL の側に入ります。

拡張子 `.rmd`（reportmd 0.1.0）のファイルにも使う場合は、VS Code の設定に次を加えます（R Markdown を使わない場合のみ）。

```json
"files.associations": { "*.rmd": "reportmd" }
```

## 設定

| 設定 | 説明 |
| --- | --- |
| `reportmd.path` | reportmd コマンドのパス。空なら `reportmd`（PATH から探し、見つからなければ `~/.local/bin/reportmd`） |
| `reportmd.checkOnSave` | 保存するたびに誤りを調べる（既定 `true`） |
| `reportmd.openPdf` | 生成した PDF を開く場所。`external`（PDF ビューア。既定）・`vscode`（VS Code の横のタブ。PDF を表示する拡張機能が必要）・`none` |

## 開発

```bash
npm install
npm test       # 色分け・出力の読み取り・スキーマ・拡張機能の動作のテスト
```

- 色分けのテストは、VS Code 本体に入っている Markdown などの文法を使います（VS Code が見つからなければ飛ばします）。
- 拡張機能の動作のテストは、VS Code の API の代わり（`test/vscode-mock.js`）の上で `extension.js` を動かし、実際に reportmd を実行します（reportmd を実行できなければ飛ばします。`REPORTMD_PATH` で指定できます）。
- ビルドの手順はありません（JavaScript をそのまま使います）。
