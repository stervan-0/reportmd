package config

import (
	"fmt"
	"sort"
	"strings"
)

// 表紙のレイアウト（cover.layout）の検証と、文字列の中の {名前} の解析。

// coverItemKeys は、表紙の項目に書けるキー。
var coverItemKeys = map[string]bool{"text": true, "space": true, "fields": true, "align": true, "size": true, "bold": true}

// coverKinds は、項目の種類を決めるキー（どれか1つだけを書く）。
var coverKinds = []string{"text", "space", "fields"}

const (
	coverSizeExpect  = `"6pt"〜"72pt"`
	coverSpaceExpect = `単位つきの長さ（例："20mm"。単位は mm cm pt in）または "fill"（残りの空きを埋める）`
)

// TemplatePart は、表紙の文字列を分けたもの。Var が空でなければ {名前} の差し込み、空なら Text の文字。
type TemplatePart struct {
	Text string `json:"text,omitempty"`
	Var  string `json:"var,omitempty"`
}

// ParseTemplate は、表紙の文字列を、文字と {名前} の差し込みに分ける。
// {{ と }} は、文字の { と } にする。
func ParseTemplate(s string) ([]TemplatePart, error) {
	var parts []TemplatePart
	var text strings.Builder
	flush := func() {
		if text.Len() > 0 {
			parts = append(parts, TemplatePart{Text: text.String()})
			text.Reset()
		}
	}
	for i := 0; i < len(s); i++ {
		switch {
		case strings.HasPrefix(s[i:], "{{"), strings.HasPrefix(s[i:], "}}"):
			text.WriteByte(s[i])
			i++
		case s[i] == '{':
			end := strings.IndexAny(s[i+1:], "{}")
			if end < 0 || s[i+1+end] != '}' {
				return nil, fmt.Errorf("{ に対応する } がありません（文字の { は {{ と書きます）")
			}
			name := strings.TrimSpace(s[i+1 : i+1+end])
			if name == "" {
				return nil, fmt.Errorf("{} の中に、差し込む項目の名前を書いてください")
			}
			flush()
			parts = append(parts, TemplatePart{Var: name})
			i += end + 1
		case s[i] == '}':
			return nil, fmt.Errorf("} に対応する { がありません（文字の } は }} と書きます）")
		default:
			text.WriteByte(s[i])
		}
	}
	flush()
	return parts, nil
}

// validateCoverLayout は、表紙のレイアウトの各項目を調べる。
// エラーは最初の1つを返し、未知のキーは警告にする。
func validateCoverLayout(items []any, source string) ([]string, error) {
	var warnings []string
	for i, value := range items {
		where := fmt.Sprintf("cover.layout の %d 番目", i+1)
		fail := func(key, expect string, v any) error {
			return &Error{File: source, Message: fmt.Sprintf("設定 %sの %s の値が不正です: %s（%s）", where, key, inspect(v), expect)}
		}
		item, ok := value.(map[string]any)
		if !ok {
			return nil, &Error{File: source, Message: fmt.Sprintf("設定 %sは、オブジェクト（{ ... }）で指定してください: %s", where, inspect(value))}
		}

		var kinds []string
		for _, kind := range coverKinds {
			if _, ok := item[kind]; ok {
				kinds = append(kinds, kind)
			}
		}
		if len(kinds) != 1 {
			return nil, &Error{File: source, Message: fmt.Sprintf("設定 %sには、text（文字）・space（空き）・fields（項目の表）のどれか1つを書いてください", where)}
		}

		var keys []string
		for key := range item {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			if !coverItemKeys[key] {
				warnings = append(warnings, fmt.Sprintf("未知の設定キーを無視します: %sの %s", where, key))
			}
		}

		switch kinds[0] {
		case "text":
			s, ok := item["text"].(string)
			if !ok {
				return nil, fail("text", "文字列。{名前} でフロントマターの値を差し込む", item["text"])
			}
			if _, err := ParseTemplate(s); err != nil {
				return nil, fail("text", err.Error(), s)
			}
		case "space":
			if v := item["space"]; !(v == "fill" || isLength(v)) {
				return nil, fail("space", coverSpaceExpect, v)
			}
			// 空きには、揃え・文字サイズ・太字は使わない
			for _, key := range []string{"align", "size", "bold"} {
				if _, ok := item[key]; ok {
					warnings = append(warnings, fmt.Sprintf("%sの %s は、space の項目では使いません", where, key))
				}
			}
		case "fields":
			if err := checkFields(item["fields"]); err != nil {
				return nil, fail("fields", err.Error(), item["fields"])
			}
		}

		if v, ok := item["align"]; ok && !oneOf("center", "left", "right")(v) {
			return nil, fail("align", `"center" "left" "right"`, v)
		}
		if v, ok := item["size"]; ok && !pointIn(6, 72)(v) {
			return nil, fail("size", coverSizeExpect, v)
		}
		if v, ok := item["bold"]; ok && !isBool(v) {
			return nil, fail("bold", "true または false", v)
		}
	}
	return warnings, nil
}

// checkFields は、fields が [項目名, 値] の組の配列か調べる。
func checkFields(v any) error {
	const expect = `["項目名", "値"] の組の配列（例：[["氏名", "{author}"]]）`
	rows, ok := v.([]any)
	if !ok || len(rows) == 0 {
		return fmt.Errorf("%s", expect)
	}
	for _, row := range rows {
		pair, ok := row.([]any)
		if !ok || len(pair) != 2 {
			return fmt.Errorf("%s", expect)
		}
		for _, cell := range pair {
			s, ok := cell.(string)
			if !ok {
				return fmt.Errorf("%s", expect)
			}
			if _, err := ParseTemplate(s); err != nil {
				return err
			}
		}
	}
	return nil
}
