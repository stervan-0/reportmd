// Package config は、設定ファイル（JSON）を読み込み、内蔵の既定値と統合して検証する。
//
// 探索順:
//  1. 明示的に指定されたファイル（-c / --config）
//  2. 入力ファイルと同じディレクトリの setting.json
//  3. 内蔵の既定値（default.json）だけを使う
package config

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

//go:embed default.json
var defaultJSON []byte

// DefaultJSON は内蔵の既定設定（init コマンドの雛形にも使う）。
func DefaultJSON() []byte { return defaultJSON }

// SettingFileName は、入力ファイルと同じ場所で探す設定ファイルの名前。
const SettingFileName = "setting.json"

// DefaultSource は、内蔵の既定設定を表示するときの名前。
const DefaultSource = "(内蔵の既定設定)"

// Error は設定ファイルの読み込み・検証で見つかったエラー。
type Error struct {
	File    string
	Line    int // わからなければ 0
	Message string
}

func (e *Error) Error() string { return e.Message }

// Config は、既定値と統合して検証した設定。
type Config struct {
	Document struct {
		Paper  string `json:"paper"`
		Title  string `json:"title"`
		Author string `json:"author"`
	} `json:"document"`
	Page struct {
		Margin struct {
			Top    string `json:"top"`
			Bottom string `json:"bottom"`
			Left   string `json:"left"`
			Right  string `json:"right"`
		} `json:"margin"`
		Numbering bool `json:"numbering"`
	} `json:"page"`
	Text struct {
		FontSize        string  `json:"font_size"`
		LineSpacing     float64 `json:"line_spacing"`
		ParagraphIndent float64 `json:"paragraph_indent"`
	} `json:"text"`
	Font struct {
		Main string `json:"main"`
		Mono string `json:"mono"`
	} `json:"font"`
	Heading struct {
		Font    string    `json:"font"`
		Bold    bool      `json:"bold"`
		Sizes   []string  `json:"sizes"`
		Indents []float64 `json:"indents"`
	} `json:"heading"`
	Caption struct {
		FigureLabel    string `json:"figure_label"`
		TableLabel     string `json:"table_label"`
		FigurePosition string `json:"figure_position"`
		TablePosition  string `json:"table_position"`
	} `json:"caption"`
	Table struct {
		Position    string  `json:"position"`
		Width       string  `json:"width"`
		FontSize    *string `json:"font_size"`
		RowSpacing  float64 `json:"row_spacing"`
		CellPadding string  `json:"cell_padding"`
		Header      struct {
			Bold  bool   `json:"bold"`
			Align string `json:"align"`
		} `json:"header"`
		// 各罫線は false（引かない）または線の太さの文字列。Rule で読む
		Rules map[string]any `json:"rules"`
	} `json:"table"`
	Equation struct {
		Numbering bool   `json:"numbering"`
		Label     string `json:"label"`
	} `json:"equation"`
	Cover struct {
		Layout []CoverItem `json:"layout"`
	} `json:"cover"`

	// Source は読み込んだ設定ファイルのパス（内蔵の既定値だけなら空）。
	Source string `json:"-"`
	// Warnings は、未知のキーなどの警告。
	Warnings []string `json:"-"`
}

// CoverItem は、表紙のレイアウト（cover.layout）の1項目。
// Text（1行の文字）・Space（縦の空き）・Fields（項目名と値の表）のどれか1つを持つ。
type CoverItem struct {
	Text   *string    `json:"text,omitempty"`
	Space  *string    `json:"space,omitempty"`
	Fields [][]string `json:"fields,omitempty"`
	Align  string     `json:"align,omitempty"` // 空なら center
	Size   string     `json:"size,omitempty"`  // 空なら本文と同じ
	Bold   bool       `json:"bold,omitempty"`
}

// Rule は罫線の太さを返す。線を引かないなら空文字。
func (c *Config) Rule(name string) string {
	if s, ok := c.Table.Rules[name].(string); ok {
		return s
	}
	return ""
}

// SourceName は、エラー表示に使う設定ファイルの名前。
func (c *Config) SourceName() string {
	if c.Source == "" {
		return DefaultSource
	}
	return c.Source
}

