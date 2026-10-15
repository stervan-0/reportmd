// Package cli は、コマンドライン引数を処理し、各コマンドを実行する。
// 終了コード: 0 = 成功（警告があっても 0）、1 = 失敗
package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"reportmd/internal/build"
	"reportmd/internal/config"
	"reportmd/internal/preprocess"
)

// Version は reportmd のバージョン。
const Version = "0.2.0"

const usage = `使い方:
  reportmd build [INPUT.rmd] [-o OUTPUT] [-c setting.json] [--keep-temp] [-w] [--open]
  reportmd INPUT.rmd [オプション]          （build を省略した書き方）
  reportmd watch [INPUT.rmd] [-o OUTPUT] [-c setting.json] [--open]
  reportmd check INPUT.rmd [-c setting.json]
  reportmd init [DIR] [--force]
  reportmd fonts [--all]
  reportmd doctor [-c setting.json]
  reportmd --version
  reportmd --help

コマンド:
  build    PDF を生成する（-o の拡張子で .tex .html .docx も出力できる）
  watch    ファイルの変更を監視し、保存のたびに生成し直す（build -w と同じ）
  check    PDF を作らずに、構文・設定・参照の誤りだけを調べる（速い）
  init     新しいレポートの雛形（report.rmd と setting.json）を作る
  fonts    設定に書けるフォント名の一覧を表示する（既定は日本語フォントのみ）
  doctor   Pandoc・XeLaTeX・フォントなど、必要なものが揃っているか調べる

INPUT.rmd を省略すると、カレントディレクトリにある .rmd（1つだけの場合）を使う。

オプション:
  -o, --output FILE   出力するファイルのパス（省略時は入力ファイルと同じ場所の PDF）
  -c, --config FILE   設定ファイルのパス
      --keep-temp     一時ファイルを残す（デバッグ用）
      --open          生成したファイルを既定のアプリ（PDF ビューアなど）で開く
  -w, --watch         生成したあと、変更を監視して生成し直す
  -v, --version       バージョンを表示
  -h, --help          このヘルプを表示
`

// CLI は、標準出力・標準エラー出力を持つ実行環境。
type CLI struct {
	Stdout io.Writer
	Stderr io.Writer
	// watchStop は、テストで監視を止めるために使う（nil なら止めない）。
	watchStop <-chan struct{}
}

// Main は os.Args を受けて終了コードを返す。
func Main(args []string) int {
	return (&CLI{Stdout: os.Stdout, Stderr: os.Stderr}).Run(args)
}

// Run はコマンドを実行し、終了コードを返す。
func (c *CLI) Run(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(c.Stderr, usage)
		return 1
	}
	command, rest := args[0], args[1:]
	switch command {
	case "-v", "--version", "version":
		fmt.Fprintf(c.Stdout, "reportmd %s\n", Version)
		return 0
	case "-h", "--help", "help":
		fmt.Fprint(c.Stdout, usage)
		return 0
	case "build":
		return c.build(rest, false)
	case "watch":
		return c.build(rest, true)
	case "check":
		return c.check(rest)
	case "init":
		return c.init(rest)
	case "fonts":
		return c.fonts(rest)
	case "doctor":
		return c.doctor(rest)
	}
	// 「reportmd report.rmd」のように、コマンドを省略して入力ファイルを書いたら build にする
	if strings.HasSuffix(strings.ToLower(command), ".rmd") {
		return c.build(args, false)
	}
	fmt.Fprintf(c.Stderr, "error: 不明なコマンドです: %s\n", command)
	fmt.Fprint(c.Stderr, usage)
	return 1
}

// --- 引数の解析 -----------------------------------------------------------

type options struct {
	output, config string
	keepTemp       bool
	open           bool
	watch          bool
	force          bool
	all            bool
	help           bool
	args           []string
}

