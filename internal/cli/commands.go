package cli

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"reportmd/internal/build"
	"reportmd/internal/config"
)

// --- watch ----------------------------------------------------------------

// watchInterval は、変更を確かめる間隔。
const watchInterval = 500 * time.Millisecond

// watchLoop は、生成したあと、入力ファイルのあるディレクトリ（画像や設定ファイルを含む）の
// 変更を監視し、変更があるたびに生成し直す。エラーがあっても監視は続ける。
func (c *CLI) watchLoop(input, output, configPath string, run func() int) int {
	ignore := map[string]bool{}
	if abs, err := filepath.Abs(output); err == nil {
		ignore[abs] = true
	}

	last := snapshot(input, configPath, ignore)
	run()
	fmt.Fprintln(c.Stderr, "変更を監視しています（Ctrl+C で終了）")
	ticker := time.NewTicker(watchInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.watchStop:
			return 0
		case <-ticker.C:
		}
		current := snapshot(input, configPath, ignore)
		if current == last {
			continue
		}
		last = current
		fmt.Fprintf(c.Stderr, "\n[%s] 変更を検出しました。生成し直します\n", time.Now().Format("15:04:05"))
		run()
	}
}

// watchMaxFiles は、監視するファイル数の上限（大きなディレクトリで重くならないように）。
const watchMaxFiles = 5000

// snapshot は、監視対象のファイルの更新時刻と大きさをまとめた文字列を返す。
func snapshot(input, configPath string, ignore map[string]bool) string {
	var b strings.Builder
	add := func(path string, info fs.FileInfo) {
		fmt.Fprintf(&b, "%s|%d|%d\n", path, info.ModTime().UnixNano(), info.Size())
	}
	if configPath != "" {
		if info, err := os.Stat(configPath); err == nil {
			add(configPath, info)
		}
	}

	count := 0
	root := filepath.Dir(input)
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if path != root && (strings.HasPrefix(name, ".") || name == "node_modules") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || count >= watchMaxFiles {
			return nil
		}
		if abs, err := filepath.Abs(path); err == nil && ignore[abs] {
			return nil
		}
		if info, err := d.Info(); err == nil {
			count++
			add(path, info)
		}
		return nil
	})
	return b.String()
}

// --- init -----------------------------------------------------------------

const initReport = `---
title: レポートのタイトル
author: 氏名
---

<-> **レポートのタイトル**
<-> 副題

--> 2026年10月15日
--> 学籍番号 0000000
--> 氏名

^

#1 目的

本文を書きます。段落の間は空行で区切ります。

  行頭に半角スペースを2個置くと、その段落は1字下がります。

#1 方法

#2 実験装置

実験の構成を @setup に示します。

![t:実験装置の一覧]{#setup}
| 装置 | 型番 |
| :--- | :--- |
| 電源 | ABC-123 |
| オシロスコープ | XYZ-9 |

#2 原理

独立した数式には、右端に番号が自動で付きます。

$$
F = m a
$$ {#newton}

@newton より、加速度は力に比例します。

#1 結果

図は ` + "`![f:タイトル](images/a.png){#名前}`" + ` のように、行頭に1行で書きます。

#1 考察

#1 結論

# 参考文献

1. 著者名, 書名, 出版社, 発行年.
`

// init は、新しいレポートの雛形を作る。既にあるファイルは、--force がなければ上書きしない。
func (c *CLI) init(args []string) int {
	opts, err := parseOptions(args, "force")
	if err != nil {
		return c.fail("error: " + err.Error())
	}
	if opts.help {
		fmt.Fprint(c.Stdout, usage)
		return 0
	}
	if len(opts.args) > 1 {
		return c.fail("error: 作成先のディレクトリは1つだけ指定してください")
	}
	dir := "."
	if len(opts.args) == 1 {
		dir = opts.args[0]
	}
	if err := os.MkdirAll(filepath.Join(dir, "images"), 0o755); err != nil {
		return c.fail(diagnostic(dir, 0, "error", fmt.Sprintf("ディレクトリを作れません（%v）", err)))
	}

	files := []struct {
		name string
		data []byte
	}{
		{"report.rmd", []byte(initReport)},
		{config.SettingFileName, config.DefaultJSON()},
	}
	for _, f := range files {
		path := filepath.Join(dir, f.name)
		if _, err := os.Stat(path); err == nil && !opts.force {
			return c.fail(diagnostic(path, 0, "error", "ファイルが既にあります（上書きするには --force を付けてください）"))
		}
	}
	for _, f := range files {
		path := filepath.Join(dir, f.name)
		if err := os.WriteFile(path, f.data, 0o644); err != nil {
			return c.fail(diagnostic(path, 0, "error", fmt.Sprintf("ファイルを書き込めません（%v）", err)))
		}
		fmt.Fprintf(c.Stdout, "%s を作成しました\n", path)
	}
	fmt.Fprintf(c.Stdout, "\n次のコマンドで PDF を生成できます:\n  reportmd build %s\n", filepath.Join(dir, "report.rmd"))
	return 0
}

