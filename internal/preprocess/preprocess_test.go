package preprocess

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

const (
	pagebreak = "::: {.reportmd-pagebreak}\n:::"
	right     = "::: {.reportmd-right}"
	center    = "::: {.reportmd-center}"
	num       = "{.reportmd-num}"
	caption   = "::: {.reportmd-table-caption}"
	table     = "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n"
	indent    = "[]{.reportmd-indent}"
)

// figure は図のブロックの開始行。line は元の行番号（filter.lua の警告に使う）
func figure(line int) string { return fmt.Sprintf(`::: {.reportmd-figure line="%d"}`, line) }

func run(t *testing.T, source string) *Result {
	t.Helper()
	result, err := Run(source)
	if err != nil {
		t.Fatalf("予期しないエラー: %v\n入力: %q", err, source)
	}
	return result
}

func runError(t *testing.T, source string) *Error {
	t.Helper()
	_, err := Run(source)
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("エラーになるはず: %q", source)
	}
	return e
}

func warningLines(r *Result) []int {
	lines := []int{}
	for _, w := range r.Warnings {
		lines = append(lines, w.Line)
	}
	return lines
}

type convertCase struct {
	name, in, want string
}

func checkConvert(t *testing.T, cases []convertCase) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := run(t, c.in).Text; got != c.want {
				t.Errorf("\n入力: %q\n期待: %q\n結果: %q", c.in, c.want, got)
			}
		})
	}
}

// same は、変換されずにそのまま出力されるべき入力
func same(name, in string) convertCase { return convertCase{name, in, in} }

func TestPreparation(t *testing.T) {
	checkConvert(t, []convertCase{
		same("変換対象のない文書は、そのまま出力する", "# 見出し\n\n本文です。\n\n- 項目\n"),
		{"CRLF を LF に統一する", "a\r\nb\r\n", "a\nb\n"},
		{"BOM を取り除く", "\xef\xbb\xbfa\n", "a\n"},
		{"空の入力は空文字を返す", "", ""},
	})
	if e := runError(t, "\xff\xfe"); !strings.Contains(e.Message, "UTF-8") {
		t.Errorf("UTF-8 として不正な入力はエラーにする: %v", e)
	}
}

func TestPageBreak(t *testing.T) {
	checkConvert(t, []convertCase{
		{"行だけの ^ を改ページに変換する", "前\n\n^\n\n後\n", "前\n\n" + pagebreak + "\n\n後\n"},
		{"前後に空行がなくても、空行を補う", "前\n^\n後\n", "前\n\n" + pagebreak + "\n\n後\n"},
		{"ファイルの先頭・末尾の ^ も変換する", "^\n本文\n^\n", pagebreak + "\n\n本文\n\n" + pagebreak + "\n"},
		{"行末の空白は許容する", "a\n\n^  \n\nb\n", "a\n\n" + pagebreak + "\n\nb\n"},
		{"連続した ^ はそれぞれ改ページにする", "a\n\n^\n^\n\nb\n", "a\n\n" + pagebreak + "\n\n" + pagebreak + "\n\nb\n"},
		same("文章中の ^ は変換しない", "x^2 と 2^n\n\na ^ b\n\n^上付き^\n\n    ^\n"),
	})
}

func TestProtectedCode(t *testing.T) {
	checkConvert(t, []convertCase{
		same("バッククォートのコードブロック", "```\n^\n```\n"),
		same("チルダのコードブロック", "~~~\n^\n~~~\n"),
		same("情報文字列つきのフェンス", "```ruby\n^\n```\n"),
		{"閉じたあとの ^ は変換する", "```\nコード\n```\n\n^\n", "```\nコード\n```\n\n" + pagebreak + "\n"},
		same("長いフェンスの内側の短いフェンスでは閉じない", "````\n```\n^\n```\n````\n"),
		same("種類の違うフェンスでは閉じない", "```\n~~~\n^\n```\n"),
		same("開きフェンスより短いフェンスでは閉じない", "````\n^\n```\n^\n````\n"),
		{"情報文字列に ` を含む行はフェンスではない", "``` a`b\n^\n", "``` a`b\n\n" + pagebreak + "\n"},
		same("インデントされたフェンスも保護する", "- 項目\n\n    ```\n    ^\n    ```\n"),
	})

	r := run(t, "```\n^\nまだコード\n")
	if r.Text != "```\n^\nまだコード\n" || !reflect.DeepEqual(warningLines(r), []int{1}) || !strings.Contains(r.Warnings[0].Message, "コードブロック") {
		t.Errorf("閉じフェンスがなければ、末尾までコードとして扱い警告する: %+v", r)
	}
}

