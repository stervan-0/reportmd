package build

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"reportmd/internal/config"
)

// 文献の引用（フロントマターの bibliography と @キー）を、実際の引数で Pandoc（citeproc）まで通して確かめる。

const testBib = `@article{tanaka2020,
  author = {田中, 一郎 and 佐藤, 花子},
  title = {文書作成の効率化},
  journal = {情報処理学会論文誌},
  year = {2020},
  volume = {61},
  number = {3},
  pages = {123--130}
}
@book{knuth1984,
  author = {Knuth, Donald E.},
  title = {The TeXbook},
  publisher = {Addison-Wesley},
  year = {1984}
}
@misc{pandoc,
  author = {MacFarlane, John},
  title = {Pandoc User's Guide},
  url = {https://pandoc.org/MANUAL.html},
  urldate = {2026-10-01},
  year = {2024}
}
@book{unused,
  author = {Nobody},
  title = {Not Cited},
  year = {2000}
}
@book{sys,
  author = {Same, Name},
  title = {Same Name As A Figure},
  year = {2001}
}
`

// citeHTML は、dir に refs.bib を置き、文書 body を HTML にして、本文（<body> の中）と Pandoc の出力を返す。
func citeHTML(t *testing.T, body string, cfg *config.Config, files map[string]string) (string, string) {
	t.Helper()
	text, warnings, err := citeOutput(t, body, cfg, files, HTML)
	if err != nil {
		t.Fatal(err)
	}
	if i := strings.Index(text, "<body>"); i >= 0 {
		text = text[i:]
	}
	return text, warnings
}

func citeOutput(t *testing.T, body string, cfg *config.Config, files map[string]string, format Format) (string, string, error) {
	t.Helper()
	if _, err := exec.LookPath("pandoc"); err != nil {
		t.Skip("pandoc が見つかりません")
	}
	dir := t.TempDir()
	if files == nil {
		files = map[string]string{"refs.bib": testBib}
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if cfg == nil {
		cfg = config.Default()
	}
	work := t.TempDir()
	output := filepath.Join(work, "out."+map[Format]string{HTML: "html", LaTeX: "tex", Docx: "docx", Pptx: "pptx"}[format])
	result, err := Run(Options{Input: filepath.Join(dir, "report.reportmd"), Output: output, Format: format, Config: cfg, Source: []byte(body)})
	if err != nil {
		return "", "", err
	}
	data, _ := os.ReadFile(output)
	return string(data), result.ToolOutput, nil
}

// HTML の文字だけを、空白を詰めて取り出す
func plainText(html string) string {
	text := regexp.MustCompile(`<[^>]*>`).ReplaceAllString(html, "")
	return regexp.MustCompile(`\s+`).ReplaceAllString(text, " ")
}

const citeFront = "---\nbibliography: refs.bib\n---\n\n"

func TestCitationNumbersAndList(t *testing.T) {
	html, warnings := citeHTML(t, citeFront+
		"#1 はじめに\n\n"+
		"文献 [@knuth1984] と [@tanaka2020; @pandoc] と [@knuth1984, p. 12]。\n", nil, nil)
	if warnings != "" {
		t.Errorf("警告を出さない: %s", warnings)
	}
	text := plainText(html)
	for _, want := range []string{
		"文献 [1] と [2, 3] と [1, p. 12]。",
		"参考文献",
		"[1] Donald E. Knuth. The TeXbook. Addison-Wesley, 1984.",
		"[2] 田中一郎, 佐藤花子. 文書作成の効率化. 情報処理学会論文誌. 2020, vol. 61, no. 3, p. 123–130.",
		"(参照 2026-10-01)",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("%q を含むはず:\n%s", want, text)
		}
	}
	if strings.Contains(text, "Not Cited") {
		t.Errorf("引用していない文献は一覧に出さない:\n%s", text)
	}
	// 本文の [1] は、一覧の文献へのリンク
	if !strings.Contains(html, `href="#ref-knuth1984"`) {
		t.Errorf("一覧の文献へのリンクにする:\n%s", html)
	}
	// 見出しは番号なし
	if !regexp.MustCompile(`<h1[^>]*class="unnumbered"[^>]*>参考文献</h1>`).MatchString(html) {
		t.Errorf("番号なしの見出し「参考文献」を付ける:\n%s", html)
	}
}

