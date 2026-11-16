# reportmd

Markdown の書きやすさのまま、大学のレポートに必要な組版（改ページ・右揃え・中央揃え・字下げ・見出し番号・図表番号・数式番号）を追加して、PDF を出力するツールです。詳しい仕様は [docs/spec.md](docs/spec.md) を参照してください。

Go で書いた1つの実行ファイルで動きます（Ruby などの実行環境は不要です）。0.1.0（Ruby 版）と同じ記法・設定ファイルがそのまま使えます。

## 必要なもの

- Pandoc
- XeLaTeX（TeX Live など。`xeCJK` パッケージを含むもの）
- 既定のフォント：IPAex明朝・IPAexゴシック・Noto Sans Mono CJK JP（設定で変更できます）
- ビルドする場合のみ：Go 1.22 以上

揃っているかどうかは `reportmd doctor` で確認できます。

## インストール

```bash
make install            # ~/.local/bin/reportmd に入れる（PREFIX=/usr/local で変更）
make uninstall          # 取り除く（監視で使うキャッシュ ~/.cache/reportmd も消す。install で PREFIX を指定した場合は、同じ PREFIX を指定）
make dist               # Linux・macOS・Windows 向けの実行ファイルを dist/ に作る
```

`make install` は Linux・macOS（WSL を含む）向けです。Windows の PowerShell では動きません。Windows では WSL の中で `make install` するか、次の Docker を使ってください。

## Docker で使う

Docker があれば、Go・Pandoc・XeLaTeX・フォントを自分で入れなくても使えます。必要なものは、すべてイメージに入っています。Windows の PowerShell（Docker Desktop）からも使えます。

まず、このリポジトリのフォルダでイメージを作ります（最初の1回だけ。TeX Live を取ってくるので数分かかります）。

```bash
docker build -t reportmd .
```

あとは、レポートのフォルダで `reportmd` の代わりに `docker run …` と打ちます。そのフォルダをコンテナの中の `/work` に見せて、reportmd を動かします。イメージ名 `reportmd` のあとに書いたものが、そのまま reportmd のコマンドになります。

```bash
# Linux・macOS・WSL（-u は、できたファイルを自分の持ち物にするため）
docker run --rm -it -v "$PWD:/work" -u "$(id -u):$(id -g)" reportmd build report.reportmd
```

```powershell
# Windows の PowerShell
docker run --rm -it -v "$($PWD.ProviderPath):/work" reportmd build report.reportmd
```

毎回打つのは長いので、`reportmd` という名前で呼べるようにしておくと、ふつうに入れたときと同じように使えます。端末から打ったときだけ `-t` を付けるので、`reportmd build --stdin < a.reportmd` のようなリダイレクトや、スクリプトからの呼び出しもそのまま使えます（`-t` を付けると、入力が端末でないときに失敗し、エラー出力も標準出力にまとめられてしまいます）。

```bash
# ~/.bashrc に書く
reportmd() {
  local tty=
  [ -t 0 ] && [ -t 1 ] && [ -t 2 ] && tty=-t
  docker run --rm -i $tty -v "$PWD:/work" -u "$(id -u):$(id -g)" reportmd "$@"
}
```

```powershell
# $PROFILE（notepad $PROFILE で開く）に書く
function reportmd {
  $tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or [Console]::IsErrorRedirected) { @() } else { @('-t') }
  docker run --rm -i @tty -v "$($PWD.ProviderPath):/work" reportmd @args
}
```

```bash
reportmd init myreport            # 雛形を作る
reportmd build report.reportmd    # report.pdf を作る
reportmd watch report.reportmd    # 保存するたびに PDF を作り直す（Ctrl+C で終了）
reportmd doctor                   # イメージの中に必要なものが揃っているか調べる
reportmd --version                # イメージの中の reportmd のバージョン
```

Docker で使うときの注意：