func TestProtectedMath(t *testing.T) {
	checkConvert(t, []convertCase{
		same("数式ブロック内の ^ は変換しない", "$$\n^\n$$\n"),
		same("開始行に式がある数式ブロック", "$$ x = 1\n^\ny = 2 $$\n"),
		{"1行の $$ は後続に影響しない", "$$x^2$$\n\n^\n", "$$x^2$$\n\n" + pagebreak + "\n"},
		{"閉じたあとの ^ は変換する", "$$\nx\n$$\n\n^\n", "$$\nx\n$$\n\n" + pagebreak + "\n"},
	})
	if e := runError(t, "本文\n\n$$\nx\n"); e.Line != 3 || !strings.Contains(e.Message, "数式ブロック") {
		t.Errorf("閉じられていない数式ブロックは、開始行つきでエラー: %+v", e)
	}
}

func TestEquationAttributes(t *testing.T) {
	checkConvert(t, []convertCase{
		{"{#名前} を目印のスパンにする", "$$\nE = mc^2\n$$ {#energy}\n", "$$\nE = mc^2\n$$[]{.reportmd-equation #energy line=\"3\"}\n"},
		{"{-} は番号なしの目印", "$$\nx\n$${-}\n", "$$\nx\n$$[]{.reportmd-equation .unnumbered line=\"3\"}\n"},
		{"1行の数式", "$$ x = 1 $$ {#one}\n", "$$ x = 1 $$[]{.reportmd-equation #one line=\"1\"}\n"},
		{"閉じの行に式がある数式", "$$\nx = 1\ny = 2 $$ {#two}\n", "$$\nx = 1\ny = 2 $$[]{.reportmd-equation #two line=\"3\"}\n"},
		same("数式の中身は変更しない", "$$\n{#a} ^\n--> x\n$$\n"),
		same("コードブロックの中は変換しない", "```\n$$ x $$ {#a}\n```\n"),
	})
	e := runError(t, "$$\nx\n$$ {width=50%}\n")
	if e.Line != 3 || !strings.Contains(e.Message, "{#名前}") || !strings.Contains(e.Message, "{-}") {
		t.Errorf("{#名前} と {-} 以外の属性はエラー: %+v", e)
	}
	r := run(t, "![f:図](a.png){#same}\n\n$$\nx\n$$ {#same}\n")
	if !reflect.DeepEqual(warningLines(r), []int{5}) || !strings.Contains(r.Warnings[0].Message, "#same") || !strings.Contains(r.Warnings[0].Message, "1 行目") {
		t.Errorf("図表と同じ名前は警告する: %+v", r.Warnings)
	}
}

func TestFrontMatter(t *testing.T) {
	checkConvert(t, []convertCase{
		same("フロントマター内の ^ は変換しない", "---\ntitle: a\n^\n---\n\n本文\n"),
		same("... で閉じるフロントマター", "---\ntitle: a\n^\n...\n"),
		{"フロントマターのあとの ^ は変換する", "---\ntitle: a\n---\n\n^\n", "---\ntitle: a\n---\n\n" + pagebreak + "\n"},
		{"先頭の --- の次が空行なら水平線", "---\n\n^\n", "---\n\n" + pagebreak + "\n"},
		same("ファイル先頭以外の --- はフロントマターではない", "本文\n\n---\ntitle: a\n---\n"),
	})
	if e := runError(t, "---\ntitle: a\n\n本文\n"); e.Line != 1 || !strings.Contains(e.Message, "フロントマター") {
		t.Errorf("閉じられていないフロントマターはエラー: %+v", e)
	}

	source := "---\ntitle: a\nlang: en\n\"geometry\": x\nauthor: b\n---\n\n本文\n"
	r := run(t, source)
	if r.Text != source || !reflect.DeepEqual(warningLines(r), []int{3, 4}) ||
		!strings.Contains(r.Warnings[0].Message, "lang") || !strings.Contains(r.Warnings[1].Message, "geometry") {
		t.Errorf("対応外のキーは行番号つきで警告する: %+v", r.Warnings)
	}
	if r := run(t, "---\nauthor:\n  - 山田\n  - name: 佐藤\n# メモ\ntitle: >\n  長い: タイトル\n---\n"); len(r.Warnings) != 0 {
		t.Errorf("値の中の行やコメントは、キーとして扱わない: %+v", r.Warnings)
	}
	if r := run(t, "本文\n\nlang: en\n"); len(r.Warnings) != 0 {
		t.Errorf("フロントマターの外は警告しない")
	}
}

