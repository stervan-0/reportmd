package build

import (
	"archive/zip"
	"bytes"
	_ "embed"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"text/template"

	"reportmd/internal/config"
)

// Word（.docx）は、設定の内容（用紙・余白・フォント・文字サイズ・行間・見出し・表・表紙）を
// スタイルにした雛形（reference.docx）を作り、Pandoc に --reference-doc で渡す。
// filter.lua は、右揃え・字下げ・キャプションなどを、雛形のスタイル（custom-style）にあてる。
// 寸法は、PDF（preamble.tex.tmpl）と同じ計算で決める。

//go:embed docx-styles.xml.tmpl
var docxStylesSource string

var docxStylesTemplate = template.Must(template.New("styles").
	Funcs(template.FuncMap{"xml": template.HTMLEscapeString}).Parse(docxStylesSource))

const (
	// referenceDocxName は、作業ディレクトリに書く雛形の名前。
	referenceDocxName = "reference.docx"
	// docxFileName は、filter.lua に Word の寸法を渡すファイルの名前（cover.json と同じ場所に置く）。
	docxFileName = "docx.json"
)

// 用紙の大きさ（mm）。b5 は LaTeX の b5paper と同じ ISO の B5。
var paperSizes = map[string][2]float64{"a4": {210, 297}, "a5": {148, 210}, "b5": {176, 250}, "letter": {215.9, 279.4}}

// LaTeX の寸法で、設定にないもの（pt）。
const (
	listSkip     = 8    // 中央揃え・右揃え・図表・引用・コードの前後の空き（trivlist の \topsep）
	displaySkip  = 10   // 独立した数式の前後の空き（\abovedisplayskip）
	footSkip     = 30   // 本文の下端から、ページ番号のベースラインまで（\footskip）
	footnoteSize = 8    // 脚注の文字サイズ（\footnotesize）
	footnoteLine = 9.5  // 脚注の行送り
	quoteIndent  = 2.5  // 引用の左右の字下げ（字数。\leftmargini）
	ruleMin      = 0.25 // Word の罫線の太さの範囲（pt）
	ruleMax      = 12
)

// twips は pt を Word の単位（1/20 pt）にする。
func twips(pt float64) int { return int(math.Round(pt * 20)) }

// halfPoints は文字サイズ（pt）を Word の単位（1/2 pt）にする。
func halfPoints(pt float64) int { return int(math.Round(pt * 2)) }

// lengthPoints は、単位つきの長さ（検証済みの "25mm" など）を pt にする。
func lengthPoints(s string) float64 {
	units := map[string]float64{"mm": 72 / 25.4, "cm": 720 / 25.4, "pt": 1, "in": 72}
	for unit, scale := range units {
		if strings.HasSuffix(s, unit) {
			v, _ := strconv.ParseFloat(strings.TrimSuffix(s, unit), 64)
			return v * scale
		}
	}
	return 0
}

// ruleSize は、罫線の太さを Word の単位（1/8 pt）にする。線を引かないなら 0。
func ruleSize(s string) int {
	if s == "" {
		return 0
	}
	pt := math.Min(math.Max(lengthPoints(s), ruleMin), ruleMax)
	return int(math.Round(pt * 8))
}

type docxHeading struct {
	Level, Outline, Size, Line, Indent int
	Rule, RuleSpace                    int // 下の線の太さ（1/8 pt。なければ 0）と、文字との間（pt）
}

type docxCover struct {
	Index                  int // cover.layout の何番目か（1から）
	Fields                 bool
	Align                  string
	Size, Line, LabelRight int
	Bold                   bool
}

type docxPage struct {
	Width, Height                    int
	Top, Bottom, Left, Right, Footer int
	TextWidth                        int
}

