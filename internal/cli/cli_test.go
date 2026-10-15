package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer は、監視中のゴルーチンからも安全に書き込めるバッファ。
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func runCLI(args ...string) (int, string, string) {
	var out, err syncBuffer
	code := (&CLI{Stdout: &out, Stderr: &err}).Run(args)
	return code, out.String(), err.String()
}

func writeFile(t *testing.T, dir, name, text string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func contains(t *testing.T, label, s, want string) {
	t.Helper()
	if !strings.Contains(s, want) {
		t.Errorf("%s に %q が含まれるはず:\n%s", label, want, s)
	}
}

// pdfReady は、PDF まで作れる環境（Pandoc・XeLaTeX・xeCJK・既定のフォント）かどうか。
func pdfReady(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"pandoc", "xelatex", "kpsewhich", "fc-list"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("PDF 生成に必要なツールがありません: " + tool)
		}
	}
	if out, _ := exec.Command("kpsewhich", "xeCJK.sty").Output(); strings.TrimSpace(string(out)) == "" {
		t.Skip("xeCJK がありません")
	}
	out, _ := exec.Command("fc-list", ":", "family").Output()
	fonts := strings.ToLower(string(out))
	for _, font := range []string{"ipaexmincho", "ipaexgothic", "noto sans mono cjk jp"} {
		if !strings.Contains(fonts, font) {
			t.Skip("既定のフォントがありません: " + font)
		}
	}
}

func pandocReady(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("pandoc"); err != nil {
		t.Skip("Pandoc がありません")
	}
}

