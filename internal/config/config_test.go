package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func load(t *testing.T, json string) (*Config, error) {
	t.Helper()
	dir := t.TempDir()
	path := writeFile(t, dir, "s.json", json)
	return Load(path, "")
}

func mustLoad(t *testing.T, json string) *Config {
	t.Helper()
	cfg, err := load(t, json)
	if err != nil {
		t.Fatalf("予期しないエラー: %v", err)
	}
	return cfg
}

func configError(t *testing.T, err error) *Error {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("config.Error が返るはず: %v", err)
	}
	return e
}

func TestDefault(t *testing.T) {
	cfg := Default()
	if cfg.Document.Paper != "a4" || cfg.Text.FontSize != "10.5pt" || cfg.Font.Main != "IPAexMincho" {
		t.Errorf("既定値が違う: %+v", cfg)
	}
	// 表の既定は三線表（上下 0.8pt、見出しの下が太い 1.2pt、縦線なし）
	if cfg.Rule("top") != "0.8pt" || cfg.Rule("header") != "1.2pt" || cfg.Rule("bottom") != "0.8pt" {
		t.Errorf("横線の既定値が違う")
	}
	if cfg.Rule("rows") != "" || cfg.Rule("vertical") != "" || cfg.Rule("sides") != "" {
		t.Errorf("縦線・行の間の線は、既定では引かない")
	}
	if !cfg.Equation.Numbering || cfg.Equation.Label != "式" {
		t.Errorf("数式は既定で番号を付け、ラベルは「式」")
	}
	if cfg.Table.FontSize != nil {
		t.Errorf("表の文字サイズの既定は null")
	}
}

func TestMergeKeepsNestedDefaults(t *testing.T) {
	cfg := mustLoad(t, `{"page": {"margin": {"top": "30mm"}}, "table": {"rules": {"rows": "0.4pt"}}}`)
	if cfg.Page.Margin.Top != "30mm" || cfg.Page.Margin.Left != "25mm" {
		t.Errorf("書いた項目だけを変える: %+v", cfg.Page.Margin)
	}
	if !cfg.Page.Numbering {
		t.Errorf("書いていない項目は既定のまま")
	}
	if cfg.Rule("rows") != "0.4pt" || cfg.Rule("top") != "0.8pt" {
		t.Errorf("罫線は書いたものだけ変わる")
	}
}

func TestTableFontSize(t *testing.T) {
	cfg := mustLoad(t, `{"table": {"font_size": "9pt"}}`)
	if cfg.Table.FontSize == nil || *cfg.Table.FontSize != "9pt" {
		t.Errorf("pt 単位を受け付ける")
	}
	cfg = mustLoad(t, `{"table": {"font_size": null}}`)
	if cfg.Table.FontSize != nil {
		t.Errorf("null を受け付ける")
	}
}

func TestFindUserFile(t *testing.T) {
	dir := t.TempDir()
	input := writeFile(t, dir, "report.reportmd", "本文\n")
	writeFile(t, dir, "setting.json", `{"text": {"font_size": "12pt"}}`)
	other := writeFile(t, dir, "other.json", `{"text": {"font_size": "11pt"}}`)

	cfg, err := Load("", input)
	if err != nil || cfg.Text.FontSize != "12pt" {
		t.Errorf("入力ファイルと同じ場所の setting.json を使う: %v", err)
	}
	cfg, err = Load(other, input)
	if err != nil || cfg.Text.FontSize != "11pt" {
		t.Errorf("-c で指定したファイルを優先する: %v", err)
	}
	_, err = Load(filepath.Join(dir, "none.json"), input)
	if e := configError(t, err); !strings.Contains(e.Message, "見つかりません") || !strings.HasSuffix(e.File, "none.json") {
		t.Errorf("指定された設定ファイルがなければエラー: %+v", e)
	}
	cfg, err = Load("", filepath.Join(t.TempDir(), "x.rmd"))
	if err != nil || cfg.Source != "" {
		t.Errorf("setting.json がなければ既定値")
	}
}

