package build

import (
	"archive/zip"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"reportmd/internal/config"
)

func TestLengthPoints(t *testing.T) {
	cases := map[string]int{"25mm": 1417, "2.5cm": 1417, "72pt": 1440, "1in": 1440, "6pt": 120}
	for in, want := range cases {
		if got := twips(lengthPoints(in)); got != want {
			t.Errorf("twips(lengthPoints(%q)) = %d（期待 %d）", in, got, want)
		}
	}
}

func TestRuleSize(t *testing.T) {
	cases := map[string]int{"": 0, "0.8pt": 6, "1.2pt": 10, "0.1pt": 2, "20pt": 96}
	for in, want := range cases {
		if got := ruleSize(in); got != want {
			t.Errorf("ruleSize(%q) = %d（期待 %d）", in, got, want)
		}
	}
}

// wellFormed は、XML として読めるか確かめる。
func wellFormed(t *testing.T, s string) {
	t.Helper()
	d := xml.NewDecoder(strings.NewReader(s))
	for {
		if _, err := d.Token(); err != nil {
			if !errors.Is(err, io.EOF) {
				t.Fatalf("XML として読めません: %v", err)
			}
			return
		}
	}
}

func TestDocxStylesDefault(t *testing.T) {
	styles := DocxStyles(config.Default())
	wellFormed(t, styles)
	for _, want := range []string{
		`<w:rFonts w:ascii="IPAexMincho"`,
		`<w:sz w:val="21"/>`,              // 10.5pt
		`w:line="378" w:lineRule="exact"`, // 10.5pt × 1.2 × 1.5 = 18.9pt
		`<w:ind w:firstLine="210"/>`,      // 1字
		`<w:rFonts w:ascii="IPAexGothic"`,
		`<w:sz w:val="28"/>`,                                                // 見出し1 の 14pt
		`<w:jc w:val="center"/>`,                                            // 表の配置
		`<w:top w:val="single" w:sz="6" w:space="0" w:color="000000"/>`,     // 0.8pt
		`<w:bottom w:val="single" w:sz="10" w:space="0" w:color="000000"/>`, // 見出し行の下の 1.2pt
		`<w:left w:w="120" w:type="dxa"/>`,                                  // セルの余白 6pt
		`w:styleId="reportmdCover2"`,
		`w:styleId="reportmdCoverTable6"`,
	} {
		if !strings.Contains(styles, want) {
			t.Errorf("styles.xml に %s がない", want)
		}
	}
	for _, unwanted := range []string{"<w:insideH", "<w:insideV"} {
		if strings.Contains(styles, unwanted) {
			t.Errorf("styles.xml に %s がある", unwanted)
		}
	}
}

func TestDocxStylesCustom(t *testing.T) {
	cfg, err := config.New(map[string]any{
		"font":    map[string]any{"main": "A<B"},
		"caption": map[string]any{"table_position": "bottom"},
		"table": map[string]any{
			"position": "left",
			"header":   map[string]any{"bold": true},
			"rules":    map[string]any{"rows": "0.4pt", "vertical": "0.4pt"},
		},
	}, "")
	if err != nil {
		t.Fatal(err)
	}
	styles := DocxStyles(cfg)
	wellFormed(t, styles)
	for _, want := range []string{`w:ascii="A&lt;B"`, `<w:insideH w:val="single" w:sz="3"`, `<w:insideV w:val="single" w:sz="3"`, `<w:jc w:val="left"/>`} {
		if !strings.Contains(styles, want) {
			t.Errorf("styles.xml に %s がない", want)
		}
	}
}

// sourceCodeStyle は、styles.xml のコードブロックのスタイル（Source Code）の部分を返す。
func sourceCodeStyle(t *testing.T, styles string) string {
	t.Helper()
	start := strings.Index(styles, `w:styleId="SourceCode"`)
	if start < 0 {
		t.Fatal("Source Code のスタイルがない")
	}
	return styles[start : start+strings.Index(styles[start:], "</w:style>")]
}