type docxVars struct {
	Page                        docxPage
	FontMain, FontMono          string
	HeadingFont                 string
	HeadingBold                 bool
	Size, Line, ParIndent, Char int
	HeadingBefore, HeadingAfter int
	Headings                    []docxHeading
	ListSkip, DisplaySkip       int
	QuoteIndent                 int
	FootnoteSize, FootnoteLine  int
	CaptionGap                  int
	FigureCaptionTop            bool
	TableCaptionTop             bool
	TableAlign                  string
	TableSize, TableLine        int
	TableRowPad, TableCellPad   int
	TableHeaderBold             bool
	RuleTop, RuleBottom         int
	RuleHeader, RuleRows        int
	RuleVertical, RuleSides     int
	CodeSize, CodeLine          int
	CodeSkip, CodeIndent        int    // 前後の空き（枠の外）と、左右の字下げ
	CodePadding                 int    // 枠と文字の間（pt の整数）
	CodeBorder                  int    // 枠の線の太さ（1/8 pt。なければ 0）
	CodeBorderColor             string // 枠の線の色
	CodeBackground              string // 背景の色（なければ空）
	Covers                      []docxCover
}

// docxLayout は、設定から Word の寸法を計算する。
func docxLayout(cfg *config.Config) docxVars {
	fontSize := points(cfg.Text.FontSize)
	ls := cfg.Text.LineSpacing
	leading := fontSize * baselineRatio * ls // 本文の行送り

	paper := paperSizes[cfg.Document.Paper]
	mm := 72 / 25.4
	page := docxPage{
		Width:  twips(paper[0] * mm),
		Height: twips(paper[1] * mm),
		Top:    twips(lengthPoints(cfg.Page.Margin.Top)),
		Bottom: twips(lengthPoints(cfg.Page.Margin.Bottom)),
		Left:   twips(lengthPoints(cfg.Page.Margin.Left)),
		Right:  twips(lengthPoints(cfg.Page.Margin.Right)),
		Footer: twips(math.Max(lengthPoints(cfg.Page.Margin.Bottom)-footSkip, 0)),
	}
	page.TextWidth = page.Width - page.Left - page.Right

	v := docxVars{
		Page:          page,
		FontMain:      cfg.Font.Main,
		FontMono:      cfg.Font.Mono,
		HeadingFont:   cfg.Heading.Font,
		HeadingBold:   cfg.Heading.Bold,
		Size:          halfPoints(fontSize),
		Line:          twips(leading),
		ParIndent:     twips(cfg.Text.ParagraphIndent * fontSize),
		Char:          twips(fontSize),
		HeadingBefore: twips(leading),
		HeadingAfter:  twips(leading * 0.5),
		ListSkip:      twips(listSkip),
		DisplaySkip:   twips(displaySkip),
		QuoteIndent:   twips(quoteIndent * fontSize),
		FootnoteSize:  halfPoints(footnoteSize),
		FootnoteLine:  twips(footnoteLine * ls),
		CaptionGap:    twips(leading * 0.5),

		FigureCaptionTop: cfg.Caption.FigurePosition == "top",
		TableCaptionTop:  cfg.Caption.TablePosition == "top",
		TableAlign:       cfg.Table.Position,
		TableHeaderBold:  cfg.Table.Header.Bold,
		TableCellPad:     twips(lengthPoints(cfg.Table.CellPadding)),
		RuleTop:          ruleSize(cfg.Rule("top")),
		RuleBottom:       ruleSize(cfg.Rule("bottom")),
		RuleHeader:       ruleSize(cfg.Rule("header")),
		RuleRows:         ruleSize(cfg.Rule("rows")),
		RuleVertical:     ruleSize(cfg.Rule("vertical")),
		RuleSides:        ruleSize(cfg.Rule("sides")),
	}
	for i := range 3 {
		size := points(cfg.Heading.Sizes[i])
		v.Headings = append(v.Headings, docxHeading{
			Level:   i + 1,
			Outline: i,
			Size:    halfPoints(size),
			Line:    twips(size * baselineRatio * ls),
			Indent:  twips(cfg.Heading.Indents[i] * fontSize),
		})
		if rule := cfg.HeadingRule(i); rule != "" {
			v.Headings[i].Rule = ruleSize(rule)
			// Word の罫線と文字の間は pt の整数（0〜31）
			v.Headings[i].RuleSpace = int(math.Min(math.Round(size*headingRuleGap), 31))
		}
	}

	// 表の中は本文の行間を使わない。row_spacing で広げた分を、行の上下に半分ずつ足す
	tableSize := fontSize
	if cfg.Table.FontSize != nil {
		tableSize = points(*cfg.Table.FontSize)
	}
	tableLine := tableSize * baselineRatio
	v.TableSize = halfPoints(tableSize)
	v.TableLine = twips(tableLine)
	v.TableRowPad = twips(tableLine * (cfg.Table.RowSpacing - 1) / 2)

	// コードブロックの中は本文の行間を使わない。枠や背景があれば、PDF と同じく
	// 枠と文字の間を空け、枠が本文の幅に収まるよう左右を下げる
	size := codeSize(cfg)
	v.CodeSize = halfPoints(size)
	v.CodeLine = twips(size * baselineRatio * cfg.Code.LineSpacing)
	v.CodeSkip = twips(listSkip)
	v.CodeBorder = ruleSize(cfg.CodeBorder())
	v.CodeBorderColor = codeBorderColor
	v.CodeBackground = cfg.CodeBackground()
	if v.CodeBorder > 0 || v.CodeBackground != "" {
		// Word の罫線と文字の間は pt の整数（0〜31）
		v.CodePadding = int(math.Min(math.Round(size*codePadding), 31))
		// 線の太さは、Word が引く太さ（ruleSize で範囲に収めた 1/8 pt の値）で数える
		v.CodeIndent = twips(float64(v.CodePadding) + float64(v.CodeBorder)/8)
		v.CodeSkip += twips(float64(v.CodePadding))
	}

	for i, item := range cfg.Cover.Layout {
		if item.Space != nil {
			continue
		}
		size, leading := coverSize(cfg, item)
		align := item.Align
		if align == "" {
			align = "center"
		}
		v.Covers = append(v.Covers, docxCover{
			Index:      i + 1,
			Fields:     item.Fields != nil,
			Align:      docxAlign(align),
			Size:       halfPoints(size),
			Line:       twips(leading),
			LabelRight: twips(2 * size), // 項目名と値の間（PDF の \hspace{2em}）
			Bold:       item.Bold,
		})
	}
	return v
}