func TestObjectExpected(t *testing.T) {
	_, err := load(t, `{"page": "a4"}`)
	if e := configError(t, err); !strings.Contains(e.Message, "page") {
		t.Errorf("オブジェクトであるべき項目が違う型ならエラー: %v", e)
	}
	_, err = load(t, `[1, 2]`)
	if e := configError(t, err); !strings.Contains(e.Message, "最上位") {
		t.Errorf("最上位がオブジェクトでなければエラー: %v", e)
	}
}

func TestValidation(t *testing.T) {
	cases := map[string]string{
		"document.paper":          `{"document": {"paper": "a3"}}`,
		"page.margin.top":         `{"page": {"margin": {"top": "25"}}}`,
		"page.numbering":          `{"page": {"numbering": "yes"}}`,
		"text.font_size":          `{"text": {"font_size": "30pt"}}`,
		"text.line_spacing":       `{"text": {"line_spacing": 0.5}}`,
		"text.paragraph_indent":   `{"text": {"paragraph_indent": 6}}`,
		"font.main":               `{"font": {"main": "a\\b"}}`,
		"font.mono":               `{"font": {"mono": ""}}`,
		"heading.sizes":           `{"heading": {"sizes": ["14pt", "12pt"]}}`,
		"heading.indents":         `{"heading": {"indents": [0, 1, 9]}}`,
		"caption.figure_position": `{"caption": {"figure_position": "left"}}`,
		"table.width":             `{"table": {"width": "half"}}`,
		"table.font_size":         `{"table": {"font_size": "5pt"}}`,
		"table.header.align":      `{"table": {"header": {"align": "top"}}}`,
		"table.rules.top":         `{"table": {"rules": {"top": true}}}`,
		"equation.numbering":      `{"equation": {"numbering": 1}}`,
		"cover.layout":            `{"cover": {"layout": {"text": "a"}}}`,
	}
	for name, json := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := load(t, json)
			e := configError(t, err)
			if !strings.Contains(e.Message, "設定 "+name+" の値が不正です") {
				t.Errorf("項目名を示す: %s", e.Message)
			}
			if !strings.HasSuffix(e.File, "s.json") {
				t.Errorf("設定ファイルのパスを示す: %s", e.File)
			}
		})
	}
}

func TestJSONSyntaxErrorLine(t *testing.T) {
	cases := map[string]struct {
		json string
		line int
	}{
		"末尾のカンマ":     {"{\n  \"a\": 1,\n}\n", 3},
		"閉じ括弧がない":    {"{\n  \"a\": 1\n", 3},
		"引用符のないキー":   {"{\n  \"a\": 1,\n  b: 2\n}\n", 3},
		"カンマがない":     {"{\n  \"a\": 1\n  \"b\": 2\n}\n", 3},
		"値のあとに余計な文字": {"{}\n}\n", 2},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := load(t, c.json)
			e := configError(t, err)
			if !strings.Contains(e.Message, "JSONとして不正") || e.Line != c.line {
				t.Errorf("行番号 %d を示すはず: %+v", c.line, e)
			}
		})
	}
}

func TestBOM(t *testing.T) {
	cfg := mustLoad(t, "\xef\xbb\xbf{\"text\": {\"font_size\": \"11pt\"}}")
	if cfg.Text.FontSize != "11pt" {
		t.Errorf("BOM 付きの設定ファイルを読める")
	}
}

func TestUnknownKeys(t *testing.T) {
	cfg := mustLoad(t, `{"foo": 1, "page": {"bar": 2, "margin": {"baz": 3}}, "heading": {"bold": false}}`)
	want := []string{"未知の設定キーを無視します: foo", "未知の設定キーを無視します: page.bar", "未知の設定キーを無視します: page.margin.baz"}
	if strings.Join(cfg.Warnings, "|") != strings.Join(want, "|") {
		t.Errorf("未知のキーは警告する: %v", cfg.Warnings)
	}
}
