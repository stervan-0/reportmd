package build

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"reportmd/internal/config"
	"reportmd/internal/preprocess"
)

// 前処理 → Pandoc（filter.lua）を通した結果を確認するテスト。
// Pandoc が入っていない環境では飛ばす。

func pandoc(t *testing.T, rmd, format string, settings map[string]any, extra ...string) (string, string) {
	t.Helper()
	return pandocWithConfig(t, rmd, format, settings, config.Default(), extra...)
}

// pandocWithConfig は、表紙のレイアウト（cover.json）を cfg から作る。
func pandocWithConfig(t *testing.T, rmd, format string, settings map[string]any, cfg *config.Config, extra ...string) (string, string) {
	t.Helper()
	if _, err := exec.LookPath("pandoc"); err != nil {
		t.Skip("pandoc が見つかりません")
	}
	pre, err := preprocess.Run(rmd)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	filter := filepath.Join(dir, "filter.lua")
	os.WriteFile(filter, filterLua, 0o644)
	cover, err := CoverJSON(cfg)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, coverFileName), cover, 0o644)
	args := []string{"-f", pandocReader, "--lua-filter=" + filter, "-t", format, "--wrap=none"}
	if settings != nil {
		meta, _ := json.Marshal(map[string]any{"reportmd": settings})
		path := filepath.Join(dir, "meta.json")
		os.WriteFile(path, meta, 0o644)
		args = append(args, "--metadata-file="+path)
	}
	cmd := exec.Command("pandoc", append(args, extra...)...)
	cmd.Stdin = strings.NewReader(pre.Text)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("pandoc が失敗しました: %s", stderr.String())
	}
	return out.String(), stderr.String()
}

type filterCase struct {
	name     string
	rmd      string
	format   string
	settings map[string]any
	has      []string
	hasNot   []string
	// order は、この順に出てくるべき文字列
	order []string
}

const smallTable = "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n"
const threeRows = "| 条件 | 結果 |\n|:---|---:|\n| A | 10 |\n| B | 20 |\n| C | 30 |\n"
const refDoc = "![f:構成](a.png){#sys}\n\n![f:二つ目](b.png)\n\n![t:結果]{#result}\n" + smallTable + "\n![f:三つ目](c.png){#third width=50%}\n\n"
const coverDoc = "---\ntitle: 実験レポート\nauthor: 山田 太郎\ncover:\n  副題: \"**副題**\"\n  科目: 情報工学実験\n  学籍番号: 1234567\n---\n\n本文\n"
const eqDoc = "次の式\n$$\nK = \\frac{1}{2} m v^2 % 運動エネルギー\n$$ {#kinetic}\nとなる。\n\n$$ a + b $$ {-}\n\n$$ E = mc^2 $$ {#energy}\n\n"

