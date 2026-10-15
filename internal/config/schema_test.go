package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// VS Code 拡張機能の setting.json のスキーマ（補完と検査に使う）が、
// 設定の項目（rules）と既定値（default.json）に合っていることを確かめる。
// 設定の項目を増やしたり既定値を変えたりしたら、スキーマも直す。
func TestVSCodeSchemaMatchesConfig(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "vscode", "schemas", "setting.schema.json"))
	if err != nil {
		t.Skipf("スキーマがないため飛ばす: %v", err)
	}
	var schema map[string]any
	if err := json.Unmarshal(data, &schema); err != nil {
		t.Fatalf("スキーマが JSON として不正: %v", err)
	}
	var defaults map[string]any
	if err := json.Unmarshal(DefaultJSON(), &defaults); err != nil {
		t.Fatal(err)
	}

	// スキーマの末端の項目（properties を持たないもの）を、パス → 定義の表にする
	leaves := map[string]map[string]any{}
	var walk func(prefix string, node map[string]any)
	walk = func(prefix string, node map[string]any) {
		props, ok := node["properties"].(map[string]any)
		if !ok {
			leaves[prefix] = node
			return
		}
		if node["additionalProperties"] != false {
			t.Errorf("%s: 未知のキーを知らせるため、additionalProperties を false にする", nameOr(prefix))
		}
		for key, child := range props {
			path := key
			if prefix != "" {
				path = prefix + "." + key
			}
			walk(path, child.(map[string]any))
		}
	}
	walk("", schema)

	var rulePaths []string
	for _, r := range rules {
		rulePaths = append(rulePaths, r.path)
	}
	var schemaPaths []string
	for path := range leaves {
		schemaPaths = append(schemaPaths, path)
	}
	sort.Strings(rulePaths)
	sort.Strings(schemaPaths)
	if !reflect.DeepEqual(rulePaths, schemaPaths) {
		t.Fatalf("スキーマの項目が、設定の項目と違う\n設定:     %v\nスキーマ: %v", rulePaths, schemaPaths)
	}

	for _, r := range rules {
		leaf := leaves[r.path]
		def, ok := leaf["default"]
		if !ok {
			t.Errorf("%s: スキーマに default がない", r.path)
			continue
		}
		if want := dig(defaults, r.path); !reflect.DeepEqual(def, want) {
			t.Errorf("%s: スキーマの default %v が、default.json の %v と違う", r.path, def, want)
		}
		if desc, _ := leaf["description"].(string); strings.TrimSpace(desc) == "" {
			t.Errorf("%s: スキーマに description がない", r.path)
		}
		// 列挙の項目は、スキーマの候補がどれも設定の検査を通る
		if values, ok := leaf["enum"].([]any); ok {
			for _, v := range values {
				if !r.check(v) {
					t.Errorf("%s: スキーマの候補 %v が、設定の検査を通らない", r.path, v)
				}
			}
		}
	}
}

func nameOr(path string) string {
	if path == "" {
		return "（最上位）"
	}
	return path
}
