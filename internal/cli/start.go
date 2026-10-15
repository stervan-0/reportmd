package cli

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// start は、引数なしの「reportmd」。カレントディレクトリの入力ファイル（.reportmd か .rmd）を、変更を監視しながら
// PDF にし、PDF ビューアで開く（watch --open と同じ）。
//   - 1つ     : それを監視する
//   - ない   : 雛形を作るか尋ね、作ったら監視を始める（端末でなければ尋ねずに使い方を表示）
//   - 2つ以上 : どれを使うか決められないので、ファイルの一覧を表示する
func (c *CLI) start() int {
	matches := findInputs()
	switch {
	case len(matches) == 1:
		return c.build([]string{matches[0], "--open"}, true)
	case len(matches) > 1:
		fmt.Fprintln(c.Stderr, "error: .reportmd（.rmd）が複数あるため、どれを使うか決められません。ファイル名を指定してください:")
		for _, name := range matches {
			fmt.Fprintf(c.Stderr, "  reportmd watch %s --open\n", name)
		}
		return 1
	}

	if !c.Interactive {
		fmt.Fprint(c.Stderr, usage)
		return 1
	}
	fmt.Fprint(c.Stdout, "このフォルダに .reportmd がありません。レポートの雛形を作りますか？ [Y/n] ")
	answer, _ := bufio.NewReader(c.Stdin).ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "", "y", "yes", "はい":
	default:
		fmt.Fprintln(c.Stdout, "作りませんでした。使い方は reportmd --help で確認できます")
		return 0
	}
	// 既にある setting.json は、利用者のものなので残す
	if code := c.writeTemplate(".", false, true); code != 0 {
		return code
	}
	fmt.Fprintln(c.Stdout)
	return c.build([]string{"report.reportmd", "--open"}, true)
}

// isTerminal は、ファイルが端末（キーボードからの入力）かどうか。
func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