var filterCases = []filterCase{
	// 改ページ・揃え
	{name: "改ページは LaTeX で \\newpage", rmd: "a\n\n^\n\nb\n", format: "latex", has: []string{`\newpage`}},
	{name: "コードの ^ は改ページにならない", rmd: "```\n^\n```\n\n$$\n^\n$$\n", format: "latex", hasNot: []string{`\newpage`}},
	{name: "LaTeX 以外では改ページを取り除く", rmd: "a\n\n^\n\nb\n", format: "html", hasNot: []string{"reportmd-pagebreak"}},
	{name: "右揃えは flushright", rmd: "--> a\n", format: "latex", has: []string{`\begin{flushright}`, `\end{flushright}`}},
	{name: "中央揃えは center", rmd: "<-> a\n", format: "latex", has: []string{`\begin{center}`}},
	{name: "複数行は行ごとに改行", rmd: "--> a\n--> b\n", format: "latex", has: []string{"a\\\\\nb"}},
	{name: "HTML では text-align", rmd: "--> a\n", format: "html", has: []string{"text-align: right;"}},

	// 見出し
	{name: "#1〜#3 は番号つき", rmd: "#1 a\n\n#2 b\n\n#3 c\n", format: "latex", has: []string{`\section{a}`, `\subsection{b}`, `\subsubsection{c}`}, hasNot: []string{"section*", "reportmd-num"}},
	{name: "標準の # は番号なし", rmd: "# a\n\n## b\n\n### c\n", format: "latex", has: []string{`\section*{a}`, `\subsection*{b}`, `\subsubsection*{c}`}},
	{name: "見出しのインライン書式", rmd: "#1 **太字**と$x^2$\n", format: "latex", has: []string{`\textbf{太字}`, `\(x^2\)`}},

	// タイトルと著者
	{name: "タイトルは本文に出さない", rmd: "---\ntitle: 題名\nauthor: 著者\n---\n\n本文\n", format: "latex", hasNot: []string{`\maketitle`}},
	{name: "対応外のメタデータは反映しない", rmd: "---\ntitle: a\nheader-includes: XYZHEADER\n---\n\n本文\n", format: "latex", hasNot: []string{"XYZHEADER"}},

	// 表紙
	{name: "cover がなければ表紙を付けない", rmd: "---\ntitle: 題名\n---\n\n本文\n", format: "latex", hasNot: []string{"titlepage", "題名"}},
	{name: "cover: false なら表紙を付けない", rmd: "---\ntitle: 題名\ncover: false\n---\n\n本文\n", format: "latex", hasNot: []string{"titlepage"}},
	{name: "表紙は本文の前の titlepage", rmd: coverDoc, format: "latex", order: []string{
		`\hypersetup{pageanchor=false}`, `\begin{titlepage}`, `\vspace*{40mm}`,
		`{\noindent\centering\fontsize{24pt}{28.8pt}\selectfont\addfontfeatures{FakeBold=5.714}\addCJKfontfeatures{FakeBold=5.714} 実験レポート\par}`,
		`{\noindent\centering\fontsize{14pt}{16.8pt}\selectfont \textbf{副題}\par}`, `\vspace*{\fill}`,
		`\begin{tabular}{@{}l@{\hspace{2em}}l@{}}`, "科目 & 情報工学実験 \\\\", "学籍番号 & 1234567 \\\\", "氏名 & 山田 太郎 \\\\", `\end{tabular}`,
		`\end{titlepage}`, `\hypersetup{pageanchor=true}`, "本文"}},
	{name: "値のない行は表紙に出さない", rmd: coverDoc, format: "latex", hasNot: []string{"担当教員", "提出日", "所属"}},
	{name: "cover: true なら title と author だけ", rmd: "---\ntitle: 題名\nauthor: [山田, 佐藤]\ncover: true\n---\n\n本文\n", format: "latex", has: []string{`{FakeBold=5.714} 題名\par}`, "氏名 & 山田、佐藤 \\\\"}},
	{name: "HTML の表紙", rmd: coverDoc, format: "html", has: []string{`class="reportmd-cover"`, "font-size: 24pt; font-weight: bold;", "学籍番号　1234567"}, hasNot: []string{"titlepage"}},
	{name: "表紙の値は本文の変換を受けない", rmd: "---\ntitle: \"![f:図](a.png)\"\ncover: true\n---\n", format: "latex", hasNot: []string{"図1"}},

	// 図表の番号（HTML）
	{name: "図は出現順に採番", rmd: "![f:一つ目](a.png)\n\n![f:二つ目](b.png)\n", format: "html", has: []string{">図1 一つ目</figcaption>", ">図2 二つ目</figcaption>"}},
	{name: "表は図と別の連番", rmd: "![f:図](a.png)\n\n![t:一つ目]\n" + smallTable + "\n![f:図](b.png)\n\n![t:二つ目]\n" + smallTable, format: "html", has: []string{"<caption>表1 一つ目</caption>", "<caption>表2 二つ目</caption>", ">図2 図</figcaption>"}},
	{name: "タイトルが空なら番号だけ", rmd: "![f](a.png)\n\n![t]\n" + smallTable, format: "html", has: []string{">図1</figcaption>", "<caption>表1</caption>"}},
	{name: "設定でラベルを変えられる", rmd: "![f:A](a.png)\n\n![t:B]\n" + smallTable, format: "html", settings: map[string]any{"figure_label": "Fig.", "table_label": "Table"}, has: []string{">Fig.1 A</figcaption>", "<caption>Table1 B</caption>"}},
	{name: "通常の画像は図にしない", rmd: "![図](a.png)\n", format: "html", hasNot: []string{"図1"}},

	// 図表（LaTeX）
	{name: "図は浮動体にしない", rmd: "![f:システム構成図](a.png)\n", format: "latex", has: []string{`\begin{samepage}\begin{center}`, "図1 システム構成図"}, hasNot: []string{`\begin{figure}`, `\caption`}},
	{name: "図のキャプションは既定で下", rmd: "![f:図](a.png)\n", format: "latex", order: []string{`\includegraphics`, "図1 図"}},
	{name: "figure_position top", rmd: "![f:図](a.png)\n", format: "latex", settings: map[string]any{"figure_position": "top"}, order: []string{"図1 図", `\includegraphics`}},
	{name: "表のキャプションは既定で上", rmd: "![t:実験結果]\n" + smallTable, format: "latex", has: []string{`\nopagebreak`}, hasNot: []string{`\caption`}, order: []string{"表1 実験結果", `\begin{tabular}`}},
	{name: "table_position bottom", rmd: "![t:実験結果]\n" + smallTable, format: "latex", settings: map[string]any{"table_position": "bottom"}, order: []string{`\end{tabular}`, "表1 実験結果"}},
	{name: "画像の width", rmd: "![f:図](a.png){width=50%}\n", format: "latex", has: []string{`width=0.5\textwidth`}},

	// 表の組版
	{name: "tabular に組む", rmd: "![t:結果]\n" + threeRows, format: "latex", has: []string{`\begin{reportmdtablebox}`, `{\reportmdtablestyle`, `\begin{tabular}{!{\reportmdvside}l!{\reportmdvrule}r!{\reportmdvside}}`}, hasNot: []string{"longtable"}},
	{name: "罫線の順序", rmd: "![t:結果]\n" + threeRows, format: "latex", order: []string{`\reportmdruletop`, `\reportmdtablehead{条件}`, `\reportmdruleheader`, "A &", `\reportmdrulerows`, "B &", `\reportmdrulerows`, "C &", `\reportmdrulebottom`}},
	{name: "見出しは既定で中央揃え", rmd: "![t:結果]\n" + threeRows, format: "latex", has: []string{`\multicolumn{1}{!{\reportmdvside}c!{\reportmdvrule}}{\reportmdtablehead{条件}}`, `\multicolumn{1}{c!{\reportmdvside}}{\reportmdtablehead{結果}}`}},
	{name: "header.align column", rmd: "![t:結果]\n" + threeRows, format: "latex", settings: map[string]any{"table_header_align": "column"}, has: []string{`\reportmdtablehead{条件} & \reportmdtablehead{結果} \\`}},
	{name: "セルのインライン書式", rmd: "![t]\n| a | b |\n|---|---|\n| **太字** | $x^2$ |\n", format: "latex", has: []string{`\textbf{太字} & \(x^2\) \\`}},
	{name: "width full は tabularx", rmd: "![t:結果]\n" + threeRows, format: "latex", settings: map[string]any{"table_width": "full"}, has: []string{`\begin{tabularx}{\linewidth}{!{\reportmdvside}>{\raggedright\arraybackslash}X!{\reportmdvrule}>{\raggedleft\arraybackslash}X!{\reportmdvside}}`, `\end{tabularx}`}},
	{name: "![t] のない表も同じ形・番号なし", rmd: threeRows, format: "latex", has: []string{`\begin{tabular}`}, hasNot: []string{"表1"}},
	{name: "標準のキャプションはそのまま", rmd: threeRows + "\n: 標準のキャプション\n", format: "latex", hasNot: []string{"表1"}, order: []string{"標準のキャプション", `\begin{tabular}`}},

	// 参照
	{name: "@名前 を図表の番号に", rmd: refDoc + "@sys と @result と @third を参照。\n", format: "plain", has: []string{"図1 と 表1 と 図3 を参照。"}},
	{name: "後ろの図表も参照できる", rmd: "@third を見よ。\n\n" + refDoc, format: "plain", has: []string{"図3 を見よ。"}},
	{name: "直後の日本語", rmd: refDoc + "@sysに示すように、@resultの値は\n", format: "plain", has: []string{"図1に示すように、表1の値は"}},
	{name: "@{名前}", rmd: refDoc + "@{result}に示す。\n", format: "plain", has: []string{"表1に示す。"}},
	{name: "[@a; @b]", rmd: refDoc + "[@sys; @result] を参照。\n", format: "plain", has: []string{"図1、表1 を参照。"}},
	{name: "コードとメールアドレスは置き換えない", rmd: refDoc + "`@sys` と a@sys.com\n", format: "plain", has: []string{"@sys", "a@sys.com"}, hasNot: []string{"図1 と"}},

	// 参照のリンク（PDF 内で、クリックすると参照先へ移動する）
	{name: "参照は参照先へのリンク", rmd: refDoc + "$$ E $$ {#eq}\n\n@sys と @result と @eq\n", format: "latex", has: []string{
		`\begin{samepage}\begin{center}\hypertarget{sys}{}`, `\protect\hypertarget{result}{}{}表1 結果`, `\protect\hypertarget{eq}{}{}\[ E`,
		`\protect\hyperlink{sys}{図1} と \protect\hyperlink{result}{表1} と \protect\hyperlink{eq}{式(1)}`}},
	{name: "名前のない図表には目印を置かない", rmd: "![f:図](a.png)\n\n![t:表]\n" + smallTable, format: "latex", hasNot: []string{"hypertarget"}},
	{name: "直後の日本語はリンクの外", rmd: refDoc + "@sysに示す\n", format: "latex", has: []string{`\protect\hyperlink{sys}{図1}に示す`}},
	{name: "同じ名前の2つ目には目印を置かない", rmd: "![f:a](a.png){#x}\n\n![f:b](b.png){#x}\n\n@x\n", format: "latex", has: []string{`\protect\hyperlink{x}{図1}`}, order: []string{`\hypertarget{x}`, "図1 a", "図2 b"}, hasNot: []string{"hypertarget{x}{}\\includegraphics"}},
	{name: "HTML でもリンク", rmd: refDoc + "@sys\n", format: "html", has: []string{`id="sys"`, `href="#sys"`}},

	// 数式
	{name: "数式の通し番号", rmd: eqDoc, format: "latex", has: []string{"\\[\nK = \\frac{1}{2} m v^2 % 運動エネルギー\n\\tag{1}\\]", `\[ a + b \]`, "\\[ E = mc^2\n\\tag{2}\\]"}, hasNot: []string{"reportmd-equation"}},
	{name: "式の参照", rmd: eqDoc + "@kineticと @energy\n", format: "plain", has: []string{"式(1)と 式(2)"}},
	{name: "equation_label", rmd: eqDoc + "@energy\n", format: "plain", settings: map[string]any{"equation_label": "Eq."}, has: []string{"Eq.(2)"}},
	{name: "equation_numbering false", rmd: eqDoc, format: "latex", settings: map[string]any{"equation_numbering": false}, hasNot: []string{`\tag`}},
	{name: "インライン数式は番号なし", rmd: "本文 $x^2$ の式\n", format: "latex", has: []string{`\(x^2\)`}, hasNot: []string{`\tag`}},

	// 段落の途中の改行
	{name: "日本語どうしの改行は詰める", rmd: "日本語の\n文章。\n\n日本語\nEnglish\n", format: "html", has: []string{"日本語の文章。", "日本語 English"}},

	// 字下げ
	{name: "2スペースの字下げ", rmd: "  段落です\n", format: "latex", has: []string{`\noindent\hspace*{\reportmdchar}段落です`}, hasNot: []string{"reportmd-indent"}},

	// コードブロック
	{name: "コードブロックは reportmdcode で囲む", rmd: codeDoc, format: "latex",
		order: []string{`\begin{reportmdcode}`, `\begin{Highlighting}`, `\KeywordTok{def}`, `\end{Highlighting}`, `\end{reportmdcode}`,
			`\begin{reportmdcode}`, `\begin{verbatim}`, "plain block", `\end{verbatim}`, `\end{reportmdcode}`}},
	{name: "code_highlight false なら色を付けない", rmd: codeDoc, format: "latex", settings: map[string]any{"code_highlight": false},
		has: []string{"\\begin{verbatim}\ndef hello():"}, hasNot: []string{"Highlighting", "KeywordTok"}},
	{name: "リストの中のコードブロック", rmd: "- 項目\n\n  ```\n  x = 1\n  ```\n", format: "latex",
		order: []string{`\item`, `\begin{reportmdcode}`, "x = 1", `\end{reportmdcode}`, `\end{itemize}`}},
	{name: "HTML は背景と枠の div で囲む", rmd: codeDoc, format: "html",
		has: []string{`background: #F5F5F5;`, `border: 0.4pt solid #BFBFBF;`, `font-size: 10.5pt;`, `white-space: pre-wrap;`, `class="sourceCode python"`}},
	{name: "HTML の背景と枠を付けない", rmd: codeDoc, format: "html", settings: map[string]any{"code_background": "", "code_border": ""},
		has: []string{`white-space: pre-wrap;`}, hasNot: []string{"background:", "border:"}},
	{name: "PDF・HTML 以外ではコードブロックを囲まない", rmd: codeDoc, format: "native", has: []string{`CodeBlock`, `[ "python" ]`}, hasNot: []string{"reportmdcode", "Div"}},
}