func TestAlign(t *testing.T) {
	checkConvert(t, []convertCase{
		{"--> を右揃えのブロックに", "前\n\n--> 2026年10月12日\n\n後\n", "前\n\n" + right + "\n2026年10月12日\n:::\n\n後\n"},
		{"<-> を中央揃えのブロックに", "<-> 実験レポート\n", center + "\n実験レポート\n:::\n"},
		{"連続する行をまとめ、行ごとに改行する", "--> 2026年10月12日\n--> 大阪工業大学\n--> 山田 太郎\n", right + "\n2026年10月12日\\\n大阪工業大学\\\n山田 太郎\n:::\n"},
		{"空行で別のブロック", "--> a\n\n--> b\n", right + "\na\n:::\n\n" + right + "\nb\n:::\n"},
		{"右揃えと中央揃えは別のブロック", "--> a\n<-> b\n", right + "\na\n:::\n\n" + center + "\nb\n:::\n"},
		{"前の段落に続いても新しいブロック", "本文\n--> 右\n", "本文\n\n" + right + "\n右\n:::\n"},
		{"内容が空の行は読み飛ばす", "--> a\n-->\n-->   \n--> b\n", right + "\na\\\nb\n:::\n"},
		{"内容が空の行だけなら何も出力しない", "前\n\n-->\n\n後\n", "前\n\n\n後\n"},
		{"内容は Markdown のまま渡す", "--> **太字**と$x^2$\n", right + "\n**太字**と$x^2$\n:::\n"},
		{"末尾の空白は取り除く", "--> a  \n", right + "\na\n:::\n"},
		{"日付のピリオドをエスケープする", "--> 2026. 10. 12\n", right + "\n2026\\. 10. 12\n:::\n"},
		same("文章中の --> などは変換しない", "a --> b\n\n-->text\n\n---> x\n\n    --> コード\n"),
		same("保護領域の --> は変換しない", "```\n--> a\n```\n\n$$\n<-> b\n$$\n"),
		same("フロントマター内の --> は変換しない", "---\ntitle: a\n--> b\n---\n"),
		{"コードブロックの直前の揃え行", "--> a\n```\ncode\n```\n", right + "\na\n:::\n\n```\ncode\n```\n"},
		{"ファイル末尾の揃え行", "本文\n\n<-> 末尾", "本文\n\n" + center + "\n末尾\n:::\n"},
		{"引用の内側：接頭辞を保ち、空行は >", "> 引用\n> --> 右\n> --> 2行目\n", "> 引用\n>\n> " + right + "\n> 右\\\n> 2行目\n> :::\n"},
		{"引用の接頭辞が違えば別のブロック", "> --> a\n--> b\n", "> " + right + "\n> a\n> :::\n>\n\n" + right + "\nb\n:::\n"},
		{"リストの内側", "- 項目A\n- --> 右の項目\n- 項目C\n", "- 項目A\n- " + right + "\n  右の項目\n  :::\n- 項目C\n"},
		{"番号付きリスト", "1. <-> 中央\n", "1. " + center + "\n   中央\n   :::\n"},
		{"リスト記号ごとに別の項目", "- --> a\n- --> b\n", "- " + right + "\n  a\n  :::\n- " + right + "\n  b\n  :::\n"},
		{"内容が空のリスト項目は読み飛ばす", "- a\n- -->\n- b\n", "- a\n- b\n"},
	})
}

