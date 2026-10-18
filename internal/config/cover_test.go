package config

import (
	"reflect"
	"strings"
	"testing"
)

func TestDefaultCoverLayout(t *testing.T) {
	layout := Default().Cover.Layout
	if len(layout) == 0 {
		t.Fatal("表紙のレイアウトの既定値がある")
	}
	if layout[1].Text == nil || *layout[1].Text != "{title}" || layout[1].Size != "24pt" || !layout[1].Bold {
		t.Errorf("既定のレイアウトはタイトルを大きく太字で出す: %+v", layout[1])
	}
}

func TestCoverLayoutReplacesDefault(t *testing.T) {
	cfg := mustLoad(t, `{"cover": {"layout": [{"text": "{title}", "align": "left"}, {"space": "fill"}, {"fields": [["氏名", "{author}"]]}]}}`)
	layout := cfg.Cover.Layout
	if len(layout) != 3 {
		t.Fatalf("配列は既定値と統合せず、書いたものに置き換える: %+v", layout)
	}
	if *layout[0].Text != "{title}" || layout[0].Align != "left" || *layout[1].Space != "fill" ||
		!reflect.DeepEqual(layout[2].Fields, [][]string{{"氏名", "{author}"}}) {
		t.Errorf("項目を読む: %+v", layout)
	}
	if len(cfg.Warnings) != 0 {
		t.Errorf("警告しない: %v", cfg.Warnings)
	}
}

func TestCoverLayoutValidation(t *testing.T) {
	cases := map[string]struct{ item, want string }{
		"オブジェクトでない":    {`"a"`, "2 番目は、オブジェクト"},
		"種類がない":        {`{"size": "12pt"}`, "どれか1つ"},
		"種類が2つ":        {`{"text": "a", "space": "fill"}`, "どれか1つ"},
		"text が文字列でない": {`{"text": 1}`, "の text の値が不正です"},
		"閉じない {":       {`{"text": "{title"}`, "{ に対応する } がありません"},
		"対応しない }":      {`{"text": "a}b"}`, "} に対応する { がありません"},
		"空の {}":        {`{"text": "{ }"}`, "名前を書いてください"},
		"space の長さ":    {`{"space": "10"}`, "の space の値が不正です"},
		"fields の形":    {`{"fields": [["氏名"]]}`, "の fields の値が不正です"},
		"空の fields":    {`{"fields": []}`, "の fields の値が不正です"},
		"fields の中の {": {`{"fields": [["氏名", "{author"]]}`, "{ に対応する } がありません"},
		"align":        {`{"text": "a", "align": "top"}`, "の align の値が不正です"},
		"size の範囲":     {`{"text": "a", "size": "80pt"}`, "の size の値が不正です"},
		"bold":         {`{"text": "a", "bold": "yes"}`, "の bold の値が不正です"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := load(t, `{"cover": {"layout": [{"space": "fill"}, `+c.item+`]}}`)
			e := configError(t, err)
			if !strings.HasPrefix(e.Message, "設定 cover.layout の 2 番目") || !strings.Contains(e.Message, c.want) {
				t.Errorf("何番目の項目かと、誤りを示す: %s", e.Message)
			}
		})
	}
}

func TestCoverLayoutWarnings(t *testing.T) {
	cfg := mustLoad(t, `{"cover": {"layout": [{"text": "a", "colour": "red"}, {"space": "fill", "size": "12pt"}]}}`)
	want := []string{
		"未知の設定キーを無視します: cover.layout の 1 番目の colour",
		"cover.layout の 2 番目の size は、space の項目では使いません",
	}
	if !reflect.DeepEqual(cfg.Warnings, want) {
		t.Errorf("未知のキーと、使わないキーは警告する: %v", cfg.Warnings)
	}
}

func TestParseTemplate(t *testing.T) {
	cases := map[string][]TemplatePart{
		"":                 {},
		"文字だけ":             {{Text: "文字だけ"}},
		"{title}":          {{Var: "title"}},
		"学籍番号 {学籍番号} 号":    {{Text: "学籍番号 "}, {Var: "学籍番号"}, {Text: " 号"}},
		"{ 科目 }{担当}":       {{Var: "科目"}, {Var: "担当"}},
		"{{文字}} と {{{a}}}": {{Text: "{文字} と {"}, {Var: "a"}, {Text: "}"}},
	}
	for in, want := range cases {
		got, err := ParseTemplate(in)
		if err != nil {
			t.Errorf("%q: 予期しないエラー: %v", in, err)
			continue
		}
		if len(got) == 0 && len(want) == 0 {
			continue
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%q -> %+v（期待 %+v）", in, got, want)
		}
	}
}