const codeDoc = "```python\ndef hello():\n    print(\"こんにちは\")\n```\n\n~~~\nplain block\n~~~\n"

func TestFilter(t *testing.T) {
	for _, c := range filterCases {
		t.Run(c.name, func(t *testing.T) {
			out, _ := pandoc(t, c.rmd, c.format, c.settings)
			for _, want := range c.has {
				if !strings.Contains(out, want) {
					t.Errorf("%q が含まれるはず:\n%s", want, out)
				}
			}
			for _, unwanted := range c.hasNot {
				if strings.Contains(out, unwanted) {
					t.Errorf("%q は含まれないはず:\n%s", unwanted, out)
				}
			}
			pos := 0
			for _, want := range c.order {
				i := strings.Index(out[pos:], want)
				if i < 0 {
					t.Errorf("%q が順に出てくるはず:\n%s", want, out)
					break
				}
				pos += i + len(want)
			}
		})
	}
}

func TestFilterWarnings(t *testing.T) {
	out, stderr := pandoc(t, "本文\n\n![f:図](a.png) 説明\n", "html", map[string]any{"source": "a.rmd"})
	if !strings.Contains(stderr, "a.rmd:3: warning: 図の行には、画像だけを書いてください") || !strings.Contains(out, "説明") || strings.Contains(out, "図1") {
		t.Errorf("図の行に画像以外の文字があれば警告して番号を付けない: %s", stderr)
	}

	out, stderr = pandoc(t, refDoc+"@nothing を参照。\n", "plain", map[string]any{"source": "a.rmd"})
	if !strings.Contains(stderr, "a.rmd: warning: 参照先の図表・数式が見つかりません: @nothing") || !strings.Contains(out, "@nothing を参照。") {
		t.Errorf("見つからない名前は警告して残す: %s", stderr)
	}

	_, stderr = pandoc(t, eqDoc, "latex", map[string]any{"source": "a.rmd", "equation_numbering": false})
	if !strings.Contains(stderr, "a.rmd:4: warning: 数式に番号を付けない設定") {
		t.Errorf("番号なしの設定で名前を付けた数式は警告する: %s", stderr)
	}
}