func TestNumberedHeading(t *testing.T) {
	checkConvert(t, []convertCase{
		{"#1〜#3 をクラスつきの見出しに", "#1 はじめに\n\n#2 背景\n\n#3 詳細\n", "# はじめに " + num + "\n\n## 背景 " + num + "\n\n### 詳細 " + num + "\n"},
		{"前後に空行を補う", "本文\n#1 はじめに\n本文2\n", "本文\n\n# はじめに " + num + "\n\n本文2\n"},
		{"ファイルの先頭・末尾", "#1 先頭\n本文\n#1 末尾", "# 先頭 " + num + "\n\n本文\n\n# 末尾 " + num + "\n"},
		{"スペースが複数あっても詰める", "#1   はじめに\n", "# はじめに " + num + "\n"},
		{"末尾の空白は取り除く", "#1 はじめに  \n", "# はじめに " + num + "\n"},
		{"インライン書式はそのまま", "#2 **太字**と$x^2$\n", "## **太字**と$x^2$ " + num + "\n"},
		same("標準の # 見出しはそのまま", "# 番号なし\n\n## これも番号なし\n\n### これも\n"),
		{"連続する見出し", "#1 a\n#2 b\n", "# a " + num + "\n\n## b " + num + "\n"},
		same("保護領域の #1 は変換しない", "```\n#1 コード\n```\n\n$$\n#1 数式\n$$\n"),
		same("フロントマター内の #1 は変換しない", "---\ntitle: a\n#1 b\n---\n"),
		{"右揃えの直後の見出し", "--> 右\n#1 はじめに\n", right + "\n右\n:::\n\n# はじめに " + num + "\n"},
		{"見出しの後の改ページ", "#1 はじめに\n^\n本文\n", "# はじめに " + num + "\n\n" + pagebreak + "\n\n本文\n"},
	})

	r := run(t, "#4 未対応\n\n#0 x\n\n#9 y\n")
	if r.Text != "#4 未対応\n\n#0 x\n\n#9 y\n" || !reflect.DeepEqual(warningLines(r), []int{1, 3, 5}) || !strings.Contains(r.Warnings[0].Message, "#4") {
		t.Errorf("#4 以降と #0 は警告して通す: %+v", r)
	}
	r = run(t, "#1\n\n#2   \n")
	if r.Text != "#1\n\n#2   \n" || !reflect.DeepEqual(warningLines(r), []int{1, 3}) || !strings.Contains(r.Warnings[0].Message, "見出しの文字列がありません") {
		t.Errorf("見出し文字列が空なら警告して通す: %+v", r)
	}
	for _, source := range []string{"#12 foo\n\n#タグ\n\n#1つ目\n", " #1 字下げ\n\n- #1 リスト\n\n> #1 引用\n"} {
		if r := run(t, source); r.Text != source || len(r.Warnings) != 0 {
			t.Errorf("見出しでない行は、警告せず通す: %q -> %+v", source, r)
		}
	}

	r = run(t, "#1 a\n\n#3 b\n")
	if r.Text != "# a "+num+"\n\n### b "+num+"\n" || !reflect.DeepEqual(warningLines(r), []int{3}) || !strings.Contains(r.Warnings[0].Message, "#1 の次に #3") {
		t.Errorf("レベルの飛びは警告するが見出しにする: %+v", r)
	}
	if r := run(t, "#2 a\n"); !reflect.DeepEqual(warningLines(r), []int{1}) || !strings.Contains(r.Warnings[0].Message, "見出しがない状態") {
		t.Errorf("最初の見出しが #1 でなければ警告: %+v", r.Warnings)
	}
	for _, source := range []string{"#1 a\n#2 b\n#3 c\n#1 d\n#2 e\n", "#1 a\n#1 b\n#2 c\n#2 d\n"} {
		if r := run(t, source); len(r.Warnings) != 0 {
			t.Errorf("上に戻る・同じレベルが続くのは飛びではない: %+v", r.Warnings)
		}
	}
}

