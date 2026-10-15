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
var goldenCases = []string{"default", "grid", "custom", "misc"}

func loadCase(t *testing.T, name string) *config.Config {
	t.Helper()
	path := ""
	if name != "default" {
		path = filepath.Join("testdata", name+".json")
	}
	cfg, err := config.Load(path, "")
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
	cases := map[string]Format{"a.pdf": PDF, "a.PDF": PDF, "b.tex": LaTeX, "c.html": HTML, "d.docx": Docx}
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