func TestFilterCoverLayout(t *testing.T) {
	cfg, err := config.New(map[string]any{"cover": map[string]any{"layout": []any{
		map[string]any{"text": "{{第 {回} 回}} {title}", "align": "right", "size": "10pt"},
		map[string]any{"space": "1cm"},
		map[string]any{"fields": []any{[]any{"{ラベル}", "{author}"}}, "align": "left", "bold": true},
	}}}, "")
	if err != nil {
		t.Fatal(err)
	}
	rmd := "---\ntitle: 題名\nauthor: 山田\ncover:\n  回: 3\n  ラベル: 氏名\n---\n"
	out, _ := pandocWithConfig(t, rmd, "latex", nil, cfg)
	for _, want := range []string{
		`{\noindent\raggedleft\fontsize{10pt}{12pt}\selectfont \{第 3 回\} 題名\par}`,
		`\vspace*{1cm}`,
		// 文字サイズの指定がなければ、本文の文字サイズ（10.5pt）の強さ
		"{\\noindent\\raggedright\\addfontfeatures{FakeBold=2.5}\\addCJKfontfeatures{FakeBold=2.5} \\begin{tabular}{@{}l@{\\hspace{2em}}l@{}}\n氏名 & 山田 \\\\",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("%q が含まれるはず:\n%s", want, out)
		}
	}
	if strings.Contains(out, `\vspace*{40mm}`) {
		t.Errorf("既定のレイアウトは使わない")
	}
}