// coverSize は、表紙の文字の項目（text・fields）の文字サイズと行送り（pt）を返す。
func coverSize(cfg *config.Config, item config.CoverItem) (size, leading float64) {
	size = points(cfg.Text.FontSize)
	if item.Size != "" {
		size = points(item.Size)
	}
	return size, size * baselineRatio * cfg.Text.LineSpacing
}

// docxAlign は、揃えを Word の値にする。
func docxAlign(align string) string {
	if align == "left" {
		return "left"
	}
	if align == "right" {
		return "right"
	}
	return "center"
}

// DocxStyles は、雛形の styles.xml を作る。
func DocxStyles(cfg *config.Config) string {
	var out strings.Builder
	if err := docxStylesTemplate.Execute(&out, docxLayout(cfg)); err != nil {
		panic(err) // テンプレートの誤りは実装の誤り
	}
	return out.String()
}

// docxSection は、用紙と余白の sectPr の中身（ページ番号のフッターは含めない）。
func docxSection(page docxPage) string {
	return fmt.Sprintf(`<w:pgSz w:w="%d" w:h="%d"/>`+
		`<w:pgMar w:top="%d" w:right="%d" w:bottom="%d" w:left="%d" w:header="%d" w:footer="%d" w:gutter="0"/>`,
		page.Width, page.Height, page.Top, page.Right, page.Bottom, page.Left, page.Top/2, page.Footer)
}

// DocxJSON は、filter.lua に渡す Word の寸法（表紙の空きの計算と、表紙のあとの区切りに使う）。
func DocxJSON(cfg *config.Config) ([]byte, error) {
	v := docxLayout(cfg)
	textHeight := float64(v.Page.Height-v.Page.Top-v.Page.Bottom) / 20
	// 表紙のあとは、セクションを区切る。表紙のセクションにはフッター（ページ番号）を付けない
	section := `<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/>` +
		`<w:sectPr>` + docxSection(v.Page) + `</w:sectPr></w:pPr></w:p>`
	// 表紙の項目ごとの高さ（pt）。空きは長さ（"fill" は 0）、文字と fields は1行の行送り
	heights := []float64{}
	for _, item := range cfg.Cover.Layout {
		switch {
		case item.Space == nil:
			_, leading := coverSize(cfg, item)
			heights = append(heights, leading)
		case *item.Space == "fill":
			heights = append(heights, 0)
		default:
			heights = append(heights, lengthPoints(*item.Space))
		}
	}
	return json.Marshal(map[string]any{
		"text_height":   textHeight,
		"cover_heights": heights,
		"cover_section": section,
	})
}

