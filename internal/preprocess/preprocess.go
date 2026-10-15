// Package preprocess は、.rmd のテキストを読み、独自構文を Pandoc が理解できる形式へ変換する。
//
// 対応している構文:
//   - 保護領域の判定（フロントマター、コードブロック、数式ブロック）
//   - フロントマターの対応外のキー（title・author 以外）の警告
//   - 図表・数式の参照用の名前（{#名前}）の記録と、重複の警告
//   - 数式の閉じの $$ の後ろの {#名前} / {-}（番号なし）
//   - 改ページ（行だけの ^）
//   - 右揃え（--> ）と中央揃え（<-> ）
//   - 番号付き見出し（#1 #2 #3）
//   - 図（![f:タイトル](画像)）と表の見出し（![t:タイトル]）
//   - 2スペースで始まる段落の字下げ
//
// 保護領域の内側は一切変更しない。
package preprocess

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Error は前処理で見つかったエラー（独自構文の不正、終了のない数式ブロックなど）。
type Error struct {
	Line    int // 元の入力ファイルでの行番号（1始まり。わからなければ 0）
	Message string
}

func (e *Error) Error() string { return e.Message }

// Warning は前処理で見つかった警告（処理は続けられるもの）。
type Warning struct {
	Line    int
	Message string
}

// Result は変換後のテキストと警告の一覧。
type Result struct {
	Text     string
	Warnings []Warning
	// IDs は、図表・数式に付けた参照用の名前と、その行番号。
	IDs map[string]int
}

var (
	pageBreakLine   = regexp.MustCompile(`^\^[ \t]*$`)
	fenceOpenLine   = regexp.MustCompile("^[ ]*(`{3,}|~{3,})(.*)$")
	frontMatterEnd  = regexp.MustCompile(`^(---|\.\.\.)[ \t]*$`)
	frontMatterOpen = regexp.MustCompile(`^---[ \t]*$`)
	// フロントマターの最上位のキー（字下げなし・リスト項目でない行の「キー:」）
	frontMatterKey = regexp.MustCompile(`^(?:"([^"]+)"|'([^']+)'|([^\s#'"\-][^:]*?))[ \t]*:(?:[ \t]|$)`)

	// 右揃え・中央揃えの行。行頭（または引用 > ・リスト記号の直後）に、
	// 記号と半角スペース1個以上、続けて内容が来る。内容が空の行も一致する。
	alignLine = regexp.MustCompile(`^((?:[ ]{0,3}>[ ]?)*)([ ]{0,3}(?:[-*+]|\d{1,9}[.)])[ ]+)?(-->|<->)(?:[ ]+(.*?))?[ \t]*$`)

	// 内容の先頭が「2026. 」のような番号付きリスト記法に見える場合に備える
	listLikeStart = regexp.MustCompile(`^(\d+)([.)])([ \t]|$)`)

	// 番号付き見出し。行頭（0桁目）に # と半角数字1桁、半角スペース、見出し文字列が来る。
	numberedHeadingLine      = regexp.MustCompile(`^#(\d)(?:[ ]+(\S.*?))?[ \t]*$`)
	numberedHeadingWithSpace = regexp.MustCompile(`^#\d[ ]`)
	numberedHeadingOnly      = regexp.MustCompile(`^#\d[ \t]*$`)

	// 図表。行頭に ![f ... または ![t ... が来る。区切りは半角コロンのみ。
	figureStart         = regexp.MustCompile(`^!\[f(?::|\])`)
	tableStart          = regexp.MustCompile(`^!\[t(?::|\])`)
	fullwidthColonStart = regexp.MustCompile(`^!\[[ft]：`)
	figurePrefix        = regexp.MustCompile(`^!\[f:?`)
	// 表の見出し行の後ろには、参照用の名前 {#名前} だけを書ける
	tableCaptionLine = regexp.MustCompile(`^!\[t(?::(.*))?\](?:\{#([^\s{}#]+)\})?[ \t]*$`)
	// 図の行の画像の属性（{#名前 width=50%} など）と、その中の参照用の名前
	figureAttributes = regexp.MustCompile(`\]\([^)]*\)\{([^}]*)\}`)
	idInAttributes   = regexp.MustCompile(`(?:^|\s)#([^\s{}#]+)`)

	// 段落の字下げ。段落の最初の行が、ちょうど半角スペース2個で始まる場合。
	indentLine = regexp.MustCompile(`^[ ]{2}(\S.*)$`)
	// リスト項目の行（記号のあとにスペース）。
	listItemLine = regexp.MustCompile(`^[ ]{0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)`)
	// 2スペースのあとに、ほかのブロックの記法が来る行は、字下げの段落にしない
	// （リスト、見出し、引用、コード、数式、表、脚注、水平線など）
	blockStartAfterIndent = regexp.MustCompile("^(?:[-*+](?:[ \\t]|$)|\\d{1,9}[.)](?:[ \\t]|$)|#{1,6}(?:[ \\t]|$)|>|`{3,}|~{3,}|\\$\\$|\\||\\+[-=:]|:::|\\[\\^[^\\]]+\\]:)")
	horizontalRule        = regexp.MustCompile(`^(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$`)
	atxHeading            = regexp.MustCompile(`^#{1,6}[ \t]`)
	startsWithSpace       = regexp.MustCompile(`^[ \t]`)

	// 数式の閉じの $$ の後ろの属性。{#名前}（参照用の名前）か {-}（番号なし）だけを書ける。
	mathAttributes = regexp.MustCompile(`\$\$[ \t]*\{([^{}]*)\}[ \t]*$`)
	mathID         = regexp.MustCompile(`^#([^\s{}#]+)$`)

	// 表の直後の行の判定（パイプ表・グリッド表・単純表）
	pipeSeparatorRow   = regexp.MustCompile(`^[ ]{0,3}\|?[ ]*:?-+:?[ ]*(?:\|[ ]*:?-+:?[ ]*)*\|?[ ]*$`)
	gridBorderRow      = regexp.MustCompile(`^[ ]{0,3}\+[-=:]+(?:\+[-=:]+)*\+[ ]*$`)
	simpleSeparatorRow = regexp.MustCompile(`^[ ]{0,3}-+(?:[ ]+-+)+[ ]*$`)
)