func TestFilterCoverWarnings(t *testing.T) {
	_, stderr := pandoc(t, "---\ntitle: a\ncover:\n  学生番号: 1\n  科目: b\n---\n", "latex", map[string]any{"source": "a.rmd"})
	if !strings.Contains(stderr, "a.rmd: warning: フロントマターの cover の「学生番号」は、表紙のレイアウト（設定の cover.layout）で使われていません") ||
		strings.Contains(stderr, "科目") {
		t.Errorf("レイアウトで使わない cover の値は警告する: %s", stderr)
	}
}

func TestFilterEquationOrder(t *testing.T) {
	out, _ := pandoc(t, "*強調 $$a$$* と $$b$$ 注[^1]\n$$c$$ {#c}\n\n[^1]: $$n$$\n\n@c\n", "latex", nil)
	got := regexp.MustCompile(`\\\[(\w)\n\s*\\tag\{(\d)\}`).FindAllStringSubmatch(out, -1)
	var pairs []string
	for _, m := range got {
		pairs = append(pairs, m[1]+m[2])
	}
	if strings.Join(pairs, " ") != "a1 b2 n3 c4" {
		t.Errorf("番号は文書の順（強調の中や脚注も数える）: %v", pairs)
	}
}

// pptxSlides は、前処理 → Pandoc（filter.lua）で PowerPoint を作り、スライドごとの文字を返す。
// 文字は「|」で区切り、画像は [画像]、表は [表]、題名の下の線は [線] と書く。
func pptxSlides(t *testing.T, rmd string) []string {
	t.Helper()
	if _, err := exec.LookPath("pandoc"); err != nil {
		t.Skip("pandoc が見つかりません")
	}
	dir := t.TempDir()
	// 画像は、中身が壊れていても Pandoc が読めるように、本物の PNG を使う
	png, err := os.ReadFile(filepath.Join("..", "..", "examples", "images", "pipeline.png"))
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "a.png"), png, 0o644)
	output := filepath.Join(dir, "out.pptx")
	if _, err := Run(Options{Input: filepath.Join(dir, "a.reportmd"), Output: output, Format: Pptx, Config: config.Default(), Source: []byte(rmd)}); err != nil {
		t.Fatal(err)
	}

	r, err := zip.OpenReader(output)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	files := map[string]*zip.File{}
	for _, f := range r.File {
		files[f.Name] = f
	}
	token := regexp.MustCompile(`<a:t>([^<]*)</a:t>|<p:pic>|<a:tbl>|name="` + ruleShapeName + `"`)
	var slides []string
	for i := 1; files[fmt.Sprintf("ppt/slides/slide%d.xml", i)] != nil; i++ {
		rc, err := files[fmt.Sprintf("ppt/slides/slide%d.xml", i)].Open()
		if err != nil {
			t.Fatal(err)
		}
		xml, _ := io.ReadAll(rc)
		rc.Close()
		var parts []string
		for _, m := range token.FindAllStringSubmatch(string(xml), -1) {
			switch m[0] {
			case "<p:pic>":
				parts = append(parts, "[画像]")
			case "<a:tbl>":
				parts = append(parts, "[表]")
			case `name="` + ruleShapeName + `"`:
				parts = append(parts, "[線]")
			default:
				parts = append(parts, m[1])
			}
		}
		slides = append(slides, strings.Join(parts, "|"))
	}
	return slides
}

