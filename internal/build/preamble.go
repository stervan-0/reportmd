package build

import (
	_ "embed"
	"math"
	"strconv"
	"strings"
	"text/template"

	"reportmd/internal/config"
)

//go:embed preamble.tex.tmpl
var preambleSource string

var preambleTemplate = template.Must(template.New("preamble").Parse(preambleSource))

// baselineRatio は行送りの倍率。文字サイズのこの倍率を標準とする（LaTeX の標準に近い値）。
const baselineRatio = 1.2

var paperOptions = map[string]string{"a4": "a4paper", "a5": "a5paper", "b5": "b5paper", "letter": "letterpaper"}

var tablePositionEnvs = map[string]string{"center": "center", "left": "flushleft"}

type headingVars struct {
	Name, Indent, Size, Leading string
	Level                       int
}

type ruleVars struct{ Name, Width string }

type preambleVars struct {
	PaperOption                                      string
	MarginTop, MarginBottom, MarginLeft, MarginRight string
	FontMain, FontMono                               string
	FontSize, Baseline, LineSpacing, ParIndent       string
	PageNumbering                                    bool

	HeadingFont                 string
	HeadingBold                 bool
	Headings                    []headingVars
	HeadingBefore, HeadingAfter string

	TablePositionEnv             string
	TableFontSize, TableBaseline string
	TableCellPadding             string
	TableRowSpacing              string
	TableHeaderBold              bool
	HorizontalRules              []ruleVars
	RuleVertical, RuleSides      string
}

// Preamble は、設定の内容（用紙・余白・フォント・文字サイズ・行間・見出し・表）を
// LaTeX のプリアンブルにする。Pandoc の --include-in-header で渡す。
func Preamble(cfg *config.Config) string {
	fontSize := points(cfg.Text.FontSize)
	// 見出しの前後の空きは、本文1行分（行送り）を基準にする
	leading := fontSize * baselineRatio * cfg.Text.LineSpacing

	vars := preambleVars{
		PaperOption:   paperOptions[cfg.Document.Paper],
		MarginTop:     cfg.Page.Margin.Top,
		MarginBottom:  cfg.Page.Margin.Bottom,
		MarginLeft:    cfg.Page.Margin.Left,
		MarginRight:   cfg.Page.Margin.Right,
		FontMain:      cfg.Font.Main,
		FontMono:      cfg.Font.Mono,
		FontSize:      number(fontSize),
		Baseline:      number(fontSize * baselineRatio),
		LineSpacing:   number(cfg.Text.LineSpacing),
		ParIndent:     number(cfg.Text.ParagraphIndent * fontSize), // 1字 = 本文の文字サイズ
		PageNumbering: cfg.Page.Numbering,

		HeadingFont:   cfg.Heading.Font,
		HeadingBold:   cfg.Heading.Bold,
		HeadingBefore: number(leading),
		HeadingAfter:  number(leading * 0.5),
	}
	for i, name := range []string{"section", "subsection", "subsubsection"} {
		size := points(cfg.Heading.Sizes[i])
		vars.Headings = append(vars.Headings, headingVars{
			Name:    name,
			Level:   i + 1,
			Indent:  number(cfg.Heading.Indents[i] * fontSize),
			Size:    number(size),
			Leading: number(size * baselineRatio),
		})
	}

	// 表の書式。文字サイズが null なら本文と同じにする。
	// 表の中は本文の行間（line_spacing）を使わず、row_spacing だけで行の高さを決める。
	tableSize := fontSize
	if cfg.Table.FontSize != nil {
		tableSize = points(*cfg.Table.FontSize)
	}
	vars.TablePositionEnv = tablePositionEnvs[cfg.Table.Position]
	vars.TableFontSize = number(tableSize)
	vars.TableBaseline = number(tableSize * baselineRatio)
	vars.TableCellPadding = cfg.Table.CellPadding
	vars.TableRowSpacing = number(cfg.Table.RowSpacing)
	vars.TableHeaderBold = cfg.Table.Header.Bold
	for _, name := range []string{"top", "header", "bottom", "rows"} {
		vars.HorizontalRules = append(vars.HorizontalRules, ruleVars{Name: name, Width: cfg.Rule(name)})
	}
	vars.RuleVertical = cfg.Rule("vertical")
	vars.RuleSides = cfg.Rule("sides")

	var out strings.Builder
	if err := preambleTemplate.Execute(&out, vars); err != nil {
		panic(err) // テンプレートの誤りは実装の誤り
	}
	return out.String()
}

// points は "10.5pt" を 10.5 にする（検証済みの値だけを渡す）。
func points(s string) float64 {
	f, _ := strconv.ParseFloat(strings.TrimSuffix(s, "pt"), 64)
	return f
}

// number は、小数点以下3桁に丸めて、余分な 0 を付けずに表示する（12.6、10.5、14）。
func number(v float64) string {
	return strconv.FormatFloat(math.Round(v*1000)/1000, 'f', -1, 64)
}