// @キー とだけ書いても、著者名ではなく [1] にする。直後の日本語は本文に残す。
func TestCitationInText(t *testing.T) {
	html, warnings := citeHTML(t, citeFront+"@knuth1984によれば、@tanaka2020 も。\n", nil, nil)
	if warnings != "" {
		t.Errorf("警告を出さない: %s", warnings)
	}
	if text := plainText(html); !strings.Contains(text, "[1]によれば、[2] も。") {
		t.Errorf("[1]によれば、[2] も。を含むはず:\n%s", text)
	}
}

// 図表・数式の参照と文献の引用を混ぜられる。名前が同じなら、図表・数式を優先して警告する。
func TestCitationWithFigureReferences(t *testing.T) {
	html, warnings := citeHTML(t, citeFront+
		"![f:構成](a.png){#sys}\n\n"+
		"[@sys; @knuth1984; @tanaka2020] と @sys。\n", nil, map[string]string{"refs.bib": testBib, "a.png": ""})
	text := plainText(html)
	if !strings.Contains(text, "図1、[1, 2] と 図1。") {
		t.Errorf("図1、[1, 2] と 図1。を含むはず:\n%s", text)
	}
	if strings.Contains(text, "Same Name As A Figure") {
		t.Errorf("図と同じ名前の文献は引用しない:\n%s", text)
	}
	if !strings.Contains(warnings, "文献のキー sys は、図表・数式の名前と同じです") {
		t.Errorf("図と同じ名前の文献を警告する: %s", warnings)
	}
}

func TestCitationNotFound(t *testing.T) {
	html, warnings := citeHTML(t, citeFront+"[@missing] と [@knuth1984]。\n", nil, nil)
	if !strings.Contains(warnings, "参照先の図表・数式・文献が見つかりません: @missing") {
		t.Errorf("見つからないキーを警告する: %s", warnings)
	}
	if text := plainText(html); !strings.Contains(text, "@missing と [1]。") {
		t.Errorf("見つからないキーは @キー のまま残す:\n%s", text)
	}
}

// 文献のファイルが見つからなくても、警告して文書は作る。
func TestCitationMissingBibliography(t *testing.T) {
	html, warnings := citeHTML(t, "---\nbibliography: nothing.bib\n---\n\n[@knuth1984]\n", nil, map[string]string{})
	if !strings.Contains(warnings, "文献のファイルが見つかりません: nothing.bib") {
		t.Errorf("文献のファイルがないことを警告する: %s", warnings)
	}
	if text := plainText(html); !strings.Contains(text, "@knuth1984") || strings.Contains(text, "参考文献") {
		t.Errorf("引用せず、一覧も作らない:\n%s", text)
	}
}

// 文献を引用していなければ、見出しも一覧も付けない（bibliography がない文書も同じ）。
func TestCitationNoCitations(t *testing.T) {
	for _, front := range []string{citeFront, ""} {
		html, warnings := citeHTML(t, front+"本文だけ。\n", nil, nil)
		if warnings != "" {
			t.Errorf("警告を出さない: %s", warnings)
		}
		if strings.Contains(html, "参考文献") || strings.Contains(html, `id="refs"`) {
			t.Errorf("引用がなければ一覧を作らない:\n%s", html)
		}
	}
}