func pdfText(t *testing.T, pdf string) string {
	t.Helper()
	if _, err := exec.LookPath("pdftotext"); err != nil {
		t.Skip("pdftotext がありません")
	}
	out, err := exec.Command("pdftotext", "-layout", pdf, "-").Output()
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

// --- コマンドの振り分け -----------------------------------------------------

func TestCommands(t *testing.T) {
	code, out, _ := runCLI("--version")
	if code != 0 || out != "reportmd "+Version+"\n" {
		t.Errorf("--version: %d %q", code, out)
	}
	code, out, _ = runCLI("--help")
	if code != 0 || !strings.Contains(out, "使い方") {
		t.Errorf("--help: %d", code)
	}
	if code, _, err := runCLI(); code != 1 || !strings.Contains(err, "使い方") {
		t.Errorf("引数がなければ使い方を表示し、1 を返す")
	}
	if code, _, err := runCLI("unknown"); code != 1 || !strings.Contains(err, "不明なコマンド") {
		t.Errorf("不明なコマンドは 1 を返す")
	}
}

func TestParseOptions(t *testing.T) {
	opts, err := parseOptions([]string{"a.rmd", "-o", "x.pdf", "--config=s.json", "--keep-temp", "-w"}, "output", "config", "keep-temp", "watch")
	if err != nil || opts.output != "x.pdf" || opts.config != "s.json" || !opts.keepTemp || !opts.watch || len(opts.args) != 1 {
		t.Errorf("オプションと位置引数を分ける: %+v %v", opts, err)
	}
	opts, err = parseOptions([]string{"-ox.pdf", "--", "-a.rmd"}, "output")
	if err != nil || opts.output != "x.pdf" || opts.args[0] != "-a.rmd" {
		t.Errorf("-oFILE と -- のあとの引数: %+v %v", opts, err)
	}
	for _, args := range [][]string{{"--nope"}, {"-z"}, {"-o"}, {"--keep-temp=1"}, {"--force"}} {
		if _, err := parseOptions(args, "output", "keep-temp"); err == nil {
			t.Errorf("%v はエラーになるはず", args)
		}
	}
}

// --- build の入力チェック ---------------------------------------------------

func TestBuildInputErrors(t *testing.T) {
	dir := t.TempDir()

	if code, _, err := runCLI("build"); code != 1 || !strings.Contains(err, "入力ファイルを1つ指定") {
		t.Errorf("入力ファイルがなければ 1: %s", err)
	}
	missing := filepath.Join(dir, "none.rmd")
	if code, _, err := runCLI("build", missing); code != 1 || !strings.HasPrefix(err, missing+": error: 入力ファイルが見つかりません") {
		t.Errorf("存在しない入力ファイルは、そのファイル名つきで 1: %s", err)
	}
	input := writeFile(t, dir, "report.rmd", "本文\n")
	if code, _, err := runCLI("build", input, "--nope"); code != 1 || !strings.Contains(err, "--nope") {
		t.Errorf("不明なオプションは 1: %s", err)
	}
	if code, _, err := runCLI("build", input, "-o", filepath.Join(dir, "a.txt")); code != 1 || !strings.Contains(err, "拡張子") {
		t.Errorf("対応していない出力形式は 1: %s", err)
	}

	setting := writeFile(t, dir, "bad.json", `{ "text": { "font_size": "100pt" } }`)
	if code, _, err := runCLI("build", input, "-c", setting); code != 1 || !strings.HasPrefix(err, setting+": error: 設定 text.font_size の値が不正です") {
		t.Errorf("不正な設定は、項目名つきのエラー: %s", err)
	}
	broken := writeFile(t, dir, "broken.json", "{\n  \"text\": {\n    \"font_size\": \"11pt\",\n  }\n}\n")
	if code, _, err := runCLI("build", input, "-c", broken); code != 1 || !strings.HasPrefix(err, broken+":4: error: 設定ファイルがJSONとして不正です") {
		t.Errorf("JSON の構文エラーは、ファイル名と行番号つき: %s", err)
	}
	none := filepath.Join(dir, "none.json")
	if code, _, err := runCLI("build", input, "-c", none); code != 1 || !strings.HasPrefix(err, none+": error: 設定ファイルが見つかりません") {
		t.Errorf("-c のファイルがなければ、そのファイル名つき: %s", err)
	}

	syntax := writeFile(t, dir, "syntax.rmd", "本文\n\n$$\nx\n")
	if code, _, err := runCLI("build", syntax); code != 1 || !strings.HasPrefix(err, syntax+":3: error: 数式ブロックが閉じられていません") {
		t.Errorf("独自構文のエラーは、ファイル名と行番号つき: %s", err)
	}
	table := writeFile(t, dir, "table.rmd", "本文\n\n![t:なし]\n\n本文\n")
	if code, _, err := runCLI("build", table); code != 1 || !strings.HasPrefix(err, table+":3: error: ![t:...] の直後に表がありません") {
		t.Errorf("直後に表がない ![t:...] はエラー: %s", err)
	}
	figure := writeFile(t, dir, "figure.rmd", "![f:パスなし]\n")
	if code, _, err := runCLI("build", figure); code != 1 || !strings.HasPrefix(err, figure+":1: error: 図には画像のパスが必要です") {
		t.Errorf("画像のパスがない ![f:...] はエラー: %s", err)
	}
}

// --- PDF の生成 -----------------------------------------------------------

const twoPages = "# テスト\n\n1ページ目の本文です。\n\n^\n\n2ページ目の本文です。\n"

func TestBuildPDF(t *testing.T) {
	pdfReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", twoPages)

	code, out, errOut := runCLI("build", input)
	if code != 0 || errOut != "" {
		t.Fatalf("PDF を生成できるはず: %d %s", code, errOut)
	}
	pdf := filepath.Join(dir, "report.pdf")
	contains(t, "標準出力", out, pdf)
	data, _ := os.ReadFile(pdf)
	if !bytes.HasPrefix(data, []byte("%PDF")) {
		t.Fatalf("PDF ではない")
	}
	if info, err := exec.Command("pdfinfo", pdf).Output(); err == nil {
		if !regexp.MustCompile(`Pages:\s+2`).Match(info) {
			t.Errorf("改ページで2ページになる:\n%s", info)
		}
	}

	output := filepath.Join(dir, "out.pdf")
	if code, _, _ := runCLI("build", input, "-o", output); code != 0 {
		t.Errorf("-o で出力先を指定できる")
	}
	if _, err := os.Stat(output); err != nil {
		t.Errorf("-o の場所に出力される")
	}
	if code, _, err := runCLI("build", input, "-o", filepath.Join(dir, "nothing", "out.pdf")); code != 1 || !strings.Contains(err, "出力先のディレクトリがありません") {
		t.Errorf("出力先のディレクトリがなければ 1: %s", err)
	}
}

func TestBuildConfigProblems(t *testing.T) {
	pdfReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", twoPages)

	setting := writeFile(t, dir, "setting.json", `{ "font": { "main": "NoSuchFontXYZ" } }`)
	code, _, errOut := runCLI("build", input)
	if code != 1 || !strings.HasPrefix(errOut, setting+": error: フォント「NoSuchFontXYZ」が見つかりません") {
		t.Errorf("存在しないフォントは、設定ファイル名とフォント名つきで 1: %s", errOut)
	}

	writeFile(t, dir, "setting.json", `{ "unknown_key": 1 }`)
	code, _, errOut = runCLI("build", input)
	if code != 0 {
		t.Fatalf("未知の設定キーがあっても PDF は出力する: %s", errOut)
	}
	contains(t, "警告", errOut, setting+": warning: 未知の設定キーを無視します: unknown_key")
}

func TestBuildKeepTemp(t *testing.T) {
	pdfReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", twoPages)
	code, _, errOut := runCLI("build", input, "--keep-temp")
	if code != 0 {
		t.Fatal(errOut)
	}
	m := regexp.MustCompile(`一時ファイルを残しました: (.+)`).FindStringSubmatch(errOut)
	if m == nil {
		t.Fatalf("一時ディレクトリを表示する: %s", errOut)
	}
	defer os.RemoveAll(m[1])
	for _, name := range []string{"body.md", "preamble.tex", "meta.json", "filter.lua"} {
		if _, err := os.Stat(filepath.Join(m[1], name)); err != nil {
			t.Errorf("%s が残る", name)
		}
	}
}

func TestBuildFrontMatter(t *testing.T) {
	pdfReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", "---\ntitle: 実験レポート\ngeometry: margin=1mm\n---\n\n本文\n")
	code, _, errOut := runCLI("build", input)
	if code != 0 {
		t.Fatal(errOut)
	}
	contains(t, "警告", errOut, input+":3: warning: 対応外のフロントマターのキーを無視します: geometry")
	if info, err := exec.Command("pdfinfo", filepath.Join(dir, "report.pdf")).Output(); err == nil {
		contains(t, "PDF のメタデータ", string(info), "実験レポート")
	}
}

func TestBuildNumbersAndReferences(t *testing.T) {
	pdfReady(t)
	dir := t.TempDir()
	source := "#1 はじめに\n\n#2 背景\n\n# 参考文献\n\n![t:結果]{#res}\n| a | b |\n|---|---|\n| 1 | 2 |\n\n" +
		"$$\nE = mc^2\n$$ {#energy}\n\n@res と @energy を見よ。@none も。\n"
	input := writeFile(t, dir, "report.rmd", source)
	code, _, errOut := runCLI("build", input)
	if code != 0 {
		t.Fatal(errOut)
	}
	contains(t, "警告", errOut, "参照先の図表・数式が見つかりません: @none")
	text := pdfText(t, filepath.Join(dir, "report.pdf"))
	// pdftotext の空白の入り方は一定でないので、空白を除いて比べる
	compact := strings.Join(strings.Fields(text), "")
	for _, want := range []string{"1はじめに", "1.1背景", "表1結果", "(1)", "表1と式(1)を見よ"} {
		contains(t, "PDF の本文", compact, want)
	}
	if regexp.MustCompile(`\d\s*参考文献`).MatchString(text) {
		t.Errorf("標準の # 見出しには番号が付かない:\n%s", text)
	}
}

func TestBuildOtherFormats(t *testing.T) {
	pandocReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", "#1 はじめに\n\n--> 右\n\n![t:表]\n| a | b |\n|---|---|\n| 1 | 2 |\n")

	html := filepath.Join(dir, "report.html")
	if code, _, errOut := runCLI("build", input, "-o", html); code != 0 {
		t.Fatal(errOut)
	}
	data, _ := os.ReadFile(html)
	contains(t, "HTML", string(data), "text-align: right")
	contains(t, "HTML", string(data), "表1 表")

	tex := filepath.Join(dir, "report.tex")
	if code, _, errOut := runCLI("build", input, "-o", tex); code != 0 {
		t.Fatal(errOut)
	}
	data, _ = os.ReadFile(tex)
	contains(t, "LaTeX", string(data), `\begin{flushright}`)
	contains(t, "LaTeX", string(data), `\usepackage{xeCJK}`)
}

// --- check ----------------------------------------------------------------

func TestCheck(t *testing.T) {
	dir := t.TempDir()
	good := writeFile(t, dir, "good.rmd", "#1 はじめに\n\n本文\n")
	code, out, errOut := runCLI("check", good)
	if code != 0 || !strings.Contains(out, "問題は見つかりませんでした") || errOut != "" {
		t.Errorf("問題のない文書: %d %s %s", code, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(dir, "good.pdf")); err == nil {
		t.Errorf("check は PDF を作らない")
	}

	bad := writeFile(t, dir, "bad.rmd", "本文\n\n![t:なし]\n")
	if code, _, errOut := runCLI("check", bad); code != 1 || !strings.HasPrefix(errOut, bad+":3: error:") {
		t.Errorf("構文のエラーは 1: %s", errOut)
	}

	pandocReady(t)
	ref := writeFile(t, dir, "ref.rmd", "#3 飛び\n\n@missing を参照。\n")
	code, out, errOut = runCLI("check", ref)
	if code != 0 {
		t.Fatalf("警告だけなら 0: %s", errOut)
	}
	contains(t, "警告", errOut, ref+":1: warning: 見出しレベルが飛んでいます")
	contains(t, "警告", errOut, "参照先の図表・数式が見つかりません: @missing")
	contains(t, "標準出力", out, "警告を確認してください")
}

// --- 入力の省略 -----------------------------------------------------------

func chdir(t *testing.T, dir string) {
	t.Helper()
	old, _ := os.Getwd()
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(old) })
}

