package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"reportmd/internal/config"
)

// testdata の preamble_*.tex と meta_*.json は、Ruby 版 reportmd が同じ設定から
// 生成したもの。Go 版でも、同じプリアンブルとメタデータになることを確かめる。
// Go 版で加えた行（コードの中の欧文と和文のアキをなくす設定、コードブロックの書式）は preamble_*.tex に、
// Go 版で加えた項目（code_*）は meta_*.json にも足してある。
var goldenCases = []string{"default", "grid", "custom", "misc"}

func loadCase(t *testing.T, name string) *config.Config {
	t.Helper()
	path := ""
	if name != "default" {
		path = filepath.Join("testdata", name+".json")
	}
	cfg, err := config.Load(path, "", "pdf")
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestPreambleMatchesRubyVersion(t *testing.T) {
	for _, name := range goldenCases {
		t.Run(name, func(t *testing.T) {
			want, err := os.ReadFile(filepath.Join("testdata", "preamble_"+name+".tex"))
			if err != nil {
				t.Fatal(err)
			}
			got := Preamble(loadCase(t, name))
			if got != string(want) {
				gotLines, wantLines := strings.Split(got, "\n"), strings.Split(string(want), "\n")
				for i := 0; i < len(gotLines) || i < len(wantLines); i++ {
					var g, w string
					if i < len(gotLines) {
						g = gotLines[i]
					}
					if i < len(wantLines) {
						w = wantLines[i]
					}
					if g != w {
						t.Errorf("%d 行目が違う\n期待: %q\n結果: %q", i+1, w, g)
						break
					}
				}
			}
		})
	}
}

func TestMetadataMatchesRubyVersion(t *testing.T) {
	for _, name := range goldenCases {
		t.Run(name, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join("testdata", "meta_"+name+".json"))
			if err != nil {
				t.Fatal(err)
			}
			var want, got any
			if err := json.Unmarshal(data, &want); err != nil {
				t.Fatal(err)
			}
			encoded, _ := json.Marshal(Metadata(loadCase(t, name), "x.rmd"))
			json.Unmarshal(encoded, &got)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("\n期待: %v\n結果: %v", want, got)
			}
		})
	}
}

func TestMetadataTitleAndAuthor(t *testing.T) {
	cfg, err := config.New(map[string]any{"document": map[string]any{"title": "題名", "author": " "}}, "")
	if err != nil {
		t.Fatal(err)
	}
	meta := Metadata(cfg, "a.rmd")
	if meta["title"] != "題名" {
		t.Errorf("title を渡す")
	}
	if _, ok := meta["author"]; ok {
		t.Errorf("空の author は渡さない")
	}
}

func TestFormatFromPath(t *testing.T) {
	cases := map[string]Format{"a.pdf": PDF, "a.PDF": PDF, "b.tex": LaTeX, "c.html": HTML, "d.docx": Docx, "e.pptx": Pptx}
	for path, want := range cases {
		if got, ok := FormatFromPath(path); !ok || got != want {
			t.Errorf("%s -> %s（期待 %s）", path, got, want)
		}
	}
	if _, ok := FormatFromPath("a.txt"); ok {
		t.Errorf("対応していない拡張子")
	}
}

func TestNumber(t *testing.T) {
	cases := map[float64]string{10.5: "10.5", 14: "14", 12.6: "12.6", 18.900000000000002: "18.9", 0: "0", 1.0 / 3: "0.333"}
	for in, want := range cases {
		if got := number(in); got != want {
			t.Errorf("number(%v) = %s（期待 %s）", in, got, want)
		}
	}
}

// コードブロックの書式。背景と枠の有無で、reportmdcode 環境の囲み方を変える。
func TestPreambleCode(t *testing.T) {
	cases := []struct {
		name   string
		code   map[string]any
		has    []string
		hasNot []string
	}{
		{"既定は背景と枠", nil,
			[]string{`\fontsize{10.5pt}{15.12pt}`, `\fboxsep=5.25pt\fboxrule=0.4pt`, `\fcolorbox{reportmdcodeborder}{reportmdcodebg}`, `{HTML}{F5F5F5}`},
			nil},
		{"背景だけ", map[string]any{"border": false, "background": "#ffeeee"},
			[]string{`\fboxrule=\z@`, `\colorbox{reportmdcodebg}`, `{HTML}{FFEEEE}`},
			[]string{"reportmdcodeborder"}},
		{"枠だけ", map[string]any{"background": false, "border": "1pt"},
			[]string{`\fboxrule=1pt`, `\fbox{\normalcolor #1}`},
			[]string{"reportmdcodebg"}},
		{"背景も枠もなし", map[string]any{"background": false, "border": false},
			[]string{`\newenvironment{reportmdcode}{\par\vskip\medskipamount\reportmdcodestyle}`},
			[]string{"MakeFramed", "reportmdcodebg", "reportmdcodeborder"}},
		{"文字サイズと行間", map[string]any{"font_size": "9pt", "line_spacing": 1.0},
			[]string{`\fontsize{9pt}{10.8pt}`, `\fboxsep=4.5pt`},
			nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			user := map[string]any{}
			if c.code != nil {
				user["code"] = c.code
			}
			cfg, err := config.New(user, "")
			if err != nil {
				t.Fatal(err)
			}
			got := Preamble(cfg)
			for _, want := range c.has {
				if !strings.Contains(got, want) {
					t.Errorf("%s がない:\n%s", want, got)
				}
			}
			for _, unwanted := range c.hasNot {
				if strings.Contains(got, unwanted) {
					t.Errorf("%s はないはず", unwanted)
				}
			}
		})
	}
}

// 見出しの下の線。線を引く見出しの書式の最後に \reportmdheadingrule{文字との間}{太さ} を置く。
func TestPreambleHeadingRules(t *testing.T) {
	if strings.Contains(Preamble(config.Default()), "reportmdheadingrule") {
		t.Errorf("既定では見出しの下に線を引かない")
	}
	cfg, err := config.New(map[string]any{"heading": map[string]any{"rules": []any{"0.8pt", "0.2mm", false}}}, "")
	if err != nil {
		t.Fatal(err)
	}
	got := Preamble(cfg)
	for _, want := range []string{
		`\newcommand{\reportmdheadingrule}[3]{#3\nobreak\vskip#1\hrule height#2\relax\prevdepth\z@}`,
		`{\reportmdheading{14pt}{16.8pt}\reportmdheadingrule{2.8pt}{0.8pt}}}`,   // 文字との間は文字サイズの 0.2 倍
		`{\reportmdheading{12pt}{14.4pt}\reportmdheadingrule{2.4pt}{0.567pt}}}`, // 0.2mm
		`{\reportmdheading{10.5pt}{12.6pt}}}`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%s がない:\n%s", want, got)
		}
	}
}
