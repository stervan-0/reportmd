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
make dist               # Linux・macOS・Windows 向けの実行ファイルを dist/ に作る
```

## 使い方

```bash
reportmd init myreport            # 雛形（report.rmd・setting.json・images/）を作る
cd myreport
reportmd report.rmd               # report.pdf を出力（build は省略できる）
reportmd                          # .rmd が1つだけなら、ファイル名も省略できる
reportmd watch report.rmd         # 保存するたびに PDF を作り直す
reportmd check report.rmd         # PDF を作らずに、誤りだけを調べる（速い）
reportmd build report.rmd -o out.pdf -c setting.json
reportmd build report.rmd -o report.tex   # LaTeX のソース（.html .docx も可）
```

| コマンド | 説明 |
| --- | --- |
| `build` | PDF を生成する（`-o` の拡張子で `.tex` `.html` `.docx` も出力できる） |
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
| `-v`, `--version` | バージョンを表示 |
| `-h`, `--help` | ヘルプを表示 |

エラーと警告は `ファイル名:行番号: error: メッセージ` の形で表示します（エディタから行に飛べます）。

## 記法

| 記法 | 意味 |
| --- | --- |
| `^`（行だけ） | 改ページ |
| `--> 文字列` | 右揃え（連続する行はまとめて1行ずつ） |
| `<-> 文字列` | 中央揃え |
| `#1` `#2` `#3` | 番号付き見出し（1、1.1、1.1.1） |
| `#` `##` `###` | 番号なし見出し |
| 行頭に半角スペース2個 | その段落を1字下げ |
| `![f:タイトル](画像)` | 番号付きの図（図1 タイトル） |
| `![t:タイトル]` + 直後の表 | 番号付きの表（表1 タイトル） |
| `{#名前}` と `@名前` | 図表・数式の参照。`![f:…](a.png){#sys}`・`![t:…]{#result}` で名前を付け、本文の `@sys` が「図1」になる |
| `$$ … $$` | 独立した数式。右端に通し番号 (1) が自動で付く。閉じの `$$` の後ろに `{#名前}` で参照用の名前（`@名前` が「式(1)」）、`{-}` で番号なし |

コードブロック・数式ブロック（`$$`）・YAML フロントマターの中は変換されません。フロントマターで使えるキーは `title` と `author` だけで（PDF のメタデータになります）、ほかのキーは警告を出して無視します。

サンプルは [examples/report.rmd](examples/report.rmd) にあります（`make example` で PDF を作れます）。

## 設定

用紙・余白・フォント・文字サイズ・行間・見出し・キャプション・表の書式・数式の番号を JSON で指定します。書かなかった項目は [internal/config/default.json](internal/config/default.json) の値になります。項目の一覧は仕様書の7章を参照してください。`reportmd init` で作られる `setting.json` には、すべての項目が既定値で書かれています。

```json
{
  "page": { "margin": { "top": "30mm" } },
  "text": { "font_size": "11pt", "paragraph_indent": 0 }
}
```

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

## 開発

```bash
make build     # ./reportmd を作る
make test      # go vet と go test
```

PDF の生成が必要なテストは、Pandoc・XeLaTeX・既定のフォントが揃っていない環境では飛ばされます。`internal/build/testdata` には Ruby 版が生成したプリアンブルがあり、Go 版の出力が一致することを確かめています。
