// Package build は、入力ファイルを読み、前処理 → Pandoc（filter.lua）→ XeLaTeX の順に実行して
// PDF（または LaTeX・HTML・Word の文書）を作る。
package build

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"reportmd/internal/config"
	"reportmd/internal/preprocess"
)

//go:embed filter.lua
var filterLua []byte

// Error は PDF 生成の途中で起きたエラー（外部ツールがない、PDF 生成に失敗した、など）。
// File にはエラーの原因のファイル（フォントなら設定ファイル）が入る。
// 空なら、入力ファイルの問題として表示する。
type Error struct {
	File    string
	Line    int // 入力ファイルの行番号（推定。わからなければ 0）
	Message string
}

func (e *Error) Error() string { return e.Message }

// Format は出力形式。
type Format string

const (
	PDF   Format = "pdf"
	LaTeX Format = "latex"
	HTML  Format = "html"
	Docx  Format = "docx"
)

// FormatFromPath は、出力ファイルの拡張子から形式を決める。
func FormatFromPath(path string) (Format, bool) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".pdf":
		return PDF, true
	case ".tex":
		return LaTeX, true
	case ".html", ".htm":
		return HTML, true
	case ".docx":
		return Docx, true
	}
	return "", false
}

// Options は1回の生成の指定。
type Options struct {
	Input    string // 入力ファイル（指定されたとおりのパス。警告の表示に使う）
	Output   string // 出力ファイル
	Format   Format // 空なら PDF
	Config   *config.Config
	KeepTemp bool
	// WorkDir は作業ディレクトリ。指定すると、そのまま残し、次の生成で LaTeX の補助ファイル
	// （.aux など）を使い回す。しおり・相互参照が前回と同じなら、XeLaTeX が1回で済む（watch 用）。
	// 空なら、一時ディレクトリを作り、終わったら消す。
	WorkDir string
	// Source は、入力ファイルの代わりに使う文書の内容（エディタの保存されていない内容など）。
	// nil なら入力ファイルを読む。画像などの相対パスと、エラーの表示には Input を使う。
	Source []byte
}

// Result は生成の結果。
type Result struct {
	Output   string
	Warnings []preprocess.Warning
	// ToolOutput は Pandoc の標準エラー出力（filter.lua の警告を含む）。
	ToolOutput string
	// TempDir は、--keep-temp で残した一時ディレクトリ。
	TempDir string
	// LaTeXRuns は、XeLaTeX を実行した回数（PDF のとき）。
	LaTeXRuns int
}

// pandocReader は、生 HTML・生 TeX を解釈しない Markdown（仕様 5.1）。
const pandocReader = "markdown-raw_html-raw_tex"

// pandocErrorLines は、失敗時に表示する Pandoc の出力の行数。
const pandocErrorLines = 25

// Run は文書を生成する。
func Run(opts Options) (*Result, error) {
	if opts.Format == "" {
		opts.Format = PDF
	}
	source := opts.Source
	if source == nil {
		var err error
		if source, err = os.ReadFile(opts.Input); err != nil {
			return nil, &Error{File: opts.Input, Message: "入力ファイルを読み込めません"}
		}
	}
	// 構文のエラーは外部ツールがなくても見つけられるので、先に前処理を行う
	pre, err := preprocess.Run(string(source))
	if err != nil {
		return nil, err
	}

	if err := CheckTools(opts.Format == PDF); err != nil {
		return nil, err
	}
	outDir := filepath.Dir(opts.Output)
	if st, err := os.Stat(outDir); err != nil || !st.IsDir() {
		return nil, &Error{Message: "出力先のディレクトリがありません: " + outDir}
	}
	if opts.Format == PDF {
		if err := CheckFonts(opts.Config); err != nil {
			return nil, err
		}
	}

	result := &Result{Output: opts.Output, Warnings: pre.Warnings}
	dir := opts.WorkDir
	if dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, &Error{Message: fmt.Sprintf("作業ディレクトリを作れません（%v）", err)}
		}
		if opts.KeepTemp {
			result.TempDir = dir
		}
	} else {
		dir, err = os.MkdirTemp("", "reportmd-")
		if err != nil {
			return nil, &Error{Message: fmt.Sprintf("一時ディレクトリを作れません（%v）", err)}
		}
		if opts.KeepTemp {
			result.TempDir = dir
		} else {
			defer os.RemoveAll(dir)
		}
	}

	output, err := filepath.Abs(opts.Output)
	if err != nil {
		return nil, err
	}
	if opts.Format != PDF {
		result.ToolOutput, err = runPandoc(dir, pre.Text, output, opts.Format, opts, string(source))
		return result, err
	}

	// PDF は、Pandoc で LaTeX にしてから、XeLaTeX を必要な回数だけ実行する（Pandoc に PDF まで任せると、
	// 毎回2回実行するため）。作業ディレクトリを使い回す場合は、前回の補助ファイルで1回で済むことが多い
	tex := filepath.Join(dir, texName+".tex")
	result.ToolOutput, err = runPandoc(dir, pre.Text, tex, LaTeX, opts, string(source))
	if err != nil {
		return result, err
	}
	result.LaTeXRuns, err = runLaTeX(dir, opts.Input, output, string(source), opts.WorkDir != "")
	return result, err
}