// Load は設定ファイルを探して読み込む。
// explicitPath は -c で指定されたファイル、inputPath は入力ファイル（空でもよい）。
func Load(explicitPath, inputPath string) (*Config, error) {
	path, err := FindUserFile(explicitPath, inputPath)
	if err != nil {
		return nil, err
	}
	user := map[string]any{}
	if path != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, &Error{File: path, Message: fmt.Sprintf("設定ファイルを読み込めません（%v）", err)}
		}
		value, err := parseJSON(data, path)
		if err != nil {
			return nil, err
		}
		obj, ok := value.(map[string]any)
		if !ok {
			return nil, &Error{File: path, Message: "設定ファイルの最上位は { ... } のオブジェクトにしてください"}
		}
		user = obj
	}
	return New(user, path)
}

// FindUserFile は、使う設定ファイルのパスを返す。なければ空文字。
func FindUserFile(explicitPath, inputPath string) (string, error) {
	if explicitPath != "" {
		if st, err := os.Stat(explicitPath); err != nil || st.IsDir() {
			return "", &Error{File: explicitPath, Message: "設定ファイルが見つかりません"}
		}
		return explicitPath, nil
	}
	if inputPath == "" {
		return "", nil
	}
	candidate := filepath.Join(filepath.Dir(inputPath), SettingFileName)
	if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
		return candidate, nil
	}
	return "", nil
}

// parseJSON は BOM を取り除いて JSON を読む。構文エラーは行番号つきのエラーにする。
func parseJSON(data []byte, path string) (any, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var value any
	err := dec.Decode(&value)
	if err == nil {
		// 値のあとに余計な文字があれば、構文エラーとして扱う
		var extra any
		if next := dec.Decode(&extra); next == nil {
			err = &json.SyntaxError{Offset: dec.InputOffset()}
		} else if next != io.EOF {
			err = next
		}
	}
	if err != nil {
		e := &Error{File: path, Message: "設定ファイルがJSONとして不正です"}
		var syntax *json.SyntaxError
		var typeErr *json.UnmarshalTypeError
		switch {
		case errors.As(err, &syntax):
			e.Line = lineAt(data, syntax.Offset)
		case errors.As(err, &typeErr):
			e.Line = lineAt(data, typeErr.Offset)
		case errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF):
			// 閉じないまま終わった。最後の位置（末尾）の行を示す
			e.Line = bytes.Count(data, []byte("\n")) + 1
		}
		return nil, e
	}
	return normalizeNumbers(value), nil
}

// lineAt は、バイト位置 offset のある行番号（1始まり）を返す。
// json の Offset は「崩れた文字を読んだ直後」なので、1つ戻して数える。
func lineAt(data []byte, offset int64) int {
	if offset > 0 {
		offset--
	}
	if offset > int64(len(data)) {
		offset = int64(len(data))
	}
	// 崩れた位置の直前の空白（改行）は、前の行の続きとして扱わない
	return bytes.Count(data[:offset], []byte("\n")) + 1
}

// json.Number を float64 にする（検証で数値として扱うため）。
func normalizeNumbers(value any) any {
	switch v := value.(type) {
	case map[string]any:
		for k, item := range v {
			v[k] = normalizeNumbers(item)
		}
		return v
	case []any:
		for i, item := range v {
			v[i] = normalizeNumbers(item)
		}
		return v
	case json.Number:
		f, err := v.Float64()
		if err != nil {
			return v.String()
		}
		return f
	}
	return value
}

// New は、ユーザーの設定（JSON のオブジェクト）を既定値と統合して検証する。
// source は表示用の設定ファイル名（空なら内蔵の既定値）。
func New(user map[string]any, source string) (*Config, error) {
	defaults, err := defaultValues()
	if err != nil {
		return nil, err
	}
	merged, err := deepMerge(defaults, user, nil, source)
	if err != nil {
		return nil, err
	}
	if err := validate(merged, source); err != nil {
		return nil, err
	}
	coverWarnings, err := validateCoverLayout(dig(merged, "cover.layout").([]any), source)
	if err != nil {
		return nil, err
	}

	data, err := json.Marshal(merged)
	if err != nil {
		return nil, err
	}
	cfg := &Config{}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, &Error{File: source, Message: fmt.Sprintf("設定を読み込めません（%v）", err)}
	}
	cfg.Source = source
	for _, name := range unknownKeys(defaults, user, nil) {
		cfg.Warnings = append(cfg.Warnings, "未知の設定キーを無視します: "+name)
	}
	cfg.Warnings = append(cfg.Warnings, coverWarnings...)
	return cfg, nil
}