// parseOptions は、オプションと位置引数を分ける。オプションは位置引数の前後どちらにも書ける。
// allowed は、そのコマンドで使えるオプション（長い名前）。
func parseOptions(args []string, allowed ...string) (*options, error) {
	ok := map[string]bool{"help": true}
	for _, name := range allowed {
		ok[name] = true
	}
	short := map[string]string{"o": "output", "c": "config", "w": "watch", "h": "help", "f": "force"}

	opts := &options{}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			opts.args = append(opts.args, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			opts.args = append(opts.args, arg)
			continue
		}

		name, value, hasValue := strings.TrimLeft(arg, "-"), "", false
		if strings.HasPrefix(arg, "--") {
			if k, v, found := strings.Cut(name, "="); found {
				name, value, hasValue = k, v, true
			}
		} else {
			if len(name) > 1 { // -ofile のように続けて書いた値
				name, value, hasValue = name[:1], name[1:], true
			}
			if long, found := short[name]; found {
				name = long
			} else {
				return nil, fmt.Errorf("不明なオプションです: %s", arg)
			}
		}
		if !ok[name] {
			return nil, fmt.Errorf("不明なオプションです: %s", arg)
		}

		switch name {
		case "output", "config":
			if !hasValue {
				if i+1 >= len(args) {
					return nil, fmt.Errorf("オプション %s には値が必要です", arg)
				}
				i++
				value = args[i]
			}
			if name == "output" {
				opts.output = value
			} else {
				opts.config = value
			}
		default:
			if hasValue {
				return nil, fmt.Errorf("オプション %s には値を付けられません", arg)
			}
			switch name {
			case "open":
				opts.open = true
			case "keep-temp":
				opts.keepTemp = true
			case "watch":
				opts.watch = true
			case "force":
				opts.force = true
			case "all":
				opts.all = true
			case "help":
				opts.help = true
			}
		}
	}
	return opts, nil
}

// --- 表示 -----------------------------------------------------------------

// diagnostic は、エラー・警告の表示形式（仕様 9.3）「ファイル名:行番号: 種類: メッセージ」。
// 行番号がわからなければ「ファイル名: 種類: メッセージ」にする。
func diagnostic(file string, line int, kind, message string) string {
	location := file
	if line > 0 {
		location = fmt.Sprintf("%s:%d", file, line)
	}
	if location == "" {
		return fmt.Sprintf("%s: %s", kind, message)
	}
	return fmt.Sprintf("%s: %s: %s", location, kind, message)
}

func (c *CLI) fail(message string) int {
	fmt.Fprintln(c.Stderr, message)
	return 1
}

// reportError は、エラーの種類に応じて、ファイル名と行番号つきで表示する。
func (c *CLI) reportError(input string, err error) int {
	var pre *preprocess.Error
	var cfg *config.Error
	var bld *build.Error
	switch {
	case errors.As(err, &pre):
		return c.fail(diagnostic(input, pre.Line, "error", pre.Message))
	case errors.As(err, &cfg):
		return c.fail(diagnostic(cfg.File, cfg.Line, "error", cfg.Message))
	case errors.As(err, &bld):
		file := bld.File
		if file == "" {
			file = input
		}
		return c.fail(diagnostic(file, bld.Line, "error", bld.Message))
	}
	return c.fail(diagnostic(input, 0, "error", err.Error()))
}

func (c *CLI) reportConfigWarnings(cfg *config.Config) {
	for _, message := range cfg.Warnings {
		fmt.Fprintln(c.Stderr, diagnostic(cfg.SourceName(), 0, "warning", message))
	}
}

func (c *CLI) reportWarnings(input string, warnings []preprocess.Warning) {
	for _, w := range warnings {
		fmt.Fprintln(c.Stderr, diagnostic(input, w.Line, "warning", w.Message))
	}
}

// --- 入力の確認 -----------------------------------------------------------

// singleInput は、位置引数がちょうど1つの入力ファイルであることを確認する。
// 入力ファイルを省略した場合は、カレントディレクトリにある .rmd が1つだけなら、それを使う。
func (c *CLI) singleInput(opts *options, command string) (string, int) {
	if len(opts.args) == 0 {
		matches, _ := filepath.Glob("*.rmd")
		if len(matches) == 1 {
			opts.args = matches
		}
	}
	if len(opts.args) != 1 {
		return "", c.fail(fmt.Sprintf("error: 入力ファイルを1つ指定してください（例: reportmd %s report.rmd）", command))
	}
	input := opts.args[0]
	if st, err := os.Stat(input); err != nil || st.IsDir() {
		return "", c.fail(diagnostic(input, 0, "error", "入力ファイルが見つかりません"))
	}
	return input, 0
}

func defaultOutputPath(input string) string {
	base := filepath.Base(input)
	return filepath.Join(filepath.Dir(input), strings.TrimSuffix(base, filepath.Ext(base))+".pdf")
}