func TestDocxCodeStyle(t *testing.T) {
	styles := DocxStyles(config.Default())
	wellFormed(t, styles)
	got := sourceCodeStyle(t, styles)
	// 枠の太さは 1/8 pt、枠と文字の間は 5pt（10.5pt の半分を pt の整数に）、左右は枠と文字の間と線の太さの分だけ下げる
	for _, want := range []string{
		`<w:left w:val="single" w:sz="3" w:space="5" w:color="BFBFBF"/>`,
		`<w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>`,
		`<w:spacing w:before="260" w:after="260" w:line="302" w:lineRule="exact"/>`,
		`<w:ind w:left="108" w:right="108" w:firstLine="0"/>`,
		`<w:sz w:val="21"/>`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない:\n%s", want, got)
		}
	}

	cfg, err := config.New(map[string]any{"code": map[string]any{"background": false, "border": false, "font_size": "9pt", "line_spacing": 1.0}}, "")
	if err != nil {
		t.Fatal(err)
	}
	styles = DocxStyles(cfg)
	wellFormed(t, styles)
	got = sourceCodeStyle(t, styles)
	for _, want := range []string{`<w:spacing w:before="160" w:after="160" w:line="216" w:lineRule="exact"/>`, `<w:ind w:left="0" w:right="0" w:firstLine="0"/>`, `<w:sz w:val="18"/>`} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない:\n%s", want, got)
		}
	}
	for _, unwanted := range []string{"<w:pBdr>", "<w:shd"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("背景も枠もなければ %s を書かない", unwanted)
		}
	}
}

func TestDocxHeadingRules(t *testing.T) {
	// コードブロックの枠（これも段落の罫線）は付けずに数える
	noCodeBorder := map[string]any{"border": false}
	plain, err := config.New(map[string]any{"code": noCodeBorder}, "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(DocxStyles(plain), "<w:pBdr>") {
		t.Errorf("既定では見出しに罫線を付けない")
	}
	cfg, err := config.New(map[string]any{"heading": map[string]any{"rules": []any{"0.8pt", false, "0.4pt"}}, "code": noCodeBorder}, "")
	if err != nil {
		t.Fatal(err)
	}
	styles := DocxStyles(cfg)
	wellFormed(t, styles)
	// 太さは 1/8 pt、文字との間は見出しの文字サイズの 0.2 倍（pt の整数）
	if got := strings.Count(styles, "<w:pBdr>"); got != 2 {
		t.Errorf("線を引く見出しは2つ: %d", got)
	}
	for _, want := range []string{`<w:bottom w:val="single" w:sz="6" w:space="3" w:color="000000"/>`, `<w:bottom w:val="single" w:sz="3" w:space="2" w:color="000000"/>`} {
		if !strings.Contains(styles, want) {
			t.Errorf("%s がない", want)
		}
	}
}

func TestDocxSection(t *testing.T) {
	cfg, err := config.New(map[string]any{"document": map[string]any{"paper": "b5"}}, "")
	if err != nil {
		t.Fatal(err)
	}
	// B5（176mm × 250mm）。ページ番号は、本文の下端から 30pt 下（余白 25mm = 70.9pt → 40.9pt）
	want := `<w:pgSz w:w="9978" w:h="14173"/><w:pgMar w:top="1417" w:right="1417" w:bottom="1417" w:left="1417" w:header="708" w:footer="817" w:gutter="0"/>`
	if got := docxSection(docxLayout(cfg).Page); got != want {
		t.Errorf("\n期待: %s\n結果: %s", want, got)
	}
}

func TestFixTables(t *testing.T) {
	table := func(jc, cells string) string {
		return `<w:tbl><w:tblPr><w:tblStyle w:val="Table" /><w:tblW w:type="auto" w:w="0" /><w:jc w:val="` + jc + `" /></w:tblPr>` + cells + `</w:tbl>`
	}
	para := func(style string) string { return `<w:p><w:pPr><w:pStyle w:val="` + style + `" /></w:pPr></w:p>` }
	doc := table("start", para("reportmdTableHeader")) +
		table("start", para("Compact")+para("reportmdEquation")+para("reportmdEquationNumber")) +
		table("start", para("reportmdCover6Label")+para("reportmdCover6")) +
		// 表の中に Compact しかなければ、表のあとの段落のスタイルは見ない
		table("start", para("Compact")) + para("reportmdEquation")
	got := fixTables(doc)
	if strings.Contains(got, `<w:jc w:val="start"`) {
		t.Errorf("表の左寄せを取り除く: %s", got)
	}
	for _, want := range []string{
		`<w:tbl><w:tblPr><w:tblStyle w:val="Table" /><w:tblW w:type="auto" w:w="0" /></w:tblPr>` + para("reportmdTableHeader"),
		`<w:tblStyle w:val="reportmdEquationTable" />`,
		`<w:tblStyle w:val="reportmdCoverTable6" />`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない: %s", want, got)
		}
	}
	if n := strings.Count(got, `<w:tblStyle w:val="reportmdEquationTable" />`); n != 1 {
		t.Errorf("数式の表のスタイルは1つ（%d）: %s", n, got)
	}
}