// Default は内蔵の既定値だけの設定を返す。
func Default() *Config {
	cfg, err := New(map[string]any{}, "")
	if err != nil {
		panic(err) // 内蔵の既定値が不正なのは、実装の誤り
	}
	return cfg
}

func defaultValues() (map[string]any, error) {
	value, err := parseJSON(defaultJSON, DefaultSource)
	if err != nil {
		return nil, err
	}
	return value.(map[string]any), nil
}

// deepMerge は、既定値の項目だけを残しながら、ユーザーの値で上書きする。
func deepMerge(base, over map[string]any, prefix []string, source string) (map[string]any, error) {
	result := map[string]any{}
	for key, def := range base {
		path := append(append([]string{}, prefix...), key)
		value, given := over[key]
		if !given {
			result[key] = def
			continue
		}
		if defMap, ok := def.(map[string]any); ok {
			overMap, ok := value.(map[string]any)
			if !ok {
				return nil, &Error{File: source, Message: fmt.Sprintf("設定 %s はオブジェクト（{ ... }）で指定してください", strings.Join(path, "."))}
			}
			merged, err := deepMerge(defMap, overMap, path, source)
			if err != nil {
				return nil, err
			}
			result[key] = merged
			continue
		}
		result[key] = value
	}
	return result, nil
}

