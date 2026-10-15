package build

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"reportmd/internal/config"
)

func TestLatexErrorExcerpt(t *testing.T) {
	log := strings.Join([]string{
		"(/usr/share/texlive/texmf-dist/tex/latex/base/size10.clo)",
		"! Undefined control sequence.",
		"<argument> \\undefinedcmd ",
		"                          x",
		"l.90 \\undefinedcmd",
		"                   x",
		"Here is how much of TeX's memory you used:",
	}, "\n")
	want := "! Undefined control sequence.\n<argument> \\undefinedcmd \n                          x\nl.90 \\undefinedcmd\n                   x"
	if got := latexErrorExcerpt(log); got != want {
		t.Errorf("エラーの部分:\n%q\nwant\n%q", got, want)
	}
	if got := latexErrorExcerpt("This is XeTeX\nOutput written on report.pdf"); got != "" {
		t.Errorf("エラーがなければ空: %q", got)
	}
	// 取り出した部分から、説明と行番号を推定できる
	hint, line := explainLaTeXError(latexErrorExcerpt(log), "本文\n\n$$\n\\undefinedcmd x\n$$\n")
	if !strings.Contains(hint, "定義されていない命令") || line != 4 {
		t.Errorf("説明と行番号: %q %d", hint, line)
	}
}

func TestCopyAtomic(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.pdf")
	dst := filepath.Join(dir, "out", "report.pdf")
	os.MkdirAll(filepath.Dir(dst), 0o755)
	os.WriteFile(src, []byte("%PDF-new"), 0o644)
	os.WriteFile(dst, []byte("%PDF-old"), 0o644)
	if err := copyAtomic(src, dst); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(dst); string(data) != "%PDF-new" {
		t.Errorf("中身: %q", data)
	}
	// 一時ファイルは残らない
	entries, _ := os.ReadDir(filepath.Dir(dst))
	if len(entries) != 1 {
		t.Errorf("一時ファイルが残っている: %v", entries)
	}
}

func latexReady(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"pandoc", "xelatex", "fc-list"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skip("PDF 生成に必要なツールがありません: " + tool)
		}
	}
	if CheckFonts(config.Default()) != nil {
		t.Skip("既定のフォントがありません")
	}
}

// 作業ディレクトリを使い回すと、2回目からは XeLaTeX が1回で済む（しおりが前回と同じなら）。
// 見出しが変わったときは、しおりを作り直すために、もう一度実行する。
func TestWorkDirReusesAuxiliaryFiles(t *testing.T) {
	latexReady(t)
	dir := t.TempDir()
	input := filepath.Join(dir, "report.reportmd")
	output := filepath.Join(dir, "report.pdf")
	work := filepath.Join(dir, "work")
	build := func(text string) *Result {
		t.Helper()
		os.WriteFile(input, []byte(text), 0o644)
		result, err := Run(Options{Input: input, Output: output, Config: config.Default(), WorkDir: work})
		if err != nil {
			t.Fatal(err)
		}
		if data, _ := os.ReadFile(output); !strings.HasPrefix(string(data), "%PDF") {
			t.Fatal("PDF が出力されていない")
		}
		return result
	}

	if r := build("#1 はじめに\n\n本文\n"); r.LaTeXRuns != 2 {
		t.Errorf("最初は、しおりを作るために2回: %d", r.LaTeXRuns)
	}
	if r := build("#1 はじめに\n\n本文を書き換えた\n"); r.LaTeXRuns != 1 {
		t.Errorf("見出しが同じなら1回: %d", r.LaTeXRuns)
	}
	if r := build("#1 はじめに\n\n本文\n\n#1 おわりに\n\n本文\n"); r.LaTeXRuns != 2 {
		t.Errorf("見出しが変わったら2回: %d", r.LaTeXRuns)
	}
	if _, err := os.Stat(filepath.Join(work, texName+".aux")); err != nil {
		t.Error("作業ディレクトリが残っていない")
	}

	// 作業ディレクトリを指定しなければ、毎回2回（一時ディレクトリは消す）
	result, err := Run(Options{Input: input, Output: output, Config: config.Default()})
	if err != nil || result.LaTeXRuns != 2 {
		t.Errorf("作業ディレクトリなし: %d %v", result.LaTeXRuns, err)
	}

	// 補助ファイルが壊れていても、消してやり直す
	os.WriteFile(filepath.Join(work, texName+".aux"), []byte("\\relax\n\\broken{"), 0o644)
	if r := build("#1 はじめに\n\n本文\n"); r.LaTeXRuns < 1 {
		t.Errorf("壊れた補助ファイル: %d", r.LaTeXRuns)
	}
}

// XeLaTeX のエラーは、ログから取り出して、説明と推定した行番号を付ける。
func TestLaTeXErrorFromLog(t *testing.T) {
	latexReady(t)
	dir := t.TempDir()
	input := filepath.Join(dir, "report.reportmd")
	os.WriteFile(input, []byte("本文\n\n$$\n\\undefinedcmd x\n$$\n"), 0o644)
	_, err := Run(Options{Input: input, Output: filepath.Join(dir, "report.pdf"), Config: config.Default(), WorkDir: filepath.Join(dir, "work")})
	e, ok := err.(*Error)
	if !ok {
		t.Fatalf("エラーにならない: %v", err)
	}
	for _, want := range []string{"xelatex の終了コード", "定義されていない命令", "Undefined control sequence"} {
		if !strings.Contains(e.Message, want) {
			t.Errorf("メッセージに %q がない:\n%s", want, e.Message)
		}
	}
	if e.Line != 4 {
		t.Errorf("行番号: %d", e.Line)
	}
	if _, err := os.Stat(filepath.Join(dir, "report.pdf")); err == nil {
		t.Error("失敗したのに PDF を書いた")
	}
}
