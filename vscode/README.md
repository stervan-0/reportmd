# reportmd for VS Code

reportmd（Markdown で大学のレポートを書いて PDF にするツール）を、VS Code で使いやすくする拡張機能です。

- **色分け**：`.reportmd` の独自記法（`^` `->` `<->` `#1` `![f:…]` `![t:…]` `$$ … $$ {#名前}` `@名前`）に色を付けます。そのほかは Markdown と同じ色分けです。
- **エラーの表示**：開いたときと保存するたびに `reportmd check` を実行し、誤りの箇所に波線を引きます（「問題」パネルにも一覧が出ます）。
  - 見つからない参照（`@名前`）は、その `@名前` の位置に表示します。
  - `setting.json` の誤りは、`setting.json` のその項目の位置に表示します。
- **PDF のプレビュー**：エディタの右上のプレビューのボタン（またはコマンド「reportmd: プレビューを横に表示」）で、生成した PDF を VS Code の横に表示します。
  - 開くと監視を始め、入力するたびに（保存しなくても）PDF を作り直して、プレビューも表示し直します（見ていた位置と倍率はそのまま）。
  - 生成中・エラーは、プレビューの上の欄に表示します。エラーのときは、前の PDF を表示したままにします。
  - 倍率は「幅に合わせる」「ページ全体」と 50%〜200%。Ctrl+マウスホイール、Ctrl+`+` / `-` / `0` でも変えられます。
  - プレビューを閉じると、プレビューから始めた監視も止まります。
- **PDF の生成**：エディタの右上のボタン、ステータスバー、コマンドパレット（`reportmd:` で始まるコマンド）から実行できます。
  - 「PDF を生成」：`reportmd build` を1回実行します。
  - 「監視」：`reportmd watch` を実行し、入力・保存するたびに PDF を作り直します。もう一度押すと止まります。監視中は、生成したときのエラー（LaTeX のエラーを含む）を表示します。
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
| `reportmd.openPdf` | 「PDF を生成」「監視を開始」で生成した PDF を開く場所。`preview`（VS Code の横のプレビュー。既定）・`external`（OS の PDF ビューア）・`none` |
| `reportmd.liveUpdate` | プレビュー・監視の間は、保存しなくても入力するたびに PDF を作り直す（既定 `true`。オフにすると保存したときだけ） |
| `reportmd.liveUpdateDelay` | 入力が止まってから作り直すまでの時間（ミリ秒。既定 `300`） |

## 開発

```bash
npm install    # テストに使うライブラリと、プレビューに使う pdf.js（media/pdfjs にコピーされる）
npm test       # 色分け・出力の読み取り・スキーマ・拡張機能の動作・プレビューの画面のテスト
```

- 色分けのテストは、VS Code 本体に入っている Markdown などの文法を使います（VS Code が見つからなければ飛ばします）。
- 拡張機能の動作のテストは、VS Code の API の代わり（`test/vscode-mock.js`）の上で `extension.js` を動かし、実際に reportmd を実行します（reportmd を実行できなければ飛ばします。`REPORTMD_PATH` で指定できます）。
- プレビューの画面のテストは、ヘッドレスの Chrome（または Edge）で実際に PDF を描かせます（見つからなければ飛ばします。`CHROME_PATH` で指定できます）。
- ビルドの手順はありません（JavaScript をそのまま使います）。pdf.js（`media/pdfjs`）はコミットせず、`npm install` と `.vsix` を作るときにコピーします。