func unknownKeys(defaults, user map[string]any, prefix []string) []string {
	keys := make([]string, 0, len(user))
	for key := range user {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var names []string
	for _, key := range keys {
		path := append(append([]string{}, prefix...), key)
		def, known := defaults[key]
		if !known {
			names = append(names, strings.Join(path, "."))
			continue
		}
		defMap, ok1 := def.(map[string]any)
		userMap, ok2 := user[key].(map[string]any)
		if ok1 && ok2 {
			names = append(names, unknownKeys(defMap, userMap, path)...)
		}
	}
	return names
}

// --- 検証 -------------------------------------------------------------

var (
	lengthPattern = regexp.MustCompile(`^\d+(\.\d+)?(mm|cm|pt|in)$`)
	pointPattern  = regexp.MustCompile(`^\d+(\.\d+)?pt$`)
	// LaTeX の特殊文字を含むフォント名は受け付けない（組版コードの破損を防ぐ）
	fontNamePattern = regexp.MustCompile(`^[^{}\\%#&$^_~]+$`)
)

type check func(any) bool

func isString(v any) bool { _, ok := v.(string); return ok }

func isBool(v any) bool { _, ok := v.(bool); return ok }

func isLength(v any) bool { s, ok := v.(string); return ok && lengthPattern.MatchString(s) }

func isFontName(v any) bool {
	s, ok := v.(string)
	return ok && strings.TrimSpace(s) != "" && fontNamePattern.MatchString(s)
}

func numberIn(min, max float64) check {
	return func(v any) bool { f, ok := v.(float64); return ok && f >= min && f <= max }
}

func pointIn(min, max float64) check {
	return func(v any) bool {
		s, ok := v.(string)
		if !ok || !pointPattern.MatchString(s) {
			return false
		}
		f, _ := strconv.ParseFloat(strings.TrimSuffix(s, "pt"), 64)
		return f >= min && f <= max
	}
}

func arrayOf(count int, item check) check {
	return func(v any) bool {
		list, ok := v.([]any)
		if !ok || len(list) != count {
			return false
		}
		for _, x := range list {
			if !item(x) {
				return false
			}
		}
		return true
	}
}

func oneOf(list ...string) check {
	return func(v any) bool {
		s, ok := v.(string)
		if !ok {
			return false
		}
		for _, x := range list {
			if s == x {
				return true
			}
		}
		return false
	}
}

func orNull(c check) check  { return func(v any) bool { return v == nil || c(v) } }
func orFalse(c check) check { return func(v any) bool { return v == false || c(v) } }

type rule struct {
	path   string
	expect string
	check  check
}

const (
	fontExpect   = "空でない文字列。{ } \\ % # & $ ^ _ ~ は使えません"
	lengthExpect = "単位つきの長さ（例：\"25mm\"。単位は mm cm pt in）"
	ruleExpect   = "false（線を引かない）または線の太さ（例：\"0.5pt\"。単位は mm cm pt in）"
)

var rules = []rule{
	{"document.paper", `"a4" "a5" "b5" "letter"`, oneOf("a4", "a5", "b5", "letter")},
	{"document.title", "文字列", isString},
	{"document.author", "文字列", isString},
	{"page.margin.top", lengthExpect, isLength},
	{"page.margin.bottom", lengthExpect, isLength},
	{"page.margin.left", lengthExpect, isLength},
	{"page.margin.right", lengthExpect, isLength},
	{"page.numbering", "true または false", isBool},
	{"text.font_size", `"6pt"〜"24pt"`, pointIn(6, 24)},
	{"text.line_spacing", "1.0〜3.0 の数値", numberIn(1, 3)},
	{"text.paragraph_indent", "0〜5 の数値（単位は字）", numberIn(0, 5)},
	{"font.main", fontExpect, isFontName},
	{"font.mono", fontExpect, isFontName},
	{"heading.font", fontExpect, isFontName},
	{"heading.bold", "true または false", isBool},
	{"heading.sizes", `"6pt"〜"24pt" の文字列を3個並べた配列`, arrayOf(3, pointIn(6, 24))},
	{"heading.indents", "0〜5 の数値を3個並べた配列（単位は字）", arrayOf(3, numberIn(0, 5))},
	{"caption.figure_label", "文字列", isString},
	{"caption.table_label", "文字列", isString},
	{"caption.figure_position", `"top" または "bottom"`, oneOf("top", "bottom")},
	{"caption.table_position", `"top" または "bottom"`, oneOf("top", "bottom")},
	{"table.position", `"center" または "left"`, oneOf("center", "left")},
	{"table.width", `"auto"（内容に合わせる）または "full"（本文幅いっぱい）`, oneOf("auto", "full")},
	{"table.font_size", `null（本文と同じ）または "6pt"〜"24pt"`, orNull(pointIn(6, 24))},
	{"table.row_spacing", "1.0〜3.0 の数値", numberIn(1, 3)},
	{"table.cell_padding", lengthExpect, isLength},
	{"table.header.bold", "true または false", isBool},
	{"table.header.align", `"center" "left" "right" "column"（列の揃えに従う）`, oneOf("center", "left", "right", "column")},
	{"table.rules.top", ruleExpect, orFalse(isLength)},
	{"table.rules.header", ruleExpect, orFalse(isLength)},
	{"table.rules.bottom", ruleExpect, orFalse(isLength)},
	{"table.rules.rows", ruleExpect, orFalse(isLength)},
	{"table.rules.vertical", ruleExpect, orFalse(isLength)},
	{"table.rules.sides", ruleExpect, orFalse(isLength)},
	{"equation.numbering", "true または false", isBool},
	{"equation.label", "文字列", isString},
	// 各項目の中身は validateCoverLayout で調べる
	{"cover.layout", "表紙の項目（{ ... }）の配列", isArray},
}

func isArray(v any) bool { _, ok := v.([]any); return ok }

func dig(values map[string]any, path string) any {
	var current any = values
	for _, key := range strings.Split(path, ".") {
		m, ok := current.(map[string]any)
		if !ok {
			return nil
		}
		current = m[key]
	}
	return current
}

func validate(values map[string]any, source string) error {
	for _, r := range rules {
		value := dig(values, r.path)
		if r.check(value) {
			continue
		}
		return &Error{File: source, Message: fmt.Sprintf("設定 %s の値が不正です: %s（%s）", r.path, inspect(value), r.expect)}
	}
	return nil
}

// inspect は、値を JSON の書き方で表示する。
func inspect(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Sprint(value)
	}
	return string(data)
}