func TestFigure(t *testing.T) {
	checkConvert(t, []convertCase{
		{"図のブロックに変換する", "![f:システム構成図](images/a.png)\n", figure(1) + "\n![システム構成図](images/a.png)\n:::\n"},
		{"画像の属性は残す", "![f:図](a.png){width=50%}\n", figure(1) + "\n![図](a.png){width=50%}\n:::\n"},
		{"タイトルが空", "![f](a.png)\n\n![f:](b.png)\n", figure(1) + "\n![](a.png)\n:::\n\n" + figure(3) + "\n![](b.png)\n:::\n"},
		{"タイトルの書式やコロンはそのまま", "![f:**太字**と$x^2$、比率 1:2](a.png)\n", figure(1) + "\n![**太字**と$x^2$、比率 1:2](a.png)\n:::\n"},
		{"前後に空行を補う", "本文\n![f:図](a.png)\n続き\n", "本文\n\n" + figure(2) + "\n![図](a.png)\n:::\n\n続き\n"},
		{"行末の空白は取り除く", "![f:図](a.png)  \n", figure(1) + "\n![図](a.png)\n:::\n"},
		same("保護領域の記法は変換しない", "```\n![f:図](a.png)\n![t:表]\n```\n\n$$\n![f:図](a.png)\n$$\n"),
		same("フロントマターの記法は変換しない", "---\ntitle: a\n![f:図](a.png)\n---\n"),
		{"右揃えの直後の図", "--> 右\n![f:図](a.png)\n", right + "\n右\n:::\n\n" + figure(2) + "\n![図](a.png)\n:::\n"},
		{"図の {#名前} は画像の属性に残す", "![f:図](a.png){#sys width=50%}\n", figure(1) + "\n![図](a.png){#sys width=50%}\n:::\n"},
	})

	if e := runError(t, "本文\n\n![f:パスなし]\n"); e.Line != 3 || !strings.Contains(e.Message, "画像のパス") {
		t.Errorf("画像のパスがなければエラー: %+v", e)
	}
	r := run(t, "![f：全角](a.png)\n")
	if r.Text != "![f：全角](a.png)\n" || !reflect.DeepEqual(warningLines(r), []int{1}) || !strings.Contains(r.Warnings[0].Message, "半角コロン") {
		t.Errorf("全角コロンは警告して通す: %+v", r)
	}
	source := "![図](a.png)\n\n本文 ![f:行中](a.png)\n\n- ![f:リスト](a.png)\n\n> ![f:引用](a.png)\n\n![fig:x](a.png)\n"
	if r := run(t, source); r.Text != source || len(r.Warnings) != 0 {
		t.Errorf("通常の画像や行の途中の ![f: は変換しない: %+v", r)
	}
}

func TestTableCaption(t *testing.T) {
	checkConvert(t, []convertCase{
		{"表の見出しのブロックに変換する", "![t:実験結果]\n" + table, caption + "\n実験結果\n:::\n\n" + table},
		{"空行が1つあってもよい", "![t:実験結果]\n\n" + table, caption + "\n実験結果\n:::\n\n" + table},
		{"タイトルが空", "![t]\n" + table + "\n![t:]\n" + table, caption + "\n:::\n\n" + table + "\n" + caption + "\n:::\n\n" + table},
		{"タイトルの書式はそのまま", "![t:**太字**と$x^2$]\n" + table, caption + "\n**太字**と$x^2$\n:::\n\n" + table},
		{"行末の空白", "![t:実験結果]  \n" + table, caption + "\n実験結果\n:::\n\n" + table},
		{"先頭の | がないパイプ表", "![t:表]\n条件 | 結果\n-----|-----\nA | 10\n", caption + "\n表\n:::\n\n条件 | 結果\n-----|-----\nA | 10\n"},
		{"グリッド表", "![t:表]\n+---+---+\n| a | b |\n+---+---+\n", caption + "\n表\n:::\n\n+---+---+\n| a | b |\n+---+---+\n"},
		{"単純な表", "![t:表]\n条件  結果\n----  ----\nA     10\n", caption + "\n表\n:::\n\n条件  結果\n----  ----\nA     10\n"},
		{"図と表が混ざっていても変換する", "![f:図](a.png)\n\n![t:表]\n" + table, figure(1) + "\n![図](a.png)\n:::\n\n" + caption + "\n表\n:::\n\n" + table},
		{"{#名前} をブロックの ID にする", "![t:実験結果]{#result}\n" + table, "::: {.reportmd-table-caption #result}\n実験結果\n:::\n\n" + table},
		{"タイトルが空の表にも名前", "![t]{#result}\n" + table, "::: {.reportmd-table-caption #result}\n:::\n\n" + table},
		same("本文の @名前 は変更しない", "@sys に示す。[@a; @b]\n"),
	})

	if e := runError(t, "本文\n\n![t:なし]\n\n本文\n"); e.Line != 3 || !strings.Contains(e.Message, "直後に表がありません") {
		t.Errorf("直後に表がなければエラー: %+v", e)
	}
	for _, source := range []string{"![t:x]\n\n\n" + table, "![t:x]"} {
		if e := runError(t, source); !strings.Contains(e.Message, "直後に表がありません") {
			t.Errorf("空行2つ・ファイル末尾はエラー: %+v", e)
		}
	}
	if e := runError(t, "![t:x](a.png)\n"); e.Line != 1 || !strings.Contains(e.Message, "![f:") {
		t.Errorf("後ろに (...) がある行はエラー: %+v", e)
	}
	if e := runError(t, "![t:x]{width=50%}\n"+table); !strings.Contains(e.Message, "{#名前}") {
		t.Errorf("{#名前} 以外の属性はエラー: %+v", e)
	}
	if r := run(t, "![t：全角]\n"+table); !reflect.DeepEqual(warningLines(r), []int{1}) {
		t.Errorf("全角コロンは警告する: %+v", r.Warnings)
	}

	r := run(t, "![f:図](a.png){width=50% #same}\n\n![t:表]{#same}\n"+table)
	if !reflect.DeepEqual(warningLines(r), []int{3}) || !strings.Contains(r.Warnings[0].Message, "1 行目") {
		t.Errorf("同じ名前は2回目で警告する: %+v", r.Warnings)
	}
	if r := run(t, "![f:a](a.png){#a}\n\n![f:b](b.png)\n\n![t:表]{#c}\n"+table); len(r.Warnings) != 0 || len(r.IDs) != 2 {
		t.Errorf("名前の違う図表は警告しない: %+v", r)
	}
}