// writeDocxFiles は、Word の出力に使う雛形（reference.docx）と、filter.lua に渡す寸法（docx.json）を
// dir に書き出し、そのパスを paths に加える。
func writeDocxFiles(dir string, cfg *config.Config, paths map[string]string) error {
	reference, err := ReferenceDocx(cfg)
	if err != nil {
		return err
	}
	sizes, err := DocxJSON(cfg)
	if err != nil {
		return err
	}
	for name, data := range map[string][]byte{referenceDocxName: reference, docxFileName: sizes} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return &Error{Message: fmt.Sprintf("一時ファイルを書き込めません（%v）", err)}
		}
		paths[name] = path
	}
	return nil
}

const docxFooter = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
	`<w:p><w:pPr><w:pStyle w:val="Footer"/></w:pPr>` +
	`<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>` +
	`<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>`

const (
	footerRelID   = "rIdReportmdFooter"
	footerRel     = `<Relationship Id="` + footerRelID + `" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>`
	footerContent = `<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>`
)

// ReferenceDocx は、Pandoc の標準の雛形をもとに、設定を反映した雛形を作る。
// スタイル（styles.xml）と、用紙・余白・ページ番号（document.xml の sectPr）を置き換える。
func ReferenceDocx(cfg *config.Config) ([]byte, error) {
	base, err := exec.Command("pandoc", "--print-default-data-file", "reference.docx").Output()
	if err != nil {
		return nil, &Error{Message: fmt.Sprintf("Pandoc の標準の Word の雛形を読めません（%v）", err)}
	}
	v := docxLayout(cfg)
	section := docxSection(v.Page) + `<w:pgNumType w:start="1"/>`
	var extra map[string][]byte
	if cfg.Page.Numbering {
		section = `<w:footerReference w:type="default" r:id="` + footerRelID + `"/>` + section
		extra = map[string][]byte{"word/footer1.xml": []byte(docxFooter)}
	}
	document := `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
		`<w:body><w:p/><w:sectPr>` + section + `</w:sectPr></w:body></w:document>`

	reference, err := rewriteZip(base, func(name string, data []byte) []byte {
		switch name {
		case "word/styles.xml":
			return []byte(DocxStyles(cfg))
		case "word/document.xml":
			return []byte(document)
		case "word/_rels/document.xml.rels":
			if cfg.Page.Numbering {
				return bytes.Replace(data, []byte("</Relationships>"), []byte(footerRel+"</Relationships>"), 1)
			}
		case "[Content_Types].xml":
			if cfg.Page.Numbering {
				return bytes.Replace(data, []byte("</Types>"), []byte(footerContent+"</Types>"), 1)
			}
		}
		return data
	}, extra)
	if err != nil {
		return nil, &Error{Message: fmt.Sprintf("Word の雛形を作れません（%v）", err)}
	}
	return reference, nil
}

// rewriteZip は、ZIP の各ファイルを edit で書き換え、extra のファイルを足した ZIP を返す。
func rewriteZip(data []byte, edit func(name string, data []byte) []byte, extra map[string][]byte) ([]byte, error) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	w := zip.NewWriter(&out)
	write := func(name string, content []byte) error {
		f, err := w.Create(name)
		if err != nil {
			return err
		}
		_, err = f.Write(content)
		return err
	}
	for _, f := range r.File {
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		content, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, err
		}
		if err := write(f.Name, edit(f.Name, content)); err != nil {
			return nil, err
		}
	}
	for name, content := range extra {
		if err := write(name, content); err != nil {
			return nil, err
		}
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// Pandoc の出力の表は、生成後に2か所を直す。
//   - 表の配置：Pandoc は表ごとに左寄せ（<w:jc w:val="start"/>）を書くので、取り除いて、
//     スタイルの配置（table.position）を使う。
//   - 罫線のない表（数式の番号と、表紙の項目名と値の表）：Pandoc は表のスタイルを1つ（Table）しか
//     使えないので、最初のセルの段落のスタイル（filter.lua があてたもの）を見て差し替える。
var (
	tableProps = regexp.MustCompile(`(?s)<w:tbl>\s*<w:tblPr>.*?</w:tblPr>`)
	tableAlign = regexp.MustCompile(`<w:jc w:val="[^"]*"\s*/>`)
	paraStyle  = regexp.MustCompile(`<w:pStyle w:val="([^"]*)"\s*/>`)
)

