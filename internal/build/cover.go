package build

import (
	"encoding/json"

	"reportmd/internal/config"
)

// coverFileName は、表紙のレイアウトを filter.lua に渡すファイルの名前（filter.lua と同じ場所に置く）。
// メタデータで渡すと、文字列が Markdown として読まれてしまうため、JSON のファイルで渡す。
const coverFileName = "cover.json"

// coverLine は、filter.lua に渡す表紙の1項目。文字列は、文字と {名前} の差し込みに分けておく。
type coverLine struct {
	Kind    string                     `json:"kind"` // text / space / fields
	Parts   []config.TemplatePart      `json:"parts,omitempty"`
	Space   string                     `json:"space,omitempty"` // 長さ、または fill
	Rows    [][2][]config.TemplatePart `json:"rows,omitempty"`
	Align   string                     `json:"align"`
	Size    string                     `json:"size,omitempty"`    // pt の数（空なら本文と同じ）
	Leading string                     `json:"leading,omitempty"` // 行送り（pt の数）
	Bold    bool                       `json:"bold,omitempty"`
}

// CoverJSON は、表紙のレイアウト（cover.layout）を filter.lua 用の JSON にする。
func CoverJSON(cfg *config.Config) ([]byte, error) {
	lines := []coverLine{}
	for _, item := range cfg.Cover.Layout {
		line := coverLine{Align: item.Align, Bold: item.Bold}
		if line.Align == "" {
			line.Align = "center"
		}
		if item.Size != "" {
			size := points(item.Size)
			line.Size = number(size)
			line.Leading = number(size * baselineRatio)
		}
		switch {
		case item.Text != nil:
			line.Kind = "text"
			line.Parts = mustParse(*item.Text)
		case item.Space != nil:
			line.Kind = "space"
			line.Space = *item.Space
		default:
			line.Kind = "fields"
			for _, pair := range item.Fields {
				line.Rows = append(line.Rows, [2][]config.TemplatePart{mustParse(pair[0]), mustParse(pair[1])})
			}
		}
		lines = append(lines, line)
	}
	return json.Marshal(map[string]any{"layout": lines})
}

// mustParse は、検証済みの文字列を分ける。
func mustParse(s string) []config.TemplatePart {
	parts, err := config.ParseTemplate(s)
	if err != nil {
		panic(err) // 設定の検証で調べているので、ここでは起きない
	}
	if parts == nil {
		parts = []config.TemplatePart{}
	}
	return parts
}