// 最後の見出しが「# 参考文献」なら、見出しを足さない。bibliography.title で見出しを変えられる。
func TestCitationHeading(t *testing.T) {
	html, _ := citeHTML(t, citeFront+"[@knuth1984]\n\n# 参考文献\n", nil, nil)
	if n := strings.Count(html, "参考文献</h1>"); n != 1 {
		t.Errorf("見出しは1つだけ（%d 個）:\n%s", n, html)
	}

	// 番号付きの見出し（#1 参考文献）は別のものとして、番号なしの見出しを足す
	html, _ = citeHTML(t, citeFront+"#1 参考文献\n\n[@knuth1984]\n", nil, nil)
	if n := strings.Count(html, "参考文献</h1>"); n != 2 {
		t.Errorf("番号付きの見出しのあとに、番号なしの見出しを足す（%d 個）:\n%s", n, html)
	}

	cfg := config.Default()
	cfg.Bibliography.Title = "References"
	html, _ = citeHTML(t, citeFront+"[@knuth1984]\n", cfg, nil)
	if !strings.Contains(html, ">References</h1>") {
		t.Errorf("bibliography.title の見出しにする:\n%s", html)
	}

	cfg.Bibliography.Title = ""
	html, _ = citeHTML(t, citeFront+"[@knuth1984]\n", cfg, nil)
	if strings.Contains(html, "<h1") || !strings.Contains(plainText(html), "[1] Donald E. Knuth.") {
		t.Errorf("bibliography.title が空なら、見出しを付けずに一覧だけ:\n%s", html)
	}
}

// bibliography.style で、別の CSL ファイルのスタイルにする（設定ファイルのある場所からの相対パス）。
func TestCitationCustomStyle(t *testing.T) {
	const style = `<?xml version="1.0" encoding="utf-8"?>
<style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
  <info><title>test</title><id>test</id><updated>2026-01-01T00:00:00+00:00</updated></info>
  <citation><layout prefix="(" suffix=")"><text variable="title"/></layout></citation>
  <bibliography><layout><text value="ENTRY "/><text variable="title"/></layout></bibliography>
</style>
`
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "styles"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "styles", "my.csl"), []byte(style), 0o644)
	setting := filepath.Join(dir, "setting.json")
	os.WriteFile(setting, []byte(`{"bibliography": {"style": "styles/my.csl"}}`), 0o644)
	cfg, err := config.Load(setting, "", "html")
	if err != nil {
		t.Fatal(err)
	}
	html, _ := citeHTML(t, citeFront+"[@knuth1984]\n", cfg, nil)
	if text := plainText(html); !strings.Contains(text, "(The TeXbook)") || !strings.Contains(text, "ENTRY The TeXbook") {
		t.Errorf("設定の CSL のスタイルにする:\n%s", text)
	}

	os.WriteFile(setting, []byte(`{"bibliography": {"style": "styles/none.csl"}}`), 0o644)
	if cfg, err = config.Load(setting, "", "html"); err != nil {
		t.Fatal(err)
	}
	_, _, err = citeOutput(t, citeFront+"[@knuth1984]\n", cfg, nil, HTML)
	if e, ok := err.(*Error); !ok || e.File != setting || !strings.Contains(e.Message, "文献のスタイルのファイルが見つかりません") {
		t.Errorf("CSL ファイルがなければ、設定ファイルのエラーにする: %v", err)
	}
}

// LaTeX（PDF の元）でも、[1] と文献の一覧を出す。番号は一覧へのリンクにする。
func TestCitationLaTeX(t *testing.T) {
	tex, _, err := citeOutput(t, citeFront+"[@knuth1984]\n", nil, nil, LaTeX)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`\hyperlink{ref-knuth1984}{1}`, `\section*{参考文献}`, `\begin{CSLReferences}`, `\renewcommand{\CSLLeftMargin}`} {
		if !strings.Contains(tex, want) {
			t.Errorf("%s を含むはず", want)
		}
	}
}

// Word と PowerPoint でも、文献の一覧を作る。
func TestCitationDocxPptx(t *testing.T) {
	for _, format := range []Format{Docx, Pptx} {
		if _, _, err := citeOutput(t, citeFront+"[@knuth1984]\n", nil, nil, format); err != nil {
			t.Errorf("%s: %v", format, err)
		}
	}
}