// firstParaStyle は、表の最初の段落のスタイルを返す。空のセルの段落（Pandoc が Compact にする）は飛ばす。
func firstParaStyle(s string) string {
	for {
		m := paraStyle.FindStringSubmatchIndex(s)
		if m == nil {
			return ""
		}
		if style := s[m[2]:m[3]]; style != "Compact" {
			return style
		}
		s = s[m[1]:]
	}
}

// plainTableStyle は、最初のセルの段落のスタイルから、罫線のない表のスタイルを決める（なければ空）。
// 数式の表は、最初のセル（空き）に段落のスタイルがないので、数式のセルのスタイルを見る。
func plainTableStyle(paraStyle string) string {
	switch {
	case paraStyle == "reportmdEquation":
		return "reportmdEquationTable"
	case strings.HasPrefix(paraStyle, "reportmdCover") && strings.HasSuffix(paraStyle, "Label"):
		return "reportmdCoverTable" + strings.TrimSuffix(strings.TrimPrefix(paraStyle, "reportmdCover"), "Label")
	}
	return ""
}

// fixDocx は、Pandoc が出力した Word の文書の表と、行内の数式・画像を含む段落の行送りを直す。
func fixDocx(path string, cfg *config.Config) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := styleLines(DocxStyles(cfg))
	out, err := rewriteZip(data, func(name string, content []byte) []byte {
		switch name {
		case "word/document.xml":
			return []byte(fixLineRules(fixTables(string(content)), lines))
		case "word/footnotes.xml":
			return []byte(fixLineRules(string(content), lines))
		}
		return content
	}, nil)
	if err != nil {
		return err
	}
	return os.WriteFile(path, out, 0o644)
}

func fixTables(doc string) string {
	var b strings.Builder
	last := 0
	for _, loc := range tableProps.FindAllStringIndex(doc, -1) {
		props := tableAlign.ReplaceAllString(doc[loc[0]:loc[1]], "")
		// 表の終わりか、入れ子の表の始まりの手前まで（表の最初のセルの段落）を見る
		end := len(doc)
		for _, tag := range []string{"</w:tbl>", "<w:tbl>"} {
			if next := strings.Index(doc[loc[1]:], tag); next >= 0 && loc[1]+next < end {
				end = loc[1] + next
			}
		}
		if style := plainTableStyle(firstParaStyle(doc[loc[1]:end])); style != "" {
			props = strings.Replace(props, `<w:tblStyle w:val="Table"`, `<w:tblStyle w:val="`+style+`"`, 1)
		}
		b.WriteString(doc[last:loc[0]])
		b.WriteString(props)
		last = loc[1]
	}
	b.WriteString(doc[last:])
	return b.String()
}

// 段落の行送りは、本文・表・見出しなどを PDF と同じ固定値（exact）にしている。
// 固定値の行に、行より背の高い分数や画像を置くと、Word ははみ出した部分を描かない。
// そこで、行内の数式・画像を含む段落だけ、同じ値の最小値（atLeast）にして、行を広げる
// （PDF でも、LaTeX がその行を広げる）。

// lineSpacing は、段落の行送り（twips の値と、exact などの種類）。
type lineSpacing struct {
	Line string `xml:"line,attr"`
	Rule string `xml:"lineRule,attr"`
}