// --- fonts ----------------------------------------------------------------

// fonts は、設定に書けるフォント名を表示する。既定は日本語に対応したフォントだけ。
func (c *CLI) fonts(args []string) int {
	opts, err := parseOptions(args, "all")
	if err != nil {
		return c.fail("error: " + err.Error())
	}
	if opts.help {
		fmt.Fprint(c.Stdout, usage)
		return 0
	}
	pattern := ":lang=ja"
	if opts.all {
		pattern = ":"
	}
	out, err := exec.Command("fc-list", pattern, "family").Output()
	if err != nil {
		return c.fail("error: fc-list が使えないため、フォントを調べられません（fontconfig をインストールしてください）")
	}

	seen := map[string]bool{}
	var names []string
	for _, line := range strings.Split(string(out), "\n") {
		for _, name := range strings.Split(line, ",") {
			name = strings.TrimSpace(name)
			if name != "" && !seen[name] {
				seen[name] = true
				names = append(names, name)
			}
		}
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintln(c.Stdout, name)
	}
	if len(names) == 0 {
		fmt.Fprintln(c.Stderr, "フォントが見つかりませんでした")
	}
	return 0
}

// --- doctor ---------------------------------------------------------------

// latexPackages は、PDF の生成に使う LaTeX のパッケージ。
var latexPackages = []string{"xeCJK.sty", "geometry.sty", "indentfirst.sty", "tabularx.sty", "array.sty", "calc.sty", "fontspec.sty"}

// doctor は、PDF の生成に必要なものが揃っているかを調べて表示する。
func (c *CLI) doctor(args []string) int {
	opts, err := parseOptions(args, "config")
	if err != nil {
		return c.fail("error: " + err.Error())
	}
	if opts.help {
		fmt.Fprint(c.Stdout, usage)
		return 0
	}

	ok := true
	report := func(good bool, label, detail string) {
		mark := "OK"
		if !good {
			mark = "NG"
			ok = false
		}
		fmt.Fprintf(c.Stdout, "[%s] %s", mark, label)
		if detail != "" {
			fmt.Fprintf(c.Stdout, "  %s", detail)
		}
		fmt.Fprintln(c.Stdout)
	}

	fmt.Fprintf(c.Stdout, "reportmd %s\n\n", Version)
	for _, tool := range []struct{ command, label, hint string }{
		{"pandoc", "Pandoc", "https://pandoc.org/installing.html からインストールしてください"},
		{"xelatex", "XeLaTeX", "TeX Live（texlive-xetex・texlive-lang-japanese）をインストールしてください"},
		{"fc-list", "fontconfig（フォントの確認に使う）", "fontconfig をインストールしてください"},
	} {
		if _, err := exec.LookPath(tool.command); err != nil {
			report(false, tool.label, tool.hint)
			continue
		}
		report(true, tool.label, toolVersion(tool.command))
	}

	if _, err := exec.LookPath("kpsewhich"); err == nil {
		for _, pkg := range latexPackages {
			out, err := exec.Command("kpsewhich", pkg).Output()
			found := err == nil && strings.TrimSpace(string(out)) != ""
			hint := ""
			if !found {
				hint = "TeX Live のパッケージが足りません（tlmgr install " + strings.TrimSuffix(pkg, ".sty") + " など）"
			}
			report(found, "LaTeX パッケージ "+pkg, hint)
		}
	}

	cfg, err := config.Load(opts.config, "")
	if err != nil {
		var e *config.Error
		if errors.As(err, &e) {
			report(false, "設定ファイル", diagnostic(e.File, e.Line, "error", e.Message))
		} else {
			report(false, "設定ファイル", err.Error())
		}
	} else if families, found := build.InstalledFonts(); found {
		for _, item := range build.FontSettings(cfg) {
			good := families[strings.ToLower(item[1])]
			hint := ""
			if !good {
				hint = "見つかりません。`reportmd fonts` で使えるフォント名を確認してください"
			}
			report(good, fmt.Sprintf("フォント %s（%s）", item[1], item[0]), hint)
		}
	}

	fmt.Fprintln(c.Stdout)
	if !ok {
		fmt.Fprintln(c.Stdout, "足りないものがあります。上の NG の項目を確認してください")
		return 1
	}
	fmt.Fprintln(c.Stdout, "PDF を生成する準備ができています")
	return 0
}

// toolVersion は、コマンドの --version の1行目を返す。
func toolVersion(command string) string {
	out, err := exec.Command(command, "--version").Output()
	if err != nil {
		return ""
	}
	first, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return first
}
