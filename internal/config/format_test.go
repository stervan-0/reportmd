package config

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func messages(warnings []Warning) []string {
	var list []string
	for _, w := range warnings {
		list = append(list, w.Message)
	}
	return list
}

func TestFormatFileName(t *testing.T) {
	cases := map[[2]string]string{
		{"setting.json", "docx"}:     "setting.docx.json",
		{"dir/my.json", "pdf"}:       "dir/my.pdf.json",
		{"conf", "pptx"}:             "conf.pptx.json",
		{"a.b/setting.json", "html"}: "a.b/setting.html.json",
	}
	for in, want := range cases {
		if got := FormatFileName(in[0], in[1]); got != want {
			t.Errorf("FormatFileName(%q, %q) = %q（期待 %q）", in[0], in[1], got, want)
		}
	}
}

// 形式ごとの設定ファイルは、その形式の出力だけ、共通の設定を上書きする。
func TestFormatOverride(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "a.reportmd")
	common := writeFile(t, dir, "setting.json", `{"font": {"main": "Common"}, "text": {"font_size": "11pt"}}`)
	word := writeFile(t, dir, "setting.docx.json", `{"font": {"main": "Word"}, "heading": {"sizes": ["16pt", "13pt", "11pt"]}}`)

	docx, err := Load("", input, "docx")
	if err != nil {
		t.Fatal(err)
	}
	if docx.Font.Main != "Word" || docx.Text.FontSize != "11pt" || docx.Heading.Sizes[0] != "16pt" || docx.Font.Mono != "Noto Sans Mono CJK JP" {
		t.Errorf("Word は、共通の設定に setting.docx.json を重ねる: %+v %+v %+v", docx.Font, docx.Text, docx.Heading)
	}
	if docx.SourceOf("font.main") != word || docx.SourceOf("text.font_size") != common {
		t.Errorf("項目ごとに、値を書いた設定ファイルを示す: %s %s", docx.SourceOf("font.main"), docx.SourceOf("text.font_size"))
	}

	pdf, err := Load("", input, "pdf")
	if err != nil {
		t.Fatal(err)
	}
	if pdf.Font.Main != "Common" || pdf.FormatSource != "" {
		t.Errorf("PDF は setting.docx.json を読まない: %+v", pdf.Font)
	}
}

// 共通の設定ファイルがなくても、入力ファイルと同じ場所の形式ごとの設定ファイルを読む。
// -c で指定したときは、そのファイルの名前に形式を挟んだファイルを読む。
func TestFormatFileLocation(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "setting.pdf.json", `{"page": {"numbering": false}}`)
	cfg, err := Load("", filepath.Join(dir, "a.reportmd"), "pdf")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Page.Numbering || cfg.Source != "" {
		t.Errorf("setting.json がなくても setting.pdf.json を読む: %+v", cfg.Page)
	}

	other := t.TempDir()
	explicit := writeFile(t, other, "my.json", `{}`)
	writeFile(t, other, "my.pdf.json", `{"page": {"margin": {"top": "30mm"}}}`)
	cfg, err = Load(explicit, filepath.Join(dir, "a.reportmd"), "pdf")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Page.Margin.Top != "30mm" || !cfg.Page.Numbering {
		t.Errorf("-c のときは my.pdf.json を読み、入力ファイルの場所の setting.pdf.json は読まない: %+v", cfg.Page)
	}
}

func TestFormatOverrideErrors(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "a.reportmd")
	common := writeFile(t, dir, "setting.json", `{"colour": 1}`)
	path := writeFile(t, dir, "setting.html.json", `{"text": {"font_size": "40pt"}}`)
	_, err := Load("", input, "html")
	if e := configError(t, err); e.File != path || !strings.Contains(e.Message, "text.font_size") {
		t.Errorf("上書きの誤りは、形式ごとの設定ファイルのエラーにする: %+v", e)
	}

	writeFile(t, dir, "setting.html.json", `{"text": {"size": "1pt"}, "slide": {}}`)
	cfg, err := Load("", input, "html")
	if err != nil {
		t.Fatal(err)
	}
	want := []Warning{
		{common, "未知の設定キーを無視します: colour"},
		{path, "未知の設定キーを無視します: slide（PowerPoint の設定は、setting.pptx.json に書きます）"},
		{path, "未知の設定キーを無視します: text.size"},
	}
	if !reflect.DeepEqual(cfg.Warnings, want) {
		t.Errorf("警告は、キーを書いた設定ファイルごとに示す:\n%v\nのはず:\n%v", cfg.Warnings, want)
	}
}

func TestSlideSettings(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "a.reportmd")
	def := Default().Slide
	if def.Title.Font != "IPAexGothic" || !def.Title.Bold || def.Title.Size != "36pt" || def.Title.Color != "1F3864" || def.RuleWidth() != "2pt" || def.Text.Size != "20pt" {
		t.Errorf("PowerPoint の既定値が違う: %+v", def)
	}

	path := writeFile(t, dir, "setting.pptx.json", `{"title": {"color": "#C00000", "rule": false, "underline": true}}`)
	cfg, err := Load("", input, "pptx")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Slide.Title.Color != "#C00000" || cfg.Slide.RuleWidth() != "" || cfg.Slide.Title.Size != "36pt" {
		t.Errorf("setting.pptx.json の値を既定値に重ねる: %+v", cfg.Slide)
	}
	if want := []Warning{{path, "未知の設定キーを無視します: title.underline"}}; !reflect.DeepEqual(cfg.Warnings, want) {
		t.Errorf("未知のキーは警告する: %v", cfg.Warnings)
	}
	if pdf, _ := Load("", input, "pdf"); pdf.Slide.Title.Color != "1F3864" {
		t.Errorf("PowerPoint 以外では setting.pptx.json を読まない")
	}

	cases := map[string]string{
		"title.font":  `{"title": {"font": ""}}`,
		"title.bold":  `{"title": {"bold": "yes"}}`,
		"title.size":  `{"title": {"size": "100pt"}}`,
		"title.color": `{"title": {"color": "navy"}}`,
		"title.rule":  `{"title": {"rule": true}}`,
		"text.size":   `{"text": {"size": "20"}}`,
	}
	for name, json := range cases {
		t.Run(name, func(t *testing.T) {
			path := writeFile(t, dir, "setting.pptx.json", json)
			_, err := Load("", input, "pptx")
			if e := configError(t, err); e.File != path || !strings.Contains(e.Message, "設定 "+name+" の値が不正です") {
				t.Errorf("項目名と設定ファイルを示す: %+v", e)
			}
		})
	}
}
