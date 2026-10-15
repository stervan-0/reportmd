package build

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// LaTeX のエラーを、利用者向けの説明と、元の .rmd の行番号（推定）にする。
//
// XeLaTeX のエラーは、Pandoc が作った中間の .tex の行番号を示すので、そのままでは
// .rmd のどこが悪いのかわからない。エラーの行に表示される本文の断片を .rmd から探して、
// 行番号を推定する。

type latexHint struct {
	pattern *regexp.Regexp
	message string
}

var latexHints = []latexHint{
	{regexp.MustCompile(`Undefined control sequence`), "定義されていない命令（\\ で始まる語）があります。数式の命令のつづりを確認してください"},
	{regexp.MustCompile(`Missing \$ inserted`), "数式の書き方に誤りがあります。括弧 { } の対応や、数式の外で _ ^ を使っていないかを確認してください"},
	{regexp.MustCompile(`Missing \} inserted|Extra \}|Missing \{ inserted|Extra \\right|Missing \\right`), "括弧の対応が取れていません。数式の { } や \\left \\right の組を確認してください"},
	{regexp.MustCompile(`File .+ not found`), "ファイルが見つかりません。画像などのパスを確認してください"},
	{regexp.MustCompile(`Double subscript|Double superscript`), "数式で _ や ^ が続いています。x_{a_b} のように { } でまとめてください"},
	{regexp.MustCompile(`Misplaced alignment tab character &`), "& は表や aligned などの中でしか使えません。文字として使うには \\& と書いてください"},
	{regexp.MustCompile(`Environment .+ undefined`), "定義されていない環境（\\begin{...}）があります。環境の名前を確認してください"},
	{regexp.MustCompile(`TeX capacity exceeded`), "LaTeX の処理が終わりませんでした。数式の中で命令が自分自身を呼んでいないかを確認してください"},
}

// LaTeX のエラーの行「l.94 インライン \(\alpha \undefinedcommand」
var latexErrorLine = regexp.MustCompile(`(?m)^l\.\d+ (.*)$`)

// 断片を区切る記号（LaTeX に変換されると変わる部分）
var fragmentSeparators = regexp.MustCompile(`\\\(|\\\)|\\\[|\\\]|[{}$\s]+|\^\^.`)

// explainLaTeXError は、Pandoc のエラー出力から、説明と、.rmd の行番号（わからなければ 0）を返す。
func explainLaTeXError(output, source string) (string, int) {
	hint := ""
	for _, h := range latexHints {
		if h.pattern.MatchString(output) {
			hint = h.message
			break
		}
	}
	m := latexErrorLine.FindStringSubmatch(output)
	if m == nil {
		return hint, 0
	}
	return hint, locateFragment(m[1], source)
}

// locateFragment は、エラーの行の断片を .rmd から探し、行番号を返す。
// エラーの位置に近い（後ろの）断片から順に、1つの行にだけ見つかるものを使う。
func locateFragment(snippet, source string) int {
	lines := strings.Split(source, "\n")
	fragments := fragmentSeparators.Split(snippet, -1)
	for i := len(fragments) - 1; i >= 0; i-- {
		fragment := fragments[i]
		if utf8.RuneCountInString(fragment) < 3 {
			continue
		}
		found := 0
		for n, line := range lines {
			if strings.Contains(line, fragment) {
				if found != 0 {
					found = -1 // 2行以上に見つかる断片では決められない
					break
				}
				found = n + 1
			}
		}
		if found > 0 {
			return found
		}
	}
	return 0
}