const (
	headingClass      = "reportmd-num"
	equationClass     = "reportmd-equation"
	figureClass       = "reportmd-figure"
	tableCaptionClass = "reportmd-table-caption"
	indentMarker      = "[]{.reportmd-indent}"
	maxHeadingLevel   = 3
)

var pageBreakBlock = []string{"::: {.reportmd-pagebreak}", ":::"}

// フロントマターで使えるキー。ほかのキーは警告して無視する（filter.lua が取り除く）
var frontMatterKeys = map[string]bool{"title": true, "author": true}

type alignKind int

const (
	alignRight alignKind = iota
	alignCenter
)

var alignClasses = map[alignKind]string{alignRight: "reportmd-right", alignCenter: "reportmd-center"}

type state int

const (
	stateNormal state = iota
	stateFrontMatter
	stateFence
	stateMath
)

type alignBlock struct {
	kind  alignKind
	quote string
	key   string
	lines []string
}

type processor struct {
	lines    []string
	index    int
	output   []string
	warnings []Warning
	ids      map[string]int

	state          state
	regionStart    int
	mathBody       []string // 数式ブロックの中身（括弧の対応を調べるため）
	fenceChar      byte
	fenceLen       int
	afterGenerated bool
	align          *alignBlock
	lastHeading    int
	inList         bool
	lastLineBlank  bool
}

// Run は、入力のテキストを変換する。
func Run(source string) (*Result, error) {
	text, err := normalize(source)
	if err != nil {
		return nil, err
	}
	p := &processor{ids: map[string]int{}, lastLineBlank: true}
	p.lines = splitLines(text)
	for i, line := range p.lines {
		p.index = i
		if err := p.processLine(line, i+1); err != nil {
			return nil, err
		}
		p.lastLineBlank = strip(line) == ""
	}
	if err := p.finish(); err != nil {
		return nil, err
	}

	out := ""
	if len(p.output) > 0 {
		out = strings.Join(p.output, "\n") + "\n"
	}
	return &Result{Text: out, Warnings: p.warnings, IDs: p.ids}, nil
}