func TestIndent(t *testing.T) {
	checkConvert(t, []convertCase{
		{"空行のあと・ファイル先頭の段落", "  先頭\n\n  次の段落\n", indent + "先頭\n\n" + indent + "次の段落\n"},
		{"段落の途中の行は変換しない", "  a\n  b\n", indent + "a\n  b\n"},
		same("4スペース・1スペース・3スペースは変換しない", "    コード\n\n 一つ\n\n   三つ\n"),
		same("リストの続き・引用の続きは変換しない", "- 項目\n  続き\n\n  項目の2段落目\n\n> 引用\n  続き\n"),
		same("ほかのブロックの記法なら変換しない", "  - 項目\n\n  # 見出し\n\n  > 引用\n\n  | a | b |\n\n  ---\n"),
		same("保護領域の中は変換しない", "```\n  コード\n```\n\n$$\n  x\n$$\n"),
		{"強調などの記号でも字下げする", "  *強調* 開始\n", indent + "*強調* 開始\n"},
		same("水平線（* * *）も字下げしない", "  * * *\n\n  ___\n"),
	})
	out := run(t, "# 見出し\n  本文\n\n^\n  次\n\n--> 右\n\n  後\n").Text
	for _, want := range []string{"# 見出し\n" + indent + "本文", indent + "次", indent + "後"} {
		if !strings.Contains(out, want) {
			t.Errorf("見出し・改ページ・右揃えの直後も字下げする: %q に %q がない", out, want)
		}
	}
}

func TestMathBraces(t *testing.T) {
	cases := []struct {
		name, in string
		lines    []int
		message  string
	}{
		{"閉じていない {", "本文\n\n$$\n\\frac{1}{2 + x\n$$\n", []int{3}, "閉じていない { が 1 個"},
		{"対応する { のない }", "$$ a } $$\n", []int{1}, "対応する { のない }"},
		{"1行の数式の後ろの属性は数えない", "$$ \\frac{a}{b} $$ {#eq}\n", nil, ""},
		{"エスケープした括弧は数えない", "$$\n\\left\\{ x \\right.\n$$\n", nil, ""},
		{"コメントの中は数えない", "$$\nx^{2} % {メモ\n$$\n", nil, ""},
		{"開始行・閉じの行の式も数える", "$$ \\sqrt{x\n+ 1 $$\n", []int{1}, "閉じていない {"},
		{"対応が取れていれば警告しない", "$$\n\\begin{aligned}\na &= {b}_{c} \\\\\n\\end{aligned}\n$$\n", nil, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := run(t, c.in)
			if !strings.Contains(c.in, "{#") && r.Text != c.in {
				t.Errorf("数式は変更しない: %q", r.Text)
			}
			got := warningLines(r)
			if len(c.lines) == 0 {
				if len(got) != 0 {
					t.Errorf("警告しないはず: %+v", r.Warnings)
				}
				return
			}
			if !reflect.DeepEqual(got, c.lines) || !strings.Contains(r.Warnings[0].Message, c.message) {
				t.Errorf("警告 %v %q のはず: %+v", c.lines, c.message, r.Warnings)
			}
		})
	}
}