func TestInputShortcuts(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	writeFile(t, dir, "only.rmd", "本文\n")

	// build を省略して、入力ファイルだけを書ける
	if code, _, errOut := runCLI("check", "only.rmd"); code != 0 {
		t.Fatalf("check: %s", errOut)
	}
	if code, _, errOut := runCLI("nothing.rmd"); code != 1 || !strings.Contains(errOut, "nothing.rmd: error: 入力ファイルが見つかりません") {
		t.Errorf("「reportmd X.rmd」は build として扱う: %s", errOut)
	}

	// 入力ファイルを省略したら、1つだけある .rmd を使う
	if code, out, errOut := runCLI("check"); code != 0 || !strings.Contains(out, "only.rmd") {
		t.Errorf(".rmd が1つなら、それを使う: %s %s", out, errOut)
	}
	writeFile(t, dir, "second.rmd", "本文\n")
	if code, _, errOut := runCLI("check"); code != 1 || !strings.Contains(errOut, "入力ファイルを1つ指定") {
		t.Errorf(".rmd が2つ以上なら、指定を求める: %s", errOut)
	}
}

// --- init -----------------------------------------------------------------

func TestInit(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "new")
	code, out, errOut := runCLI("init", dir)
	if code != 0 {
		t.Fatal(errOut)
	}
	contains(t, "標準出力", out, "report.rmd")
	for _, name := range []string{"report.rmd", "setting.json", "images"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("%s を作る", name)
		}
	}
	if code, _, errOut := runCLI("init", dir); code != 1 || !strings.Contains(errOut, "--force") {
		t.Errorf("既にあるファイルは上書きしない: %s", errOut)
	}
	if code, _, _ := runCLI("init", dir, "--force"); code != 0 {
		t.Errorf("--force で上書きする")
	}

	// 雛形は、そのまま警告なしで通る
	code, _, errOut = runCLI("check", filepath.Join(dir, "report.rmd"))
	if code != 0 || errOut != "" {
		t.Errorf("雛形は警告なしで通る: %s", errOut)
	}
}