func TestFilterPptx(t *testing.T) {
	cases := []struct {
		name string
		rmd  string
		want []string
	}{
		{"見出しごとに1枚。番号は文字で付ける", "#1 目的\n\n本文\n\n#1 原理\n\n#2 前提\n\n説明\n\n#3 細目\n\n# 番号なし\n\n#2 次\n",
			[]string{"1 目的|本文|[線]", "2 原理|[線]", "2.1 前提|説明|[線]", "2.1.1 細目|[線]", "番号なし|[線]", "2.2 次|[線]"}},
		{"改ページは新しいスライド", "#1 a\n\n前\n\n^\n\n後\n", []string{"1 a|前|[線]", "後"}},
		{"図は画像とキャプション", "#1 a\n\n![f:構成](a.png){#sys}\n\n@sysに示す\n", []string{"1 a|[画像]|図1 構成|図1に示す|[線]"}},
		{"表は番号つき", "![t:結果]{#r}\n| a | b |\n|---|---|\n| 1 | 2 |\n\n@r\n", []string{"[表]|a|b|1|2|表1 結果", "表1"}}, // 表のあとは、Pandoc が次のスライドにする
		{"脚注は最後の「注」のスライド", "#1 a\n\n本文[^1]と[^2]\n\n[^1]: 一つ目\n[^2]: 二つ目\n", []string{"1 a|本文|1|と|2|[線]", "注|一つ目|二つ目|[線]"}},
		{"日本語どうしの改行は詰める", "生成する\nレポート\n", []string{"生成するレポート"}},
		{"表紙だけで1枚", "---\ntitle: 題名\ncover: true\n---\n\n本文\n", []string{"題名", "本文"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := strings.Join(pptxSlides(t, c.rmd), "\n")
			if want := strings.Join(c.want, "\n"); got != want {
				t.Errorf("スライド:\n%s\nのはず:\n%s", got, want)
			}
		})
	}
}