func TestDocxJSONCoverHeights(t *testing.T) {
	cfg, err := config.New(map[string]any{"cover": map[string]any{"layout": []any{
		map[string]any{"space": "10mm"},
		map[string]any{"text": "{title}", "size": "20pt"},
		map[string]any{"space": "fill"},
		map[string]any{"fields": []any{[]any{"氏名", "{author}"}}},
	}}}, "")
	if err != nil {
		t.Fatal(err)
	}
	data, err := DocxJSON(cfg)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		CoverHeights []float64 `json:"cover_heights"`
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	// 空きは長さ、fill は 0、文字は「文字サイズ × 1.2 × 行間 1.5」（fields は本文の 10.5pt）
	want := []float64{10 * 72 / 25.4, 20 * 1.2 * 1.5, 0, 10.5 * 1.2 * 1.5}
	if len(got.CoverHeights) != len(want) {
		t.Fatalf("高さ: %v（期待: %v）", got.CoverHeights, want)
	}
	for i := range want {
		if math.Abs(got.CoverHeights[i]-want[i]) > 1e-9 {
			t.Errorf("高さ: %v（期待: %v）", got.CoverHeights, want)
			break
		}
	}
}

func TestFixLineRules(t *testing.T) {
	lines := styleLines(DocxStyles(config.Default()))
	// 本文：10.5pt × 1.2 × 1.5 = 18.9pt（378）、表：10.5pt × 1.2 = 12.6pt（252）
	para := func(props, runs string) string { return `<w:p>` + props + runs + `</w:p>` }
	math := `<m:oMath><m:r><m:t>x</m:t></m:r></m:oMath>`
	image := `<w:r><w:drawing></w:drawing></w:r>`
	text := `<w:r><w:t>a</w:t></w:r>`
	cases := []struct{ name, in, want string }{
		{"本文の数式は最小値", para(`<w:pPr><w:pStyle w:val="BodyText" /></w:pPr>`, math),
			para(`<w:pPr><w:pStyle w:val="BodyText" /><w:spacing w:line="378" w:lineRule="atLeast"/></w:pPr>`, math)},
		{"表の画像は、揃えより前に置く", para(`<w:pPr><w:pStyle w:val="reportmdTableText" /><w:jc w:val="left" /></w:pPr>`, image),
			para(`<w:pPr><w:pStyle w:val="reportmdTableText" /><w:spacing w:line="252" w:lineRule="atLeast"/><w:jc w:val="left" /></w:pPr>`, image)},
		{"段落のプロパティがなければ標準の行送り", para("", math),
			para(`<w:pPr><w:spacing w:line="378" w:lineRule="atLeast"/></w:pPr>`, math)},
		{"独立した数式は変えない", para(`<w:pPr><w:pStyle w:val="reportmdEquation" /></w:pPr>`, `<m:oMathPara>`+math+`</m:oMathPara>`), ""},
		{"数式・画像のない段落は変えない", para(`<w:pPr><w:pStyle w:val="BodyText" /></w:pPr>`, text), ""},
	}
	for _, c := range cases {
		want := c.want
		if want == "" {
			want = c.in
		}
		if got := fixLineRules(c.in, lines); got != want {
			t.Errorf("%s\n期待: %s\n結果: %s", c.name, want, got)
		}
	}
}