// --- 前準備 -------------------------------------------------------------

// normalize は、UTF-8 の確認、BOM の除去、改行コードを LF に統一する。
func normalize(source string) (string, error) {
	if !utf8.ValidString(source) {
		return "", &Error{Message: "入力がUTF-8として読み込めません"}
	}
	source = strings.TrimPrefix(source, "\xef\xbb\xbf")
	source = strings.ReplaceAll(source, "\r\n", "\n")
	return strings.ReplaceAll(source, "\r", "\n"), nil
}

func splitLines(text string) []string {
	if text == "" {
		return nil
	}
	lines := strings.Split(text, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1] // 末尾の改行で生じる空要素
	}
	return lines
}

// strip は前後の ASCII の空白を取り除く（全角スペースは残す）。
func strip(s string) string { return strings.Trim(s, " \t\n\v\f\r\x00") }

func lstrip(s string) string { return strings.TrimLeft(s, " \t\n\v\f\r\x00") }

func rstrip(s string) string { return strings.TrimRight(s, " \t\n\v\f\r\x00") }

func (p *processor) warn(line int, format string, args ...any) {
	p.warnings = append(p.warnings, Warning{Line: line, Message: fmt.Sprintf(format, args...)})
}

// --- 行ごとの処理（状態機械）---------------------------------------------

func (p *processor) processLine(line string, lineno int) error {
	if p.index == 0 && p.frontMatterStart() {
		p.state = stateFrontMatter
		p.regionStart = lineno
		p.output = append(p.output, line)
		return nil
	}

	switch p.state {
	case stateFrontMatter:
		p.inFrontMatter(line, lineno)
	case stateFence:
		p.output = append(p.output, line)
		if p.fenceClose(line) {
			p.state = stateNormal
		}
	case stateMath:
		return p.inMath(line, lineno)
	default:
		return p.inNormal(line, lineno)
	}
	return nil
}

// ファイル先頭が `---` で、次の行が空でなければフロントマター。
// （次が空行なら水平線として扱う。Pandoc と同じ判定）
func (p *processor) frontMatterStart() bool {
	if !frontMatterOpen.MatchString(p.lines[0]) {
		return false
	}
	return len(p.lines) > 1 && strip(p.lines[1]) != ""
}

func (p *processor) inFrontMatter(line string, lineno int) {
	p.output = append(p.output, line)
	if frontMatterEnd.MatchString(line) {
		p.state = stateNormal
		return
	}
	// 対応外のキーは警告する（値は filter.lua が取り除くので、文書には反映されない）
	m := frontMatterKey.FindStringSubmatch(line)
	if m == nil {
		return
	}
	key := m[1] + m[2] + m[3]
	if !frontMatterKeys[key] {
		p.warn(lineno, "対応外のフロントマターのキーを無視します: %s（使えるのは title と author です）", key)
	}
}

// 数式の中身は変更しない。閉じの $$ の行の後ろの属性だけを変換する。
func (p *processor) inMath(line string, lineno int) error {
	if !strings.Contains(line, "$$") {
		p.mathBody = append(p.mathBody, line)
		p.output = append(p.output, line)
		return nil
	}
	p.mathBody = append(p.mathBody, line[:strings.Index(line, "$$")])
	p.checkBraces(p.mathBody, p.regionStart)
	closed, err := p.mathClose(line, lineno)
	if err != nil {
		return err
	}
	p.output = append(p.output, closed)
	p.state = stateNormal
	return nil
}