// CheckTools は、Pandoc（PDF なら XeLaTeX も）が使えるか確認する。
func CheckTools(needLaTeX bool) error {
	tools := [][2]string{{"pandoc", "Pandoc"}}
	if needLaTeX {
		tools = append(tools, [2]string{"xelatex", "XeLaTeX"})
	}
	for _, tool := range tools {
		if _, err := exec.LookPath(tool[0]); err != nil {
			return &Error{Message: fmt.Sprintf("%s（%s）が見つかりません。インストールされているか確認してください", tool[1], tool[0])}
		}
	}
	return nil
}

// FontSettings は、フォントを指定する設定の項目名と値。
func FontSettings(cfg *config.Config) [][2]string {
	return [][2]string{
		{"font.main", cfg.Font.Main},
		{"font.mono", cfg.Font.Mono},
		{"heading.font", cfg.Heading.Font},
	}
}

// CheckFonts は、設定されたフォントがインストールされているか確認する。
// fc-list が使えない環境では、確認を飛ばす（XeLaTeX がエラーを出す）。
func CheckFonts(cfg *config.Config) error {
	families, ok := InstalledFonts()
	if !ok {
		return nil
	}
	for _, item := range FontSettings(cfg) {
		if families[strings.ToLower(item[1])] {
			continue
		}
		return &Error{
			File: cfg.SourceName(),
			Message: fmt.Sprintf("フォント「%s」が見つかりません（設定: %s）。`reportmd fonts` で使えるフォント名を確認してください",
				item[1], item[0]),
		}
	}
	return nil
}

// InstalledFonts は、fc-list で調べたフォントのファミリー名（小文字）の集合を返す。
func InstalledFonts() (map[string]bool, bool) {
	out, err := exec.Command("fc-list", ":", "family").Output()
	if err != nil {
		return nil, false
	}
	families := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		for _, name := range strings.Split(line, ",") {
			if name = strings.TrimSpace(name); name != "" {
				families[strings.ToLower(name)] = true
			}
		}
	}
	return families, true
}

// Metadata は、Pandoc に渡す文書のメタデータ。title と author は、空の項目を渡さない
// （本文中の YAML フロントマターの値が、これより優先される）。
// reportmd は、filter.lua が図表のキャプションなどの組版に使う設定。
func Metadata(cfg *config.Config, source string) map[string]any {
	meta := map[string]any{}
	if strings.TrimSpace(cfg.Document.Title) != "" {
		meta["title"] = cfg.Document.Title
	}
	if strings.TrimSpace(cfg.Document.Author) != "" {
		meta["author"] = cfg.Document.Author
	}
	meta["reportmd"] = map[string]any{
		"figure_label":    cfg.Caption.FigureLabel,
		"table_label":     cfg.Caption.TableLabel,
		"figure_position": cfg.Caption.FigurePosition,
		"table_position":  cfg.Caption.TablePosition,
		"source":          source, // filter.lua の警告に表示するファイル名
		// 表の組み方（tabular の形）に関わる設定。線の太さなどはプリアンブルで決める
		"table_width":        cfg.Table.Width,
		"table_header_align": cfg.Table.Header.Align,
		"equation_numbering": cfg.Equation.Numbering,
		"equation_label":     cfg.Equation.Label,
	}
	return meta
}

