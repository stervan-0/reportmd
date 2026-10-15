package build

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// texName は、作業ディレクトリに置く LaTeX のファイルの名前（拡張子なし）。
const texName = "report"

// latexMaxRuns は、XeLaTeX を実行する最大の回数（しおり・相互参照が落ち着くまで）。
const latexMaxRuns = 3

// latexRerun は、もう一度実行する必要があることを表すログの文言
// （hyperref のしおり、rerunfilecheck、LaTeX の相互参照）。
var latexRerun = regexp.MustCompile(`Rerun to get|Rerun LaTeX|Label\(s\) may have changed|has changed\. Rerun|Please rerun`)

// latexErrorStart は、ログのエラーの始まり（「! Undefined control sequence.」など）。
var latexErrorStart = regexp.MustCompile(`(?m)^! `)

// runLaTeX は、作業ディレクトリ dir の report.tex を XeLaTeX で PDF にし、output に書き出す。
// ログが求める間だけ実行し直す（最大 latexMaxRuns 回）。実行した回数を返す。
// 画像などの相対パスは、入力ファイルのある場所を基準にする。
// reused（作業ディレクトリを使い回している）なら、前回の補助ファイルが壊れていて失敗した場合に、
// 補助ファイルを消して1回だけやり直す。
func runLaTeX(dir, input, output, source string, reused bool) (int, error) {
	runs, err := latexUntilStable(dir, input, source)
	if err != nil && reused && errorInAuxFile(dir) {
		removeAuxFiles(dir)
		runs, err = latexUntilStable(dir, input, source)
	}
	if err != nil {
		return runs, err
	}
	if err := copyAtomic(filepath.Join(dir, texName+".pdf"), output); err != nil {
		return runs, &Error{Message: fmt.Sprintf("PDF を書き込めません（%v）", err)}
	}
	return runs, nil
}

func latexUntilStable(dir, input, source string) (int, error) {
	tex := filepath.Join(dir, texName+".tex")
	for runs := 1; ; runs++ {
		cmd := exec.Command("xelatex", "-interaction=nonstopmode", "-halt-on-error", "-output-directory="+dir, tex)
		cmd.Dir = filepath.Dir(input)
		var out bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &out
		err := cmd.Run()
		log, _ := os.ReadFile(filepath.Join(dir, texName+".log"))
		if err != nil {
			code := -1
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				code = exitErr.ExitCode()
			}
			text := latexErrorExcerpt(string(log))
			if text == "" {
				text = out.String()
			}
			return runs, toolError("xelatex", code, text, source)
		}
		if runs >= latexMaxRuns || !latexRerun.Match(log) {
			return runs, nil
		}
	}
}

// latexErrorExcerpt は、XeLaTeX のログから、エラーの部分（「! 」の行から、エラーの箇所を示す「l.行番号」の
// 次の行まで）を取り出す。エラーがなければ空。
func latexErrorExcerpt(log string) string {
	loc := latexErrorStart.FindStringIndex(log)
	if loc == nil {
		return ""
	}
	lines := strings.Split(log[loc[0]:], "\n")
	var excerpt []string
	for i, line := range lines {
		excerpt = append(excerpt, line)
		if strings.HasPrefix(line, "l.") || i >= 15 {
			if strings.HasPrefix(line, "l.") && i+1 < len(lines) {
				excerpt = append(excerpt, lines[i+1])
			}
			break
		}
	}
	return strings.TrimSpace(strings.Join(excerpt, "\n"))
}

// latexErrorAt は、ログのエラーの箇所の行「l.2 \broken」の、行番号と内容。
var latexErrorAt = regexp.MustCompile(`(?m)^l\.(\d+) (.*)$`)

// errorInAuxFile は、XeLaTeX のエラーが、補助ファイル（.aux）の中で起きたかどうか。
// エラーの箇所の行（l.行番号 のあとの内容）が、.aux のその行と一致するかで判断する
// （前回の実行が途中で止められて、.aux が壊れている場合など）。
func errorInAuxFile(dir string) bool {
	log, err := os.ReadFile(filepath.Join(dir, texName+".log"))
	if err != nil {
		return false
	}
	m := latexErrorAt.FindStringSubmatch(latexErrorExcerpt(string(log)))
	if m == nil {
		return false
	}
	aux, err := os.ReadFile(filepath.Join(dir, texName+".aux"))
	if err != nil {
		return false
	}
	lines := strings.Split(string(aux), "\n")
	n := 0
	fmt.Sscanf(m[1], "%d", &n)
	return n >= 1 && n <= len(lines) && strings.TrimSpace(m[2]) != "" &&
		strings.HasPrefix(strings.TrimSpace(lines[n-1]), strings.TrimSpace(m[2]))
}

// removeAuxFiles は、作業ディレクトリの LaTeX の補助ファイルを消す。
func removeAuxFiles(dir string) {
	for _, ext := range []string{".aux", ".out", ".toc", ".log"} {
		os.Remove(filepath.Join(dir, texName+ext))
	}
}

// copyAtomic は、src を dst にコピーする。いったん同じディレクトリの一時ファイルに書いてから
// 名前を変えるので、PDF ビューア・プレビューが書き込みの途中のファイルを読むことがない。
func copyAtomic(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // 名前を変えたあとは、何もしない
	if _, err := io.Copy(tmp, in); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}