// --- build / watch --------------------------------------------------------

func (c *CLI) build(args []string, watch bool) int {
	opts, err := parseOptions(args, "output", "config", "keep-temp", "watch", "open")
	if err != nil {
		return c.fail("error: " + err.Error())
	}
	if opts.help {
		fmt.Fprint(c.Stdout, usage)
		return 0
	}
	input, code := c.singleInput(opts, "build")
	if code != 0 {
		return code
	}
	output := opts.output
	if output == "" {
		output = defaultOutputPath(input)
	}
	format, ok := build.FormatFromPath(output)
	if !ok {
		return c.fail(diagnostic(output, 0, "error", "出力ファイルの拡張子は .pdf .tex .html .docx のどれかにしてください"))
	}

	opened := false
	run := func() int {
		cfg, err := config.Load(opts.config, input)
		if err != nil {
			return c.reportError(input, err)
		}
		c.reportConfigWarnings(cfg)
		result, err := build.Run(build.Options{
			Input: input, Output: output, Format: format, Config: cfg, KeepTemp: opts.keepTemp,
		})
		if result != nil && result.TempDir != "" {
			defer fmt.Fprintf(c.Stderr, "一時ファイルを残しました: %s\n", result.TempDir)
		}
		if err != nil {
			return c.reportError(input, err)
		}
		c.reportWarnings(input, result.Warnings)
		if result.ToolOutput != "" {
			fmt.Fprintln(c.Stderr, result.ToolOutput)
		}
		fmt.Fprintf(c.Stdout, "%s を出力しました\n", result.Output)
		// --open は、最初に生成できたときだけ開く（監視中に何度も開かない）
		if opts.open && !opened {
			opened = true
			if err := openFile(result.Output); err != nil {
				fmt.Fprintln(c.Stderr, diagnostic(result.Output, 0, "warning", "ファイルを開けませんでした（"+err.Error()+"）"))
			}
		}
		return 0
	}

	if watch || opts.watch {
		return c.watchLoop(input, output, opts.config, run)
	}
	return run()
}

// --- check ----------------------------------------------------------------

// check は、PDF を作らずに誤りを調べる。前処理と設定の検証に加えて、Pandoc があれば
// filter.lua まで通し、参照先が見つからない @名前 なども報告する（XeLaTeX は使わない）。
func (c *CLI) check(args []string) int {
	opts, err := parseOptions(args, "config")
	if err != nil {
		return c.fail("error: " + err.Error())
	}
	if opts.help {
		fmt.Fprint(c.Stdout, usage)
		return 0
	}
	input, code := c.singleInput(opts, "check")
	if code != 0 {
		return code
	}
	cfg, err := config.Load(opts.config, input)
	if err != nil {
		return c.reportError(input, err)
	}
	c.reportConfigWarnings(cfg)

	if build.CheckTools(false) != nil {
		// Pandoc がなければ、前処理だけで調べる
		source, err := os.ReadFile(input)
		if err != nil {
			return c.reportError(input, err)
		}
		pre, err := preprocess.Run(string(source))
		if err != nil {
			return c.reportError(input, err)
		}
		c.reportWarnings(input, pre.Warnings)
		fmt.Fprintln(c.Stderr, "（Pandoc が見つからないため、図表・数式の参照は調べていません）")
		fmt.Fprintf(c.Stdout, "%s: 問題は見つかりませんでした\n", input)
		return 0
	}

	dir, err := os.MkdirTemp("", "reportmd-check-")
	if err != nil {
		return c.reportError(input, err)
	}
	defer os.RemoveAll(dir)
	result, err := build.Run(build.Options{
		Input: input, Output: filepath.Join(dir, "check.tex"), Format: build.LaTeX, Config: cfg,
	})
	if err != nil {
		return c.reportError(input, err)
	}
	c.reportWarnings(input, result.Warnings)
	if result.ToolOutput != "" {
		fmt.Fprintln(c.Stderr, result.ToolOutput)
	}
	if len(result.Warnings) == 0 && result.ToolOutput == "" && len(cfg.Warnings) == 0 {
		fmt.Fprintf(c.Stdout, "%s: 問題は見つかりませんでした\n", input)
	} else {
		fmt.Fprintf(c.Stdout, "%s: エラーはありません（警告を確認してください）\n", input)
	}
	return 0
}