// WorkFiles は、Pandoc に渡す作業用ファイルを dir に書き出し、そのパスを返す。
func WorkFiles(dir, markdown string, cfg *config.Config, source string) (map[string]string, error) {
	meta, err := json.Marshal(Metadata(cfg, source))
	if err != nil {
		return nil, err
	}
	files := map[string][]byte{
		"body.md":      []byte(markdown),
		"meta.json":    meta,
		"preamble.tex": []byte(Preamble(cfg)),
		"filter.lua":   filterLua,
	}
	paths := map[string]string{}
	for name, data := range files {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return nil, &Error{Message: fmt.Sprintf("一時ファイルを書き込めません（%v）", err)}
		}
		paths[name] = path
	}
	return paths, nil
}

// PandocArgs は、Pandoc の引数を作る。
// title は HTML のページの題名（文書に title がない場合に使う）。
func PandocArgs(paths map[string]string, output string, format Format, title string) []string {
	args := []string{
		paths["body.md"],
		"-f", pandocReader,
		"--lua-filter=" + paths["filter.lua"],
		"--metadata-file=" + paths["meta.json"],
		"--number-sections", // 見出しの番号（標準の見出しは filter.lua で番号なしにする）
	}
	switch format {
	case LaTeX: // PDF も、いったん LaTeX にしてから XeLaTeX にかける（latex.go）
		args = append(args,
			"-t", "latex", "-s",
			"--include-in-header="+paths["preamble.tex"],
			"-V", "indent=true") // Pandoc 標準の段落間隔・字下げなしの設定を無効にする
	case HTML:
		args = append(args, "-t", "html5", "-s", "--mathml", "--metadata=pagetitle:"+title)
	case Docx:
		args = append(args, "-t", "docx")
	}
	return append(args, "-o", output)
}

// source は元の .rmd の内容（LaTeX のエラーの位置を推定するために使う）。
func runPandoc(dir, markdown, output string, format Format, opts Options, source string) (string, error) {
	paths, err := WorkFiles(dir, markdown, opts.Config, opts.Input)
	if err != nil {
		return "", err
	}
	title := opts.Config.Document.Title
	if strings.TrimSpace(title) == "" {
		base := filepath.Base(opts.Input)
		title = strings.TrimSuffix(base, filepath.Ext(base))
	}
	cmd := exec.Command("pandoc", PandocArgs(paths, output, format, title)...)
	// 画像などの相対パスは、入力ファイルのある場所を基準にする
	cmd.Dir = filepath.Dir(opts.Input)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err = cmd.Run()
	text := strings.TrimSpace(stderr.String())
	if err == nil {
		return text, nil
	}

	var exitErr *exec.ExitError
	code := -1
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	}
	return "", toolError("pandoc", code, text, source)
}

// toolError は、Pandoc・XeLaTeX が失敗したときのエラーを作る。
// LaTeX のよくあるエラーには説明を付け、エラーの箇所の文字から入力ファイルの行番号を推定する。
func toolError(tool string, code int, text, source string) error {
	var lines []string
	for _, line := range strings.Split(text, "\n") {
		if line = strings.TrimRight(line, " \t\r"); line != "" {
			lines = append(lines, "  "+line)
		}
	}
	if len(lines) > pandocErrorLines {
		lines = lines[len(lines)-pandocErrorLines:]
	}
	message := fmt.Sprintf("文書の生成に失敗しました（%s の終了コード: %d）", tool, code)
	hint, line := explainLaTeXError(text, strings.ReplaceAll(source, "\r\n", "\n"))
	if hint != "" {
		message += "\n  原因の候補: " + hint
	}
	if line > 0 {
		message += "\n  （行番号は、エラーの箇所の文字から推定したものです）"
	}
	return &Error{Line: line, Message: message + "\n" + strings.Join(lines, "\n")}
}