// checkBraces は、数式の { } の対応を調べ、取れていなければ警告する。
// \{ \} のようにエスケープした括弧と、% から行末までのコメントは数えない。
// （LaTeX のエラーは .rmd のどこが悪いのかわかりにくいので、先に知らせる）
func (p *processor) checkBraces(lines []string, lineno int) {
	depth, unmatched := 0, false
	for _, line := range lines {
		for i := 0; i < len(line); i++ {
			switch line[i] {
			case '\\':
				i++ // 次の1文字はエスケープされている
			case '%':
				i = len(line)
			case '{':
				depth++
			case '}':
				depth--
				if depth < 0 {
					unmatched = true
					depth = 0
				}
			}
		}
	}
	if depth > 0 {
		p.warn(lineno, "数式の括弧 { } の対応が取れていません（閉じていない { が %d 個あります）", depth)
	} else if unmatched {
		p.warn(lineno, "数式の括弧 { } の対応が取れていません（対応する { のない } があります）")
	}
}

func (p *processor) inNormal(line string, lineno int) error {
	if a := parseAlign(line); a != nil {
		p.handleAlign(a)
		return nil
	}

	// 右揃え・中央揃えの行が途切れたので、溜めていたブロックを出力する
	p.flushAlign()

	if heading := p.numberedHeading(line, lineno); heading != "" {
		p.emitBlock([]string{heading}, "")
		return nil
	}
	block, err := p.figureTableBlock(line, lineno)
	if err != nil {
		return err
	}
	if block != nil {
		p.emitBlock(block, "")
		return nil
	}

	switch {
	case p.fenceOpen(line):
		p.state = stateFence
		p.regionStart = lineno
		p.inList = false
		p.emit(line)
	case mathOpen(line):
		p.state = stateMath
		p.regionStart = lineno
		p.inList = false
		_, after, _ := strings.Cut(line, "$$")
		p.mathBody = []string{after}
		p.emit(line)
	case strings.HasPrefix(lstrip(line), "$$"):
		// 1行の数式（$$ 式 $$ {#名前}）
		parts := strings.Split(line, "$$")
		p.checkBraces(parts[1:len(parts)-1], lineno)
		closed, err := p.mathClose(line, lineno)
		if err != nil {
			return err
		}
		p.emit(closed)
	case pageBreakLine.MatchString(line):
		p.emitBlock(pageBreakBlock, "")
	default:
		if indented := p.indentedParagraph(line); indented != "" {
			p.emit(indented)
			return nil
		}
		p.trackList(line)
		p.emit(line)
	}
	return nil
}

// --- 段落の字下げ ---------------------------------------------------------

// indentedParagraph は、字下げの段落の最初の行なら、目印をつけた行を返す。違えば空文字。
// 次の場合は字下げの段落にしない（行はそのまま通す）。
//   - 直前が空行ではない（段落の途中の行）
//   - リスト項目の続きの段落（リストの中）
//   - 2スペースのあとに、ほかのブロックの記法が来る
func (p *processor) indentedParagraph(line string) string {
	m := indentLine.FindStringSubmatch(line)
	if m == nil || !p.paragraphStart() || p.inList {
		return ""
	}
	text := m[1]
	if blockStartAfterIndent.MatchString(text) || horizontalRule.MatchString(text) {
		return ""
	}
	return indentMarker + text
}

// paragraphStart は、段落の先頭か（出力の直前が空行・見出しか、まだ何も出力していない）。
func (p *processor) paragraphStart() bool {
	if len(p.output) == 0 {
		return true
	}
	last := p.output[len(p.output)-1]
	return strip(last) == "" || atxHeading.MatchString(last)
}

// trackList は、リストの中にいるかを追う。リスト項目の行で始まり、字下げされた行や
// 空行は続きとして扱い、空行のあとの、字下げのない行で終わる。
func (p *processor) trackList(line string) {
	switch {
	case strip(line) == "":
	case listItemLine.MatchString(line):
		p.inList = true
	case startsWithSpace.MatchString(line):
		// 字下げされた行は、リスト項目の続き（状態は変えない）
	case p.lastLineBlank:
		p.inList = false
	}
}

// --- 保護領域の判定 -------------------------------------------------------

// fenceOpen は、開きフェンスなら、その文字と長さを記録して true を返す。
func (p *processor) fenceOpen(line string) bool {
	m := fenceOpenLine.FindStringSubmatch(line)
	if m == nil {
		return false
	}
	marker := m[1]
	// バッククォートのフェンスは、情報文字列に ` を含められない
	if marker[0] == '`' && strings.Contains(m[2], "`") {
		return false
	}
	p.fenceChar = marker[0]
	p.fenceLen = len(marker)
	return true
}