- コンテナの中からは PDF ビューアを開けません。引数なしの `reportmd`（監視して作り直す）や `--open` も使えますが、ビューアは開かないので、できた PDF は自分で開いてください。
- コンテナから見えるのは、コマンドを打ったフォルダの中だけです。`../images/a.png` のような外のファイルも、`/home/…` や `C:\…` の絶対パス、`-c` で指定する別の場所の設定ファイルも使えません（「見つかりません」のエラーになります）。レポートのフォルダに移ってから実行してください。
- 使えるフォントは、イメージに入っているもの（IPAex明朝・IPAexゴシック・Noto Sans CJK JP など）だけです。`reportmd fonts` に出るのも、イメージの中のフォントです。游明朝などのほかのフォントを使うときは、フォントのフォルダを `/usr/local/share/fonts` の下に見せます（Windows のフォントなら、bash では `-v /mnt/c/Windows/Fonts:/usr/local/share/fonts/windows:ro`、PowerShell では `-v "C:\Windows\Fonts:/usr/local/share/fonts/windows:ro"` を `docker run` に足します）。
- `--keep-temp` で残した一時ファイルは、そのままではコンテナと一緒に消えます。`-e TMPDIR=/work` を `docker run` に足すと、レポートのフォルダの中に残ります。
- VS Code 拡張機能は `reportmd` を直接起動するので、Docker 版では使えません（上の関数も見えません）。VS Code で使うときは、WSL の中で `make install` してください。
- 時刻（監視中の「[15:04:05] 変更を検出しました」など）は日本時間です。変えるときは `-e TZ=UTC` のように指定します。
- reportmd を新しくしたら、`git pull` のあとに `docker build -t reportmd .` をもう一度実行します。古いイメージのままかどうかは `reportmd --version` で確かめられます。

## 使い方

ふだんは、レポートのフォルダで `reportmd` と打つだけです。

```bash
mkdir myreport && cd myreport
reportmd
```

- フォルダに `.reportmd` がなければ、雛形（`report.reportmd`・`setting.json`・`images/`）を作るか尋ねます。
- `.reportmd` を PDF にしてビューアで開き、あとは `.reportmd`・画像・設定を保存するたびに PDF を作り直します（Ctrl+C で終了）。

文書の拡張子は `.reportmd` です。0.1.0 の `.rmd` もそのまま使えます（`.rmd` は R Markdown と同じ拡張子なので、0.11.0 で変えました）。

個別のコマンドも使えます。

```bash
reportmd init myreport            # 雛形を作る
reportmd report.reportmd               # report.pdf を1回だけ出力（build は省略できる）
reportmd watch report.reportmd         # 保存するたびに PDF を作り直す
reportmd check report.reportmd         # PDF を作らずに、誤りだけを調べる（速い）
reportmd build report.reportmd -o out.pdf -c setting.json
reportmd build report.reportmd -o report.tex   # LaTeX のソース（.html .docx .pptx も可）
```

| コマンド | 説明 |
| --- | --- |
| `build` | PDF を生成する（`-o` の拡張子で `.tex` `.html` `.docx` `.pptx` も出力できる） |
| `watch` | ファイルの変更を監視し、保存のたびに生成し直す（`build -w` と同じ） |
| `check` | PDF を作らずに、構文・設定・参照（`@名前`）の誤りを調べる |
| `init` | 新しいレポートの雛形を作る（`--force` で上書き） |
| `fonts` | 設定に書ける日本語フォントの名前を表示する（`--all` ですべて） |
| `doctor` | Pandoc・XeLaTeX・LaTeX パッケージ・フォントが揃っているか調べる |

| オプション | 説明 |
| --- | --- |
| `-o`, `--output` | 出力するファイルのパス（省略時は入力ファイルと同じ場所・同じ名前の PDF） |
| `-c`, `--config` | 設定ファイルのパス（省略時は入力ファイルと同じ場所の `setting.json`、なければ内蔵の既定値） |
| `--keep-temp` | 一時ファイルを残す（前処理後の Markdown などを確認できる） |
| `-w`, `--watch` | 生成したあと、変更を監視して生成し直す |
| `--open` | 生成したファイルを PDF ビューアなどで開く（`reportmd watch report.reportmd --open` が便利） |
| `-v`, `--version` | バージョンを表示 |
| `-h`, `--help` | ヘルプを表示 |