// styleLines は、雛形の styles.xml から、段落のスタイルごとの行送りを求める。
// スタイルにない値は、元のスタイル（basedOn）・既定の書式（docDefaults）からたどる。
// 標準のスタイル（Normal）は、キー "" にも入れる（スタイルのない段落・ないスタイル用）。
func styleLines(styles string) map[string]lineSpacing {
	var sheet struct {
		Default *lineSpacing `xml:"docDefaults>pPrDefault>pPr>spacing"`
		Styles  []struct {
			Type    string `xml:"type,attr"`
			ID      string `xml:"styleId,attr"`
			Default string `xml:"default,attr"`
			BasedOn *struct {
				Val string `xml:"val,attr"`
			} `xml:"basedOn"`
			Spacing *lineSpacing `xml:"pPr>spacing"`
		} `xml:"style"`
	}
	if err := xml.Unmarshal([]byte(styles), &sheet); err != nil {
		panic(err) // テンプレートの誤りは実装の誤り
	}
	own := map[string]lineSpacing{}
	parent := map[string]string{}
	normal := ""
	for _, s := range sheet.Styles {
		if s.Type != "paragraph" {
			continue
		}
		if s.Spacing != nil {
			own[s.ID] = *s.Spacing
		}
		if s.BasedOn != nil {
			parent[s.ID] = s.BasedOn.Val
		}
		if s.Default == "1" {
			normal = s.ID
		}
	}
	var base lineSpacing
	if sheet.Default != nil {
		base = *sheet.Default
	}
	resolve := func(id string) lineSpacing {
		var v lineSpacing
		for seen := map[string]bool{}; id != "" && !seen[id]; id = parent[id] {
			seen[id] = true
			if v.Line == "" {
				v.Line = own[id].Line
			}
			if v.Rule == "" {
				v.Rule = own[id].Rule
			}
		}
		if v.Line == "" {
			v.Line = base.Line
		}
		if v.Rule == "" {
			v.Rule = base.Rule
		}
		return v
	}
	lines := map[string]lineSpacing{"": resolve(normal)}
	for _, s := range sheet.Styles {
		if s.Type == "paragraph" {
			lines[s.ID] = resolve(s.ID)
		}
	}
	return lines
}

var (
	paragraphXML = regexp.MustCompile(`(?s)<w:p>.*?</w:p>`)
	// 段落のプロパティのうち、spacing より後ろに置くもの（OOXML の要素の順）
	afterSpacing = regexp.MustCompile(`<w:(?:ind|contextualSpacing|mirrorIndents|suppressOverlap|jc|textDirection|textAlignment|textboxTightWrap|outlineLvl|divId|cnfStyle|rPr|sectPr|pPrChange)[ />]`)
)

// fixLineRules は、行内の数式・画像を含み、行送りが固定値の段落を、同じ値の最小値にする。
// 独立した数式・図の段落は、スタイルの行送りが固定値でないので、変えない。
func fixLineRules(doc string, lines map[string]lineSpacing) string {
	return paragraphXML.ReplaceAllStringFunc(doc, func(p string) string {
		if !strings.Contains(p, "<m:oMath") && !strings.Contains(p, "<w:drawing") {
			return p
		}
		start := strings.Index(p, "<w:pPr>")
		end := strings.Index(p, "</w:pPr>")
		if start >= 0 && end > start && strings.Contains(p[start:end], "<w:spacing") {
			return p // 段落に直接書いた行送りはそのまま
		}
		style := ""
		if start >= 0 && end > start {
			if m := paraStyle.FindStringSubmatch(p[start:end]); m != nil {
				style = m[1]
			}
		}
		line, ok := lines[style]
		if !ok {
			line = lines[""]
		}
		if line.Rule != "exact" {
			return p
		}
		spacing := `<w:spacing w:line="` + line.Line + `" w:lineRule="atLeast"/>`
		if start < 0 || end < start {
			return `<w:p><w:pPr>` + spacing + `</w:pPr>` + p[len("<w:p>"):]
		}
		at := end
		if loc := afterSpacing.FindStringIndex(p[start:end]); loc != nil {
			at = start + loc[0]
		}
		return p[:at] + spacing + p[at:]
	})
}