// fenceClose は、同じ文字で、開きフェンス以上の長さだけが並ぶ行か。
func (p *processor) fenceClose(line string) bool {
	s := strip(line)
	if len(s) < p.fenceLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] != p.fenceChar {
			return false
		}
	}
	return true
}

// mathOpen は、行頭が $$ で、その行で閉じていなければ数式ブロックの開始。
func mathOpen(line string) bool {
	if !strings.HasPrefix(lstrip(line), "$$") {
		return false
	}
	return strings.Count(line, "$$")%2 == 1
}

// mathClose は、数式を閉じる行の、$$ の後ろの {#名前} / {-} を、目印のスパンに変換する。
// 属性がなければ、行をそのまま返す。
//
//	$$ {#energy}  ->  $$[]{.reportmd-equation #energy line="行番号"}
//	$$ {-}        ->  $$[]{.reportmd-equation .unnumbered line="行番号"}
func (p *processor) mathClose(line string, lineno int) (string, error) {
	loc := mathAttributes.FindStringSubmatchIndex(line)
	if loc == nil {
		return line, nil
	}
	attrs := strip(line[loc[2]:loc[3]])
	var marker string
	if attrs == "-" {
		marker = "." + equationClass + " .unnumbered"
	} else if m := mathID.FindStringSubmatch(attrs); m != nil {
		p.registerID(m[1], lineno)
		marker = "." + equationClass + " #" + m[1]
	} else {
		return "", &Error{Line: lineno, Message: "数式の $$ の後ろには、{#名前}（参照用）か {-}（番号なし）だけを書けます"}
	}
	return fmt.Sprintf(`%s$$[]{%s line="%d"}`, line[:loc[0]], marker, lineno), nil
}

// --- 番号付き見出し -------------------------------------------------------

// numberedHeading は、番号付き見出しの行なら、Pandoc の見出し（クラス付き）の文字列を返す。
// 見出しにならない行は空文字を返す（必要なら警告を記録する）。
//
//	#1 はじめに  ->  # はじめに {.reportmd-num}
//	#2 背景      ->  ## 背景 {.reportmd-num}
func (p *processor) numberedHeading(line string, lineno int) string {
	if !numberedHeadingWithSpace.MatchString(line) && !numberedHeadingOnly.MatchString(line) {
		return ""
	}
	m := numberedHeadingLine.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	level := int(m[1][0] - '0')
	if level < 1 || level > maxHeadingLevel {
		p.warn(lineno, "未対応の見出しレベルです（#%d は使えません。#1〜#3 を使ってください）。通常の段落として扱います", level)
		return ""
	}
	if m[2] == "" {
		p.warn(lineno, "見出しの文字列がありません（#%d）。通常の段落として扱います", level)
		return ""
	}

	if level > p.lastHeading+1 {
		before := fmt.Sprintf("#%d", p.lastHeading)
		if p.lastHeading == 0 {
			before = "見出しがない状態"
		}
		p.warn(lineno, "見出しレベルが飛んでいます（%s の次に #%d）", before, level)
	}
	p.lastHeading = level
	return fmt.Sprintf("%s %s {.%s}", strings.Repeat("#", level), m[2], headingClass)
}

// --- 図と表 ---------------------------------------------------------------

// figureTableBlock は、図・表の行なら、Pandoc のブロック（行の配列）を返す。違えば nil。
//
//	![f:タイトル](画像)  ->  ::: {.reportmd-figure line="行番号"}
//	                         ![タイトル](画像)
//	                         :::
//	![t:タイトル]        ->  ::: {.reportmd-table-caption}
//	                         タイトル
//	                         :::
//	![t:タイトル]{#名前} ->  ::: {.reportmd-table-caption #名前}
//
// 番号とキャプションの組版、@名前 の参照は filter.lua が行う。
func (p *processor) figureTableBlock(line string, lineno int) ([]string, error) {
	if fullwidthColonStart.MatchString(line) {
		p.warn(lineno, "図表の記法の区切りは半角コロン : を使ってください（全角コロン：は図表として扱いません）")
		return nil, nil
	}
	if figureStart.MatchString(line) {
		return p.figureBlock(line, lineno)
	}
	if tableStart.MatchString(line) {
		return p.tableCaptionBlock(line, lineno)
	}
	return nil, nil
}

