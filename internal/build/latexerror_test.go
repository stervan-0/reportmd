package build

import (
	"strings"
	"testing"
)

func TestExplainLaTeXError(t *testing.T) {
	source := "#1 はじめに\n\n本文です。\n\nインライン $\\alpha \\undefinedcommand{x}$ の式。\n\n続きの段落です。\n"
	output := "Error producing PDF.\n! Undefined control sequence.\nl.94 インライン \\(\\alpha \\undefinedcommand"
	hint, line := explainLaTeXError(output, source)
	if !strings.Contains(hint, "定義されていない命令") || line != 5 {
		t.Errorf("説明と行番号: %q %d", hint, line)
	}

	hint, line = explainLaTeXError("! Missing $ inserted.\n<inserted text>\n                $\nl.95 ^^L", source)
	if !strings.Contains(hint, "数式の書き方") || line != 0 {
		t.Errorf("断片がなければ行番号は 0: %q %d", hint, line)
	}

	hint, line = explainLaTeXError("! LaTeX Error: File `missing.png' not found.", source)
	if !strings.Contains(hint, "ファイルが見つかりません") || line != 0 {
		t.Errorf("ファイルが見つからない: %q %d", hint, line)
	}

	if hint, _ := explainLaTeXError("something else", source); hint != "" {
		t.Errorf("知らないエラーには説明を付けない: %q", hint)
	}
}

func TestLocateFragment(t *testing.T) {
	source := "a \\foo{x}\nb \\foo{y}\nc \\bar{z}\n"
	// \foo は2行にあるので決められない。前の断片 \bar（1行だけ）を使う
	if got := locateFragment(`c \(\bar`, source); got != 3 {
		t.Errorf("1行だけに見つかる断片を使う: %d", got)
	}
	if got := locateFragment(`\(\foo`, source); got != 0 {
		t.Errorf("2行以上に見つかる断片だけなら 0: %d", got)
	}
}