エラーと警告は `ファイル名:行番号: error: メッセージ` の形で表示します（エディタから行に飛べます）。

## VS Code 拡張機能

[vscode/](vscode/README.md) に、VS Code の拡張機能があります。独自記法の色分け、保存するたびの誤りの表示（波線）、VS Code の中での PDF のプレビュー（保存しなくても、入力するたびに更新）、ボタンからの PDF の生成・監視、`setting.json` の補完と検査ができます。

```bash
make vscode          # vscode/reportmd-0.9.0.vsix を作る（Node.js が必要）
make vscode-docker   # 同じものを Node.js のイメージの中で作る（Node.js の代わりに Docker が必要）
```

Node.js を入れていない場合は `make vscode-docker` を使います。`npm` の取り込みなどはすべてコンテナの中で行い、できた `.vsix` だけを `vscode/` に置きます。`make` のない PowerShell では、リポジトリのフォルダで次を実行します。

```powershell
docker run --rm -v "$($PWD.ProviderPath)\vscode:/out" node:22 sh /out/scripts/package-in-docker.sh
```

VS Code の拡張機能ビューの「…」→「VSIX からのインストール...」で入れます。拡張機能が呼び出す reportmd は、ローカルに入れたもの（`make install`）です。Docker のイメージの reportmd は使えません。

## 記法

| 記法 | 意味 |
| --- | --- |
| `^`（行だけ） | 改ページ |
| `-> 文字列` | 右揃え（連続する行はまとめて1行ずつ。0.1.0 の `-->` も使える。行頭に矢印を文字で書くときは `\->`） |
| `<-> 文字列` | 中央揃え |
| `#1` `#2` `#3` | 番号付き見出し（1、1.1、1.1.1） |
| `#` `##` `###` | 番号なし見出し |
| 行頭に半角スペース2個 | その段落を1字下げ |
| `![f:タイトル](画像)` | 番号付きの図（図1 タイトル） |
| `![t:タイトル]` + 直後の表 | 番号付きの表（表1 タイトル） |
| `{#名前}` と `@名前` | 図表・数式の参照。`![f:…](a.png){#sys}`・`![t:…]{#result}` で名前を付け、本文の `@sys` が「図1」になる（PDF 内でクリックすると図へ移動する） |
| `$$ … $$` | 独立した数式。右端に通し番号 (1) が自動で付く。閉じの `$$` の後ろに `{#名前}` で参照用の名前（`@名前` が「式(1)」）、`{-}` で番号なし |

コードブロック・数式ブロック（`$$`）・YAML フロントマターの中は変換されません。フロントマターで使えるキーは `title`・`author`（PDF のメタデータになります）と `cover`（表紙）だけで、ほかのキーは警告を出して無視します。

### 表紙

フロントマターに `cover` を書くと、文書の先頭に表紙が付きます。表紙にはページ番号を付けず、本文が1ページ目になります。

```yaml
---
title: 実験レポート
author: 山田 太郎
cover:
  副題: Markdown による文書作成ツールの開発
  科目: 情報工学実験 II
  担当教員: 鈴木 一郎 先生
  提出日: 2026年10月12日
  所属: 情報工学科 3年
  学籍番号: 1234567
---
```

既定のレイアウトは、上にタイトル（`title`）と `副題`、下に `科目`・`担当教員`・`提出日`・`所属`・`学籍番号`・氏名（`author`）を項目名をそろえて並べます。書かなかった項目の行は出ません。`title` と `author` だけで表紙を作るなら `cover: true` と書きます。

レイアウトは設定の `cover.layout` で自由に変えられます（下の「表紙のレイアウト」）。

サンプルは [examples/report.reportmd](examples/report.reportmd) にあります（`make example` で PDF を作れます）。

## 設定

用紙・余白・フォント・文字サイズ・行間・見出し・キャプション・表の書式・数式の番号・表紙のレイアウトを JSON で指定します。書かなかった項目は [internal/config/default.json](internal/config/default.json) の値になります。項目の一覧は仕様書の7章を参照してください。`reportmd init` で作られる `setting.json` には、すべての項目が既定値で書かれています。