func (p *processor) figureBlock(line string, lineno int) ([]string, error) {
	if !strings.Contains(line, "](") {
		return nil, &Error{Line: lineno, Message: "図には画像のパスが必要です（例: ![f:タイトル](images/a.png)）"}
	}
	if m := figureAttributes.FindStringSubmatch(line); m != nil {
		if id := idInAttributes.FindStringSubmatch(m[1]); id != nil {
			p.registerID(id[1], lineno)
		}
	}
	image := rstrip(figurePrefix.ReplaceAllLiteralString(line, "!["))
	// line は、filter.lua が警告に元の行番号を表示するために使う
	return []string{fmt.Sprintf(`::: {.%s line="%d"}`, figureClass, lineno), image, ":::"}, nil
}

func (p *processor) tableCaptionBlock(line string, lineno int) ([]string, error) {
	m := tableCaptionLine.FindStringSubmatch(line)
	if m == nil {
		return nil, &Error{Line: lineno, Message: "![t:...] は表の見出し行です。後ろには参照用の {#名前} だけを書けます（画像には ![f:...](...) を使ってください）"}
	}
	if !p.tableFollows() {
		return nil, &Error{Line: lineno, Message: "![t:...] の直後に表がありません（空行は1つまで、直後に表を書いてください）"}
	}

	opening := "::: {." + tableCaptionClass + "}"
	if id := m[2]; id != "" {
		p.registerID(id, lineno)
		opening = "::: {." + tableCaptionClass + " #" + id + "}"
	}
	block := []string{opening}
	if title := strip(m[1]); title != "" {
		block = append(block, title)
	}
	return append(block, ":::"), nil
}

// registerID は、参照用の名前（図表・数式の {#名前}）を記録する。
// 同じ名前が2回出てきたら警告する。
func (p *processor) registerID(id string, lineno int) {
	if first, ok := p.ids[id]; ok {
		p.warn(lineno, "図表・数式の名前 #%s は、%d 行目でも使われています（参照は最初のものを指します）", id, first)
		return
	}
	p.ids[id] = lineno
}

// tableFollows は、現在の行の直後（空行は1つまで）に、表が始まっているか。
func (p *processor) tableFollows() bool {
	at := func(i int) string {
		if i < len(p.lines) {
			return p.lines[i]
		}
		return ""
	}
	first := p.index + 1
	if first < len(p.lines) && strip(p.lines[first]) == "" {
		first++
	}
	if first >= len(p.lines) || strip(p.lines[first]) == "" {
		return false
	}
	row, next := p.lines[first], at(first+1)
	if gridBorderRow.MatchString(row) {
		return true
	}
	if strings.Contains(row, "|") && strings.Contains(next, "|") && pipeSeparatorRow.MatchString(next) {
		return true
	}
	return simpleSeparatorRow.MatchString(row) || simpleSeparatorRow.MatchString(next)
}

// --- 右揃え・中央揃え -----------------------------------------------------

type alignLineParts struct {
	kind    alignKind
	quote   string
	list    string
	content string
}

// parseAlign は、右揃え・中央揃えの行なら、その内容を返す。違えば nil。
func parseAlign(line string) *alignLineParts {
	m := alignLine.FindStringSubmatch(line)
	if m == nil {
		return nil
	}
	kind := alignRight
	if m[3] == "<->" {
		kind = alignCenter
	}
	return &alignLineParts{kind: kind, quote: m[1], list: m[2], content: m[4]}
}

