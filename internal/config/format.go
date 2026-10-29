package config

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// 形式ごとの設定ファイル。共通の設定ファイル（setting.json）の名前に、形式を挟んだ名前にする
// （setting.docx.json。-c my.json なら my.docx.json）。共通の設定ファイルがなくても、
// 入力ファイルと同じ場所の setting.<形式>.json を読む。

//go:embed default.pptx.json
var defaultPptxJSON []byte

// DefaultPptxJSON は、PowerPoint の設定（setting.pptx.json）の内蔵の既定値。
func DefaultPptxJSON() []byte { return defaultPptxJSON }

// Warning は、設定ファイルの警告（File は警告の元の設定ファイル。内蔵の既定値なら空）。
type Warning struct {
	File    string
	Message string
}

// SourceName は、警告を表示するときの設定ファイルの名前。
func (w Warning) SourceName() string {
	if w.File == "" {
		return DefaultSource
	}
	return w.File
}

// Slide は、PowerPoint のスライドの題名と本文の設定（setting.pptx.json）。
type Slide struct {
	Title struct {
		Font  string `json:"font"`
		Bold  bool   `json:"bold"`
		Size  string `json:"size"`
		Color string `json:"color"` // 16進数6桁（先頭の # はあってもなくてもよい）
		Rule  any    `json:"rule"`  // false（線を引かない）または線の太さ。RuleWidth で読む
	} `json:"title"`
	Text struct {
		Size string `json:"size"`
	} `json:"text"`
}

// RuleWidth は、題名の下の線の太さを返す。線を引かないなら空文字。
func (s *Slide) RuleWidth() string {
	if w, ok := s.Title.Rule.(string); ok {
		return w
	}
	return ""
}

var slideRules = []rule{
	{"title.font", fontExpect, isFontName},
	{"title.bold", "true または false", isBool},
	{"title.size", `"10pt"〜"72pt"`, pointIn(10, 72)},
	{"title.color", `16進数6桁の色（例："1F3864"）`, isColor},
	{"title.rule", ruleExpect, orFalse(isLength)},
	{"text.size", `"8pt"〜"48pt"`, pointIn(8, 48)},
}

// NewSlide は、PowerPoint の設定（JSON のオブジェクト）を既定値と統合して検証する。
// source は表示用の設定ファイル名。未知のキーは警告にする。
func NewSlide(user map[string]any, source string) (*Slide, []Warning, error) {
	defaults, err := pptxDefaults()
	if err != nil {
		return nil, nil, err
	}
	merged, err := deepMerge(defaults, user, nil, source)
	if err != nil {
		return nil, nil, err
	}
	if err := validate(merged, slideRules, source); err != nil {
		return nil, nil, err
	}
	data, err := json.Marshal(merged)
	if err != nil {
		return nil, nil, err
	}
	slide := &Slide{}
	if err := json.Unmarshal(data, slide); err != nil {
		return nil, nil, &Error{File: source, Message: fmt.Sprintf("設定を読み込めません（%v）", err)}
	}
	var warnings []Warning
	for _, name := range unknownKeys(defaults, user, nil) {
		warnings = append(warnings, Warning{source, "未知の設定キーを無視します: " + name})
	}
	return slide, warnings, nil
}

// DefaultSlide は、内蔵の既定値だけの PowerPoint の設定を返す。
func DefaultSlide() Slide {
	slide, _, err := NewSlide(map[string]any{}, "")
	if err != nil {
		panic(err) // 内蔵の既定値が不正なのは、実装の誤り
	}
	return *slide
}

func pptxDefaults() (map[string]any, error) {
	value, err := parseJSON(defaultPptxJSON, DefaultSource)
	if err != nil {
		return nil, err
	}
	return value.(map[string]any), nil
}

// FormatFileName は、共通の設定ファイル base に対する、形式 format の設定ファイルのパスを返す。
func FormatFileName(base, format string) string {
	return strings.TrimSuffix(base, filepath.Ext(base)) + "." + format + ".json"
}

// settingBase は、形式ごとの設定ファイルの名前の元にする、共通の設定ファイルのパスを返す
// （ファイルがなくてもよい）。-c も入力ファイルもなければ空。
func settingBase(explicitPath, inputPath string) string {
	if explicitPath != "" {
		return explicitPath
	}
	if inputPath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(inputPath), SettingFileName)
}

// leafPaths は、設定のオブジェクトの末端の項目のパス（"font.main" など）を返す。
// 配列（heading.sizes・cover.layout）は、その項目を末端とする。
func leafPaths(values map[string]any, prefix string) []string {
	var paths []string
	for key, value := range values {
		path := key
		if prefix != "" {
			path = prefix + "." + key
		}
		if child, ok := value.(map[string]any); ok {
			paths = append(paths, leafPaths(child, path)...)
			continue
		}
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths
}