```json
{
  "page": { "margin": { "top": "30mm" } },
  "text": { "font_size": "11pt", "paragraph_indent": 0 }
}
```

`setting.json` はどの出力形式にも使う共通の設定です。同じ場所に形式ごとの設定ファイルを置くと、その形式の出力だけ設定を変えられます。

| ファイル | 内容 |
| --- | --- |
| `setting.pdf.json`・`setting.html.json`・`setting.docx.json` | `setting.json` と同じ項目。書いた項目だけ、その形式で上書きします（例：Word だけ `{"font": {"main": "Yu Mincho"}}`） |
| `setting.pptx.json` | PowerPoint のスライドの題名（フォント・太字・文字サイズ・色・下線）と本文の文字サイズ。既定値は [internal/config/default.pptx.json](internal/config/default.pptx.json) |

### 表の書式

表は、既定では三線表（上端と下端に 0.8pt、見出し行の下に太い 1.2pt の線、縦線なし）になります。`table` で細かく変えられます。

```json
{
  "table": {
    "position": "center",
    "width": "auto",
    "font_size": "9pt",
    "row_spacing": 1.3,
    "cell_padding": "6pt",
    "header": { "bold": true, "align": "center" },
    "rules": {
      "top": "0.8pt", "header": "1.2pt", "bottom": "0.8pt",
      "rows": false, "vertical": false, "sides": false
    }
  }
}
```

| 項目 | 意味 |
| --- | --- |
| `position` | 表の配置（`"center"` / `"left"`） |
| `width` | `"auto"`（内容に合わせる）/ `"full"`（本文幅いっぱい） |
| `font_size` | 表の中の文字サイズ（`null` なら本文と同じ） |
| `row_spacing` | 行の高さ（倍率） |
| `cell_padding` | セルの左右の余白 |
| `header.bold` / `header.align` | 見出し行の太字と揃え（`"column"` なら列の揃えに従う） |
| `rules.*` | 各罫線の太さ。`false` で線を引かない（`top` 上端、`header` 見出しの下、`bottom` 下端、`rows` 行の間、`vertical` 列の間、`sides` 左右の端） |

### 表紙のレイアウト

`cover.layout` に、表紙の項目を上から順に並べます。文字の中の `{名前}` には、フロントマターの `cover` の値（`{title}` と `{author}` はフロントマターの `title`・`author`）が入ります。差し込む値がどれも空の行は出しません。

```json
{
  "cover": {
    "layout": [
      { "space": "30mm" },
      { "text": "第 {回} 回 {科目} レポート", "size": "14pt" },
      { "space": "10mm" },
      { "text": "{title}", "size": "28pt", "bold": true },
      { "space": "fill" },
      { "fields": [["学籍番号", "{学籍番号}"], ["氏名", "{author}"]], "align": "right", "size": "12pt" }
    ]
  }
}
```

| 項目 | 意味 |
| --- | --- |
| `text` | 1行の文字。`{名前}` で値を差し込む（文字の `{` `}` は `{{` `}}` と書く） |
| `space` | 縦の空き（`"20mm"` など）。`"fill"` は残りの空きを埋める（複数あれば等分） |
| `fields` | `["項目名", "値"]` の組の配列。項目名をそろえた表にする。値が空の行は出さない |
| `align` | 揃え（`"center"`（既定）/ `"left"` / `"right"`） |
| `size` | 文字サイズ（`"6pt"`〜`"72pt"`。既定は本文と同じ） |
| `bold` | 太字にするか（既定は `false`） |

1つの項目には、`text`・`space`・`fields` のどれか1つを書きます。レイアウトで使っていない `cover` の値があれば、書き間違いに気付けるよう警告を出します。

## 開発

```bash
make build     # ./reportmd を作る
make test      # go vet と go test
```

PDF の生成が必要なテストは、Pandoc・XeLaTeX・既定のフォントが揃っていない環境では飛ばされます。`internal/build/testdata` には Ruby 版が生成したプリアンブルがあり、Go 版の出力が一致することを確かめています。