// docxParagraphs は、文書を Word にして、段落ごとに「スタイル|文字」を返す。
// 表は「[表:スタイル]」、改ページは「[改ページ]」、セクションの区切りは「[区切り]」にする。
func docxParagraphs(t *testing.T, rmd string, cfg *config.Config) []string {
	t.Helper()
	if _, err := exec.LookPath("pandoc"); err != nil {
		t.Skip("pandoc が見つかりません")
	}
	dir := t.TempDir()
	png, err := os.ReadFile(filepath.Join("..", "..", "examples", "images", "pipeline.png"))
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "a.png"), png, 0o644)
	output := filepath.Join(dir, "out.docx")
	if _, err := Run(Options{Input: filepath.Join(dir, "a.reportmd"), Output: output, Format: Docx, Config: cfg, Source: []byte(rmd)}); err != nil {
		t.Fatal(err)
	}
	r, err := zip.OpenReader(output)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	var doc string
	for _, f := range r.File {
		if f.Name == "word/document.xml" {
			rc, _ := f.Open()
			data, _ := io.ReadAll(rc)
			rc.Close()
			doc = string(data)
		}
	}
	token := regexp.MustCompile(`<w:tblStyle w:val="([^"]*)"|<w:pStyle w:val="([^"]*)"|<w:t[ >][^>]*>?([^<]*)</w:t>|<m:t>([^<]*)</m:t>|<w:br w:type="page"|<w:sectPr>|</w:p>`)
	var paras []string
	style, text := "", ""
	for _, m := range token.FindAllStringSubmatch(doc, -1) {
		switch {
		case m[1] != "":
			paras = append(paras, "[表:"+m[1]+"]")
		case m[2] != "":
			style = m[2]
		case strings.HasPrefix(m[0], "<w:t"), strings.HasPrefix(m[0], "<m:t"):
			text += m[3] + m[4]
		case strings.HasPrefix(m[0], "<w:br"):
			text += "[改ページ]"
		case m[0] == "<w:sectPr>":
			text += "[区切り]"
		default:
			if style != "" || text != "" {
				paras = append(paras, style+"|"+text)
			}
			style, text = "", ""
		}
	}
	return paras
}

func TestDocxOutput(t *testing.T) {
	cases := []struct {
		name string
		rmd  string
		want []string
	}{
		{"見出しの番号は全角1字あけて文字で付ける", "#1 目的\n\n#2 前提\n\n# 番号なし\n", []string{"Heading1|1　目的", "Heading2|1.1　前提", "Heading1|番号なし"}},
		{"字下げ・右揃え・中央揃え・改ページ", "  字下げ\n\n-> 右\n\n<-> 中央\n\n^\n\n後\n",
			[]string{"reportmdIndent|字下げ", "reportmdRight|右", "reportmdCenter|中央", "reportmdSpace|[改ページ]", "BodyText|後"}},
		{"番号の付く数式は罫線のない表", "前\n$$\nE = mc^2\n$$ {#e}\n後 @e\n\n$$ a $$ {-}\n",
			[]string{"FirstParagraph|前", "[表:reportmdEquationTable]", "Compact|", "reportmdEquation|E=mc2", "reportmdEquationNumber|(1)", "reportmdContinuation|後 式(1)", "reportmdEquation|a"}},
		{"表は上にキャプション、セルにスタイル", "![t:結果]\n| a | b |\n|---|---|\n| 1 | 2 |\n",
			[]string{"reportmdTableCaption|表1 結果", "[表:Table]", "reportmdTableHeader|a", "reportmdTableHeader|b", "reportmdTableText|1", "reportmdTableText|2", "reportmdSpace|"}},
		{"文中の数式だけの段落は、後ろに幅のない空白", "| a |\n|---|\n| $x$ |\n\n- $y$\n- 項目 $z$\n",
			[]string{"reportmdSpace|", "[表:Table]", "reportmdTableHeader|a", "reportmdTableText|x\u200b", "reportmdSpace|", "Compact|y\u200b", "Compact|項目 z"}},
		{"図は下にキャプション", "![f:構成](a.png)\n", []string{"reportmdFigure|", "reportmdFigureCaption|図1 構成"}},
		{"続けて書いたコードブロックは、空きの段落で別の枠にする", "```python\nx = 1\n```\n\n```\ny\n```\n\n- 項目\n\n  ```\n  a\n  ```\n\n  ```\n  b\n  ```\n",
			[]string{"SourceCode|x = 1", "reportmdSpace|", "SourceCode|y", "|項目", "SourceCode|a", "reportmdSpace|", "SourceCode|b"}},
		{"間に段落があれば空きの段落は入れない", "```\nx\n```\n\n本文\n\n```\ny\n```\n", []string{"SourceCode|x", "FirstParagraph|本文", "SourceCode|y"}},
		{"表紙は項目ごとのスタイルで、本文とセクションを分ける", "---\ntitle: 題名\nauthor: 山田\ncover: true\n---\n\n本文\n",
			[]string{"reportmdSpace|", "reportmdCover2|題名", "reportmdSpace|", "reportmdSpace|", "[表:reportmdCoverTable6]", "reportmdCover6Label|氏名", "reportmdCover6|山田", "reportmdSpace|", "|[区切り]", "BodyText|本文"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := strings.Join(docxParagraphs(t, c.rmd, config.Default()), "\n")
			if want := strings.Join(c.want, "\n"); got != want {
				t.Errorf("段落:\n%s\nのはず:\n%s", got, want)
			}
		})
	}
}