// --- watch ----------------------------------------------------------------

func TestWatchRebuildsOnChange(t *testing.T) {
	pandocReady(t)
	dir := t.TempDir()
	input := writeFile(t, dir, "report.rmd", "本文\n")
	output := filepath.Join(dir, "report.html")

	var out, errOut syncBuffer
	stop := make(chan struct{})
	done := make(chan int)
	c := &CLI{Stdout: &out, Stderr: &errOut, watchStop: stop}
	go func() { done <- c.Run([]string{"watch", input, "-o", output}) }()

	waitFor := func(cond func() bool) bool {
		for deadline := time.Now().Add(20 * time.Second); time.Now().Before(deadline); time.Sleep(50 * time.Millisecond) {
			if cond() {
				return true
			}
		}
		return false
	}
	if !waitFor(func() bool { return strings.Contains(errOut.String(), "変更を監視しています") }) {
		t.Fatalf("監視を始める: %s", errOut.String())
	}
	// 構文のエラーがあっても、監視は続ける
	time.Sleep(20 * time.Millisecond)
	writeFile(t, dir, "report.rmd", "![f:パスなし]\n")
	if !waitFor(func() bool { return strings.Contains(errOut.String(), "画像のパスが必要です") }) {
		t.Fatalf("変更を検出してエラーを表示する: %s", errOut.String())
	}
	writeFile(t, dir, "report.rmd", "直した本文\n")
	if !waitFor(func() bool { return strings.Count(out.String(), "を出力しました") >= 2 }) {
		t.Fatalf("直したら生成し直す: %s", out.String())
	}
	close(stop)
	if code := <-done; code != 0 {
		t.Errorf("止めたら 0 を返す")
	}
	data, _ := os.ReadFile(output)
	contains(t, "HTML", string(data), "直した本文")
}