// handleAlign は、同じ種類・同じ引用の接頭辞で連続する行を、ひとつのブロックにまとめる。
// 内容が空の行は読み飛ばす（ブロックは途切れない）。
// リスト記号つきの行は、記号ごとに別の項目なので、まとめずに単独で出力する。
func (p *processor) handleAlign(a *alignLineParts) {
	if a.list != "" {
		p.flushAlign()
		if a.content != "" {
			p.emitListAlign(a)
		}
		return
	}

	key := strings.ReplaceAll(a.quote, " ", "")
	if p.align != nil && p.align.kind == a.kind && p.align.key == key {
		if a.content != "" {
			p.align.lines = append(p.align.lines, a.content)
		}
		return
	}
	p.flushAlign()
	p.align = &alignBlock{kind: a.kind, quote: a.quote, key: key}
	if a.content != "" {
		p.align.lines = []string{a.content}
	}
}

func (p *processor) flushAlign() {
	if p.align == nil {
		return
	}
	if len(p.align.lines) > 0 {
		p.emitAlignBlock(p.align)
	}
	p.align = nil
}

// emitAlignBlock は、揃えのブロックを出力する。
// 引用の内側なら、接頭辞をすべての行に付け、空行も `>` にする。
func (p *processor) emitAlignBlock(b *alignBlock) {
	body := []string{"::: {." + alignClasses[b.kind] + "}"}
	for i, content := range b.lines {
		content = protectListLike(content)
		if i < len(b.lines)-1 {
			content += `\` // 行ごとに改行する（Pandoc の hard_line_breaks 相当）
		}
		body = append(body, content)
	}
	body = append(body, ":::")
	for i := range body {
		body[i] = b.quote + body[i]
	}
	p.emitBlock(body, rstrip(b.quote))
}

// emitListAlign は、リスト項目の中の揃えを出力する。Div の開始行をリスト記号と
// 同じ行に置き、続く行を記号の幅だけ字下げする。前後に空行は入れない（リストが緩くなるため）。
func (p *processor) emitListAlign(a *alignLineParts) {
	indent := a.quote + strings.Repeat(" ", len(a.list))
	p.output = append(p.output,
		a.quote+a.list+"::: {."+alignClasses[a.kind]+"}",
		indent+protectListLike(a.content),
		indent+":::")
	p.afterGenerated = false
	p.inList = true
}

// protectListLike は、「2026. 10. 12」のような日付が番号付きリストと解釈されないようにする。
func protectListLike(content string) string {
	return listLikeStart.ReplaceAllString(content, `$1\$2$3`)
}

// --- 出力 -----------------------------------------------------------------

// emit は通常の行を出力する。生成ブロックの直後の空行は、重複するので捨てる。
func (p *processor) emit(line string) {
	if p.afterGenerated && strip(line) == "" {
		p.afterGenerated = false
		return
	}
	p.afterGenerated = false
	p.output = append(p.output, line)
}

// emitBlock は、生成したブロックを、前後に空行を補って出力する。
// blank は空行として使う文字列（引用の内側なら ">"）。
func (p *processor) emitBlock(block []string, blank string) {
	p.inList = false
	if n := len(p.output); n > 0 {
		last := strip(p.output[n-1])
		if last != "" && last != strip(blank) {
			p.output = append(p.output, blank)
		}
	}
	p.output = append(p.output, block...)
	p.output = append(p.output, blank)
	p.afterGenerated = true
}

// --- 終了処理 -------------------------------------------------------------

func (p *processor) finish() error {
	p.flushAlign()
	switch p.state {
	case stateFrontMatter:
		return &Error{Line: p.regionStart, Message: "YAMLフロントマターが閉じられていません（--- または ... が必要です）"}
	case stateMath:
		return &Error{Line: p.regionStart, Message: "数式ブロックが閉じられていません（$$ が必要です）"}
	case stateFence:
		p.warn(p.regionStart, "コードブロックが閉じられていません（ファイル末尾までコードとして扱います）")
	}
	// 生成ブロックが最後なら、末尾に余分な空行を残さない
	if n := len(p.output); p.afterGenerated && n > 0 && strings.Trim(p.output[n-1], "> ") == "" {
		p.output = p.output[:n-1]
	}
	return nil
}
