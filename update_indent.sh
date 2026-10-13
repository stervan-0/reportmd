#!/usr/bin/env bash
set -e
cat > lib/reportmd/preprocessor.rb <<'REPORTMD_EOF'
# frozen_string_literal: true

module Reportmd
  # 前処理で見つかったエラー（独自構文の不正、終了のない数式ブロックなど）。
  # line には、元の入力ファイルでの行番号（1始まり）が入る。
  class PreprocessError < StandardError
    attr_reader :line

    def initialize(message, line: nil)
      super(message)
      @line = line
    end
  end

  # 前処理で見つかった警告（処理は続けられるもの）。
  PreprocessWarning = Struct.new(:line, :message)

  # .rmd のテキストを読み、独自構文を Pandoc が理解できる形式へ変換する。
  #
  # 現在の対応:
  #   - 保護領域の判定（フロントマター、コードブロック、数式ブロック）
  #   - 改ページ（行だけの ^）
  #   - 右揃え（--> ）と中央揃え（<-> ）
  #   - 番号付き見出し（#1 #2 #3）
  #   - 図（![f:タイトル](画像)）と表の見出し（![t:タイトル]）
  #   - 2スペースで始まる段落の字下げ
  #
  # 保護領域の内側は一切変更しない。
  class Preprocessor
    Result = Struct.new(:text, :warnings)

    PAGE_BREAK_LINE   = /\A\^[ \t]*\z/
    FENCE_OPEN_LINE   = /\A[ ]*(`{3,}|~{3,})(.*)\z/
    FRONT_MATTER_END  = /\A(---|\.\.\.)[ \t]*\z/
    FRONT_MATTER_OPEN = /\A---[ \t]*\z/

    # 右揃え・中央揃えの行。行頭（または引用 > ・リスト記号の直後）に、
    # 記号と半角スペース1個以上、続けて内容が来る。内容が空の行も一致する。
    #   quote   : 引用の接頭辞（例："> "）
    #   list    : リスト記号（例："- "、"1. "）
    #   marker  : "-->"（右揃え）または "<->"（中央揃え）
    ALIGN_LINE = /\A(?<quote>(?:[ ]{0,3}>[ ]?)*)(?<list>[ ]{0,3}(?:[-*+]|\d{1,9}[.)])[ ]+)?(?<marker>-->|<->)(?:[ ]+(?<content>.*?))?[ \t]*\z/
    ALIGN_KINDS = { '-->' => :right, '<->' => :center }.freeze
    ALIGN_CLASSES = { right: 'reportmd-right', center: 'reportmd-center' }.freeze

    # 内容の先頭が「2026. 」のような番号付きリスト記法に見える場合に備える
    LIST_LIKE_START = /\A(\d+)([.)])(?=[ \t]|\z)/

    PAGE_BREAK_BLOCK = ['::: {.reportmd-pagebreak}', ':::'].freeze

    # 番号付き見出し。行頭（0桁目）に # と半角数字1桁、半角スペース、見出し文字列が来る。
    # 数字が 1〜3 なら見出しにし、それ以外（#0、#4〜#9）は警告して、そのまま通す。
    # 見出し文字列が空（空白だけ）の場合も警告して、そのまま通す。
    NUMBERED_HEADING_LINE = /\A\#(?<level>\d)(?:[ ]+(?<text>\S.*?))?[ \t]*\z/
    NUMBERED_HEADING_WITH_SPACE = /\A\#\d[ ]/
    MAX_HEADING_LEVEL = 3
    HEADING_CLASS = 'reportmd-num'

    # 図表。行頭に ![f ... または ![t ... が来る。区切りは半角コロンのみ。
    #   図 : ![f:タイトル](画像のパス)   ![f](...)   ![f:](...)
    #   表 : ![t:タイトル]               ![t]        ![t:]      （直後に表を置く）
    FIGURE_START = /\A!\[f(?::|\])/
    TABLE_START = /\A!\[t(?::|\])/
    FULLWIDTH_COLON_START = /\A!\[[ft]：/
    TABLE_CAPTION_LINE = /\A!\[t(?::(?<title>.*))?\][ \t]*\z/
    # 段落の字下げ。段落の最初の行が、ちょうど半角スペース2個で始まる場合、
    # 先頭に空のスパン（目印）を置く。字下げの組版は filter.lua が行う。
    #   "  本文"  ->  "[]{.reportmd-indent}本文"
    INDENT_LINE = /\A[ ]{2}(?<text>\S.*)\z/
    INDENT_MARKER = '[]{.reportmd-indent}'
    # リスト項目の行（記号のあとにスペース）。リスト項目の続きの段落と区別するために使う。
    LIST_ITEM_LINE = /\A[ ]{0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|\z)/
    # 2スペースのあとに、ほかのブロックの記法が来る行は、字下げの段落にしない
    # （リスト、見出し、引用、コード、数式、表、脚注、水平線など）
    BLOCK_START_AFTER_INDENT = /\A(?:[-*+](?:[ \t]|\z)|\d{1,9}[.)](?:[ \t]|\z)|\#{1,6}(?:[ \t]|\z)|>|`{3,}|~{3,}|\$\$|\||\+[-=:]|:::|\[\^[^\]]+\]:|([-*_])(?:[ \t]*\1){2,}[ \t]*\z)/

    FIGURE_CLASS = 'reportmd-figure'
    TABLE_CAPTION_CLASS = 'reportmd-table-caption'

    # 表の直後の行の判定（パイプ表・グリッド表・単純表）
    PIPE_SEPARATOR_ROW = /\A[ ]{0,3}\|?[ ]*:?-+:?[ ]*(?:\|[ ]*:?-+:?[ ]*)*\|?[ ]*\z/
    GRID_BORDER_ROW = /\A[ ]{0,3}\+[-=:]+(?:\+[-=:]+)*\+[ ]*\z/
    SIMPLE_SEPARATOR_ROW = /\A[ ]{0,3}-+(?:[ ]+-+)+[ ]*\z/

    def initialize(source)
      @source = normalize(source)
    end

    # @return [Result] 変換後のテキストと警告の一覧
    def call
      @warnings = []
      @output = []
      @state = :normal
      @after_generated = false
      @align = nil
      @last_heading_level = 0
      @in_list = false
      @last_line_blank = true # ファイルの先頭は、空行のあとと同じに扱う

      lines = split_lines(@source)
      @lines = lines
      lines.each_with_index do |line, index|
        @index = index
        process_line(line, index + 1, lines, index)
        @last_line_blank = line.strip.empty?
      end
      finish

      Result.new(build_text, @warnings)
    end

    private

    # --- 前準備 -------------------------------------------------------

    # UTF-8 の確認、BOM の除去、改行コードを LF に統一する。
    def normalize(source)
      text = source.dup.force_encoding(Encoding::UTF_8)
      raise PreprocessError, '入力がUTF-8として読み込めません' unless text.valid_encoding?

      text.sub(/\A\uFEFF/, '').gsub(/\r\n?/, "\n")
    end

    def split_lines(text)
      lines = text.split("\n", -1)
      lines.pop if lines.last == '' # 末尾の改行で生じる空要素
      lines
    end

    # --- 行ごとの処理（状態機械）---------------------------------------

    def process_line(line, lineno, lines, index)
      if index.zero? && front_matter_start?(lines)
        @state = :front_matter
        @region_start = lineno
        @output << line
        return
      end

      case @state
      when :front_matter then in_front_matter(line)
      when :fence        then in_fence(line)
      when :math         then in_math(line)
      else                    in_normal(line, lineno)
      end
    end

    # ファイル先頭が `---` で、次の行が空でなければフロントマター。
    # （次が空行なら水平線として扱う。Pandoc と同じ判定）
    def front_matter_start?(lines)
      return false unless lines[0] =~ FRONT_MATTER_OPEN

      !lines[1].nil? && !lines[1].strip.empty?
    end

    def in_front_matter(line)
      @output << line
      @state = :normal if line =~ FRONT_MATTER_END
    end

    def in_fence(line)
      @output << line
      @state = :normal if fence_close?(line)
    end

    def in_math(line)
      @output << line
      @state = :normal if line.include?('$$')
    end

    def in_normal(line, lineno)
      if (align = align_line(line))
        handle_align(align)
        return
      end

      # 右揃え・中央揃えの行が途切れたので、溜めていたブロックを出力する
      flush_align

      if (heading = numbered_heading(line, lineno))
        emit_block([heading])
      elsif (block = figure_table_block(line, lineno))
        emit_block(block)
      elsif (fence = fence_open(line))
        @state = :fence
        @fence_char, @fence_len = fence
        @region_start = lineno
        @in_list = false
        emit(line)
      elsif math_open?(line)
        @state = :math
        @region_start = lineno
        @in_list = false
        emit(line)
      elsif line =~ PAGE_BREAK_LINE
        emit_block(PAGE_BREAK_BLOCK)
      elsif (indented = indented_paragraph(line))
        emit(indented)
      else
        track_list(line)
        emit(line)
      end
    end

    # --- 段落の字下げ ---------------------------------------------------

    # 字下げの段落の最初の行なら、目印をつけた行を返す。違えば nil。
    # 次の場合は字下げの段落にしない（行はそのまま通す）。
    #   - 直前が空行ではない（段落の途中の行）
    #   - リスト項目の続きの段落（リストの中）
    #   - 2スペースのあとに、ほかのブロックの記法が来る
    def indented_paragraph(line)
      match = INDENT_LINE.match(line)
      return nil unless match
      return nil unless paragraph_start?
      return nil if @in_list
      return nil if match[:text].match?(BLOCK_START_AFTER_INDENT)

      "#{INDENT_MARKER}#{match[:text]}"
    end

    # 段落の先頭か（出力の直前が空行か、まだ何も出力していない）
    def paragraph_start?
      @output.empty? || @output.last.strip.empty? || @output.last.match?(/\A\#{1,6}[ \t]/)
    end

    # リストの中にいるかを追う。リスト項目の行で始まり、字下げされた行や
    # 空行は続きとして扱い、空行のあとの、字下げのない行で終わる。
    def track_list(line)
      return if line.strip.empty?

      if line.match?(LIST_ITEM_LINE)
        @in_list = true
      elsif line.match?(/\A[ \t]/)
        nil # 字下げされた行は、リスト項目の続き（状態は変えない）
      elsif @last_line_blank
        @in_list = false
      end
    end

    # --- 保護領域の判定 -------------------------------------------------

    # 開きフェンスなら [文字, 長さ] を返す。違えば nil。
    def fence_open(line)
      match = FENCE_OPEN_LINE.match(line)
      return nil unless match

      marker = match[1]
      # バッククォートのフェンスは、情報文字列に ` を含められない
      return nil if marker.start_with?('`') && match[2].include?('`')

      [marker[0], marker.length]
    end

    # 同じ文字で、開きフェンス以上の長さだけが並ぶ行が閉じフェンス。
    def fence_close?(line)
      stripped = line.strip
      stripped.length >= @fence_len && stripped.each_char.all? { |ch| ch == @fence_char }
    end

    # 行頭が $$ で、その行で閉じていなければ数式ブロックの開始。
    def math_open?(line)
      return false unless line.lstrip.start_with?('$$')

      line.scan('$$').length.odd?
    end

    # --- 番号付き見出し -------------------------------------------------

    # 番号付き見出しの行なら、Pandoc の見出し（クラス付き）の文字列を返す。
    # 見出しにならない行は nil を返す（必要なら警告を記録する）。
    #   #1 はじめに  ->  # はじめに {.reportmd-num}
    #   #2 背景      ->  ## 背景 {.reportmd-num}
    def numbered_heading(line, lineno)
      return nil unless line.match?(NUMBERED_HEADING_WITH_SPACE) || line.match?(/\A\#\d[ \t]*\z/)

      match = NUMBERED_HEADING_LINE.match(line)
      return nil unless match

      level = match[:level].to_i
      if level < 1 || level > MAX_HEADING_LEVEL
        @warnings << PreprocessWarning.new(
          lineno, "未対応の見出しレベルです（##{level} は使えません。#1〜#3 を使ってください）。通常の段落として扱います"
        )
        return nil
      end
      if match[:text].nil?
        @warnings << PreprocessWarning.new(lineno, "見出しの文字列がありません（##{level}）。通常の段落として扱います")
        return nil
      end

      warn_if_level_skipped(level, lineno)
      @last_heading_level = level
      "#{'#' * level} #{match[:text]} {.#{HEADING_CLASS}}"
    end

    def warn_if_level_skipped(level, lineno)
      return if level <= @last_heading_level + 1

      before = @last_heading_level.zero? ? '見出しがない状態' : "##{@last_heading_level}"
      @warnings << PreprocessWarning.new(lineno, "見出しレベルが飛んでいます（#{before} の次に ##{level}）")
    end

    # --- 図と表 ---------------------------------------------------------

    # 図・表の行なら、Pandoc のブロック（行の配列）を返す。違えば nil。
    #   ![f:タイトル](画像)  ->  ::: {.reportmd-figure}
    #                            ![タイトル](画像)
    #                            :::
    #   ![t:タイトル]        ->  ::: {.reportmd-table-caption}
    #                            タイトル
    #                            :::
    # 番号とキャプションの組版は filter.lua が行う。
    def figure_table_block(line, lineno)
      if line.match?(FULLWIDTH_COLON_START)
        @warnings << PreprocessWarning.new(
          lineno, '図表の記法の区切りは半角コロン : を使ってください（全角コロン：は図表として扱いません）'
        )
        return nil
      end
      return figure_block(line, lineno) if line.match?(FIGURE_START)
      return table_caption_block(line, lineno) if line.match?(TABLE_START)

      nil
    end

    def figure_block(line, lineno)
      unless line.include?('](')
        raise PreprocessError.new('図には画像のパスが必要です（例: ![f:タイトル](images/a.png)）', line: lineno)
      end

      image = line.sub(/\A!\[f:?/, '![').rstrip
      ["::: {.#{FIGURE_CLASS}}", image, ':::']
    end

    def table_caption_block(line, lineno)
      match = TABLE_CAPTION_LINE.match(line)
      unless match
        raise PreprocessError.new(
          '![t:...] は表の見出し行です。後ろに (...) などは付けられません（画像には ![f:...](...) を使ってください）',
          line: lineno
        )
      end
      unless table_follows?
        raise PreprocessError.new('![t:...] の直後に表がありません（空行は1つまで、直後に表を書いてください）',
                                  line: lineno)
      end

      title = match[:title].to_s.strip
      ["::: {.#{TABLE_CAPTION_CLASS}}", *(title.empty? ? [] : [title]), ':::']
    end

    # 現在の行の直後（空行は1つまで）に、表が始まっているか。
    def table_follows?
      first_index = @index + 1
      first_index += 1 if @lines[first_index] && @lines[first_index].strip.empty?
      first = @lines[first_index]
      return false if first.nil? || first.strip.empty?

      second = @lines[first_index + 1].to_s
      return true if first.match?(GRID_BORDER_ROW)
      return true if first.include?('|') && second.include?('|') && second.match?(PIPE_SEPARATOR_ROW)

      first.match?(SIMPLE_SEPARATOR_ROW) || second.match?(SIMPLE_SEPARATOR_ROW)
    end

    # --- 右揃え・中央揃え -----------------------------------------------

    AlignLine = Struct.new(:kind, :quote, :list, :content)

    # 右揃え・中央揃えの行なら AlignLine を返す。違えば nil。
    def align_line(line)
      match = ALIGN_LINE.match(line)
      return nil unless match

      AlignLine.new(ALIGN_KINDS.fetch(match[:marker]), match[:quote].to_s,
                    match[:list].to_s, match[:content].to_s)
    end

    # 同じ種類・同じ引用の接頭辞で連続する行を、ひとつのブロックにまとめる。
    # 内容が空の行は読み飛ばす（ブロックは途切れない）。
    # リスト記号つきの行は、記号ごとに別の項目なので、まとめずに単独で出力する。
    def handle_align(align)
      unless align.list.empty?
        flush_align
        emit_list_align(align) unless align.content.empty?
        return
      end

      if @align && @align[:kind] == align.kind && @align[:key] == quote_key(align.quote)
        @align[:lines] << align.content unless align.content.empty?
      else
        flush_align
        @align = { kind: align.kind, quote: align.quote, key: quote_key(align.quote),
                   lines: align.content.empty? ? [] : [align.content] }
      end
    end

    def quote_key(quote)
      quote.delete(' ')
    end

    def flush_align
      return unless @align

      emit_align_block(@align) unless @align[:lines].empty?
      @align = nil
    end

    # 引用の内側なら、接頭辞をすべての行に付け、空行も `>` にする。
    def emit_align_block(block)
      quote = block[:quote]
      lines = block[:lines].map { |content| protect_list_like(content) }
      lines = lines.each_with_index.map { |content, i| i < lines.length - 1 ? "#{content}\\" : content }
      body = ["::: {.#{ALIGN_CLASSES.fetch(block[:kind])}}", *lines, ':::']
      emit_block(body.map { |l| "#{quote}#{l}" }, blank: quote.rstrip)
    end

    # リスト項目の中では、Div の開始行をリスト記号と同じ行に置き、
    # 続く行を記号の幅だけ字下げする。前後に空行は入れない（リストが緩くなるため）。
    def emit_list_align(align)
      indent = "#{align.quote}#{' ' * align.list.length}"
      @output << "#{align.quote}#{align.list}::: {.#{ALIGN_CLASSES.fetch(align.kind)}}"
      @output << "#{indent}#{protect_list_like(align.content)}"
      @output << "#{indent}:::"
      @after_generated = false
      @in_list = true
    end

    # 「2026. 10. 12」のように、日付などが番号付きリストと解釈されないようにする。
    def protect_list_like(content)
      content.sub(LIST_LIKE_START, '\1\\\\\2')
    end

    # --- 出力 -----------------------------------------------------------

    # 通常の行を出力する。生成ブロックの直後の空行は、重複するので捨てる。
    def emit(line)
      if @after_generated && line.strip.empty?
        @after_generated = false
        return
      end
      @after_generated = false
      @output << line
    end

    # 生成したブロックを、前後に空行を補って出力する。
    # blank は空行として使う文字列（引用の内側なら ">"）。
    def emit_block(block_lines, blank: '')
      @in_list = false
      last = @output.last
      @output << blank unless last.nil? || last.strip.empty? || last.strip == blank.strip
      @output.concat(block_lines)
      @output << blank
      @after_generated = true
    end

    # --- 終了処理 -------------------------------------------------------

    def finish
      flush_align
      case @state
      when :front_matter
        raise PreprocessError.new('YAMLフロントマターが閉じられていません（--- または ... が必要です）',
                                  line: @region_start)
      when :math
        raise PreprocessError.new('数式ブロックが閉じられていません（$$ が必要です）', line: @region_start)
      when :fence
        @warnings << PreprocessWarning.new(@region_start,
                                           'コードブロックが閉じられていません（ファイル末尾までコードとして扱います）')
      end
      # 生成ブロックが最後なら、末尾に余分な空行を残さない
      @output.pop if @after_generated && @output.last.to_s.delete('> ').empty?
    end

    def build_text
      @output.empty? ? '' : "#{@output.join("\n")}\n"
    end
  end
end
REPORTMD_EOF
cat > lib/reportmd/filter.lua <<'REPORTMD_EOF'
-- reportmd 用 Pandoc Lua フィルタ
--
-- 前処理(preprocessor.rb)が出力した「クラス付きのブロック」を、
-- 出力形式ごとの組版に変換する。
--
-- 現在の対応:
--   .reportmd-pagebreak       ->  \newpage
--   .reportmd-right           ->  右揃え（flushright）
--   .reportmd-center          ->  中央揃え（center）
--   .reportmd-figure          ->  図（番号とキャプションを付ける）
--   .reportmd-table-caption   ->  直後の表に、番号とキャプションを付ける
--   2 スペース始まりの段落   ->  字下げ 1 文字分（paragraph_indent の置き換え）
--   見出し                    ->  #1〜#3（.reportmd-num）は番号付き、
--                                 標準の #（クラスなし）は番号なしにする
--   title / author            ->  PDF のメタデータにだけ使い、本文には出さない
--
-- 設定（builder.rb が metadata の reportmd に入れて渡す）:
--   figure_label / table_label       図・表のラベル文字列（既定：図・表）
--   figure_position / table_position キャプションの位置 top / bottom

local function has_class(el, name)
  for _, class in ipairs(el.classes) do
    if class == name then
      return true
    end
  end
  return false
end

local function warn(message)
  io.stderr:write('reportmd(filter): warning: ' .. message .. '\n')
end

-- ---------------------------------------------------------------------
-- 設定の読み込み（最初の走査）
-- ---------------------------------------------------------------------

local settings = {
  figure_label = '図',
  table_label = '表',
  figure_position = 'bottom',
  table_position = 'top',
}

local function read_settings(meta)
  local given = meta.reportmd
  if given == nil then
    return
  end
  for key, _ in pairs(settings) do
    if given[key] ~= nil then
      settings[key] = pandoc.utils.stringify(given[key])
    end
  end
end

-- ---------------------------------------------------------------------
-- タイトルと著者
-- ---------------------------------------------------------------------

-- メタデータの値を、書式を除いた文字列にする（著者が複数なら「, 」でつなぐ）
local function meta_to_string(value)
  if pandoc.utils.type(value) == 'List' then
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = pandoc.utils.stringify(item)
    end
    return table.concat(parts, ', ')
  end
  return pandoc.utils.stringify(value)
end

-- title / author をそのまま残すと、Pandoc が本文の先頭にタイトルを出力してしまう。
-- そこで、PDF のメタデータ用の title-meta / author-meta に移し替える。
local function move_to_pdf_metadata(meta, key)
  if meta[key] ~= nil then
    local meta_key = key .. '-meta'
    if meta[meta_key] == nil then
      meta[meta_key] = meta_to_string(meta[key])
    end
    meta[key] = nil
  end
end

local function move_title_and_author(meta)
  move_to_pdf_metadata(meta, 'title')
  move_to_pdf_metadata(meta, 'author')
  return meta
end

-- ---------------------------------------------------------------------
-- 改ページ・右揃え・中央揃え
-- ---------------------------------------------------------------------

local ALIGNMENTS = {
  ['reportmd-right']  = { latex = 'flushright', css = 'right' },
  ['reportmd-center'] = { latex = 'center',     css = 'center' },
}

local function alignment_of(el)
  for _, class in ipairs(el.classes) do
    if ALIGNMENTS[class] then
      return ALIGNMENTS[class]
    end
  end
  return nil
end

local function convert_div(el)
  if has_class(el, 'reportmd-pagebreak') then
    if FORMAT:match('latex') then
      return pandoc.RawBlock('latex', '\\newpage')
    end
    return {} -- LaTeX 以外の出力では、改ページブロックを取り除く
  end

  local align = alignment_of(el)
  if align then
    if FORMAT:match('latex') then
      local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{' .. align.latex .. '}') })
      blocks:extend(el.content)
      blocks:insert(pandoc.RawBlock('latex', '\\end{' .. align.latex .. '}'))
      return blocks
    elseif FORMAT:match('^html') then
      el.attributes['style'] = 'text-align: ' .. align.css .. ';'
      return el
    end
    return el.content -- そのほかの出力では、揃えずに内容だけを残す
  end
end

-- ---------------------------------------------------------------------
-- 見出しの番号
-- ---------------------------------------------------------------------

-- 前処理が #1〜#3 を「.reportmd-num」つきの見出しに変換している。
-- Pandoc を --number-sections で実行すると全ての見出しに番号が付くので、
-- 標準の見出し（.reportmd-num がないもの）に .unnumbered を付けて、番号なしにする。
local function convert_header(el)
  if has_class(el, 'reportmd-num') then
    return nil
  end
  if not has_class(el, 'unnumbered') then
    el.classes:insert('unnumbered')
    return el
  end
end

-- ---------------------------------------------------------------------
-- 図表の番号とキャプション
-- ---------------------------------------------------------------------

local counters = { figure = 0, table = 0 }

-- 「図1 タイトル」。タイトルがなければ番号だけ（「図1」）。
local function make_caption(label, number, title)
  local inlines = pandoc.List({ pandoc.Str(label .. number) })
  if #title > 0 then
    inlines:insert(pandoc.Space())
    inlines:extend(title)
  end
  return inlines
end

-- 図のブロック（Div）から、画像とタイトルを取り出す。画像だけの行でなければ nil。
local function figure_parts(div)
  if #div.content ~= 1 then
    return nil
  end
  local block = div.content[1]
  if block.t == 'Figure' then
    local inner = block.content
    if #inner == 1 and (inner[1].t == 'Plain' or inner[1].t == 'Para')
        and #inner[1].content == 1 and inner[1].content[1].t == 'Image' then
      return inner[1].content[1], pandoc.utils.blocks_to_inlines(block.caption.long)
    end
  elseif block.t == 'Para' or block.t == 'Plain' then
    if #block.content == 1 and block.content[1].t == 'Image' then
      return block.content[1], pandoc.List()
    end
  end
  return nil
end

-- LaTeX：浮動体（figure 環境）にせず、書いた位置に固定する。
-- 画像とキャプションが別のページに分かれないように、samepage で囲む。
local function latex_figure(image, caption, position)
  local picture = pandoc.Plain({ pandoc.Image({}, image.src, image.title, image.attr) })
  local text = pandoc.Plain(caption)
  local gap = pandoc.RawBlock('latex', '\\vspace{0.5\\baselineskip}')
  local blocks = pandoc.List({ pandoc.RawBlock('latex', '\\begin{samepage}\\begin{center}') })
  if position == 'top' then
    blocks:extend({ text, gap, picture })
  else
    blocks:extend({ picture, gap, text })
  end
  blocks:insert(pandoc.RawBlock('latex', '\\end{center}\\end{samepage}'))
  return blocks
end

local function convert_figure(div)
  local image, title = figure_parts(div)
  if image == nil then
    warn('図の行には、画像だけを書いてください（番号は付けません）')
    return div.content
  end

  counters.figure = counters.figure + 1
  local caption = make_caption(settings.figure_label, counters.figure, title)
  if FORMAT:match('latex') then
    return latex_figure(image, caption, settings.figure_position)
  end
  local plain_image = pandoc.Image({}, image.src, image.title, image.attr)
  local figure = pandoc.Figure({ pandoc.Plain({ plain_image }) }, { long = { pandoc.Plain(caption) } })
  return pandoc.List({ figure })
end

-- LaTeX：表のキャプションは、中央に置く。表との間で、ページが分かれないようにする。
local function latex_table(tbl, caption, position)
  local text = pandoc.Plain(caption)
  local caption_blocks = pandoc.List({
    pandoc.RawBlock('latex', '\\begin{center}'),
    text,
    pandoc.RawBlock('latex', '\\end{center}'),
  })
  local blocks = pandoc.List({})
  if position == 'bottom' then
    blocks:insert(tbl)
    blocks:extend(caption_blocks)
  else
    blocks:extend(caption_blocks)
    blocks:insert(pandoc.RawBlock('latex', '\\nopagebreak[4]'))
    blocks:insert(tbl)
  end
  return blocks
end

local function convert_table(caption_div, tbl)
  local title = pandoc.List()
  if #caption_div.content > 0 then
    title = pandoc.utils.blocks_to_inlines(caption_div.content)
  end
  counters.table = counters.table + 1
  local caption = make_caption(settings.table_label, counters.table, title)

  if FORMAT:match('latex') then
    tbl.caption.long = pandoc.Blocks({}) -- 表に付いていたキャプションは使わない
    tbl.caption.short = nil
    return latex_table(tbl, caption, settings.table_position)
  end
  tbl.caption.long = pandoc.Blocks({ pandoc.Plain(caption) })
  return tbl
end

-- ブロックの並びを先頭から見ていき、図・表の見出しを、番号つきの組版に置き換える。
local function convert_blocks(blocks)
  local result = pandoc.List({})
  local changed = false
  local i = 1
  while i <= #blocks do
    local block = blocks[i]
    if block.t == 'Div' and has_class(block, 'reportmd-figure') then
      result:extend(convert_figure(block))
      changed = true
    elseif block.t == 'Div' and has_class(block, 'reportmd-table-caption') then
      local following = blocks[i + 1]
      if following ~= nil and following.t == 'Table' then
        local converted = convert_table(block, following)
        if converted.t then
          result:insert(converted)
        else
          result:extend(converted)
        end
        i = i + 1
      else
        warn('表の見出し ![t:...] の直後に、表が見つかりませんでした（番号は付けません）')
      end
      changed = true
    else
      result:insert(block)
    end
    i = i + 1
  end
  if changed then
    return result
  end
end

-- 先頭の 2 スペース（前処理が []{.reportmd-indent} にしたもの）を、
-- 字下げ 1 文字分の段落に変換する。paragraph_indent は使わない（置き換え）。
local function convert_para(para)
  local first = para.content[1]
  if first == nil or first.t ~= 'Span' or not has_class(first, 'reportmd-indent') then
    return nil
  end
  local content = pandoc.List(para.content)
  content:remove(1)
  if FORMAT:match('latex') then
    content:insert(1, pandoc.RawInline('latex', '\\noindent\\hspace*{\\reportmdchar}'))
  end
  return pandoc.Para(content)
end

-- 設定を読む走査を先に行い、そのあとで変換の走査を行う。
return {
  { Meta = function(meta) read_settings(meta) end },
  {
    Meta = move_title_and_author,
    Div = convert_div,
    Header = convert_header,
    Para = convert_para,
    Blocks = convert_blocks,
  },
}
REPORTMD_EOF
cat > lib/reportmd/preamble.tex.erb <<'REPORTMD_EOF'
% reportmd が生成した LaTeX のプリアンブル（設定ファイルの内容を反映）
\usepackage[<%= paper_option %>,top=<%= margin_top %>,bottom=<%= margin_bottom %>,left=<%= margin_left %>,right=<%= margin_right %>]{geometry}
\usepackage{xeCJK}
\setmainfont{<%= font_main %>}
\setCJKmainfont{<%= font_main %>}
\setmonofont{<%= font_mono %>}
\setCJKmonofont{<%= font_mono %>}
\usepackage{indentfirst}
\newlength{\reportmdchar}
\setlength{\reportmdchar}{<%= font_size_pt %>pt}
\setlength{\parindent}{<%= parindent_pt %>pt}
\linespread{<%= line_spacing %>}
\makeatletter
\renewcommand\normalsize{\@setfontsize\normalsize{<%= font_size_pt %>pt}{<%= baseline_pt %>pt}}
\makeatother
<% unless page_numbering -%>
\pagestyle{empty}
<% end -%>
% --- 見出し（レベル1〜3：section, subsection, subsubsection） ---
\newfontfamily\reportmdheadlatin{<%= heading_font %>}<%= heading_bold ? '[AutoFakeBold=2.5]' : '' %>
\newCJKfontfamily\reportmdheadcjk{<%= heading_font %>}<%= heading_bold ? '[AutoFakeBold=2.5]' : '' %>
\makeatletter
\newcommand{\reportmdheading}[2]{\reportmdheadlatin\reportmdheadcjk<%= heading_bold ? '\bfseries' : '' %>\fontsize{#1}{#2}\selectfont}
\renewcommand{\@seccntformat}[1]{\csname the#1\endcsname\hspace{1em}}
<% %w[section subsection subsubsection].each_with_index do |name, i| -%>
\renewcommand{\<%= name %>}{\@startsection{<%= name %>}{<%= i + 1 %>}{<%= heading_indents[i] %>pt}{<%= heading_before %>pt}{<%= heading_after %>pt}{\reportmdheading{<%= heading_sizes[i] %>pt}{<%= heading_leadings[i] %>pt}}}
<% end -%>
\makeatother
REPORTMD_EOF
cat > spec/preprocessor_spec.rb <<'REPORTMD_EOF'
# frozen_string_literal: true

require_relative '../lib/reportmd/preprocessor'

RSpec.describe Reportmd::Preprocessor do
  def run(source)
    described_class.new(source).call
  end

  def convert(source)
    run(source).text
  end

  PAGEBREAK = "::: {.reportmd-pagebreak}\n:::"

  describe '前準備' do
    it '変換対象のない文書は、そのまま出力する' do
      source = "# 見出し\n\n本文です。\n\n- 項目\n"
      expect(convert(source)).to eq(source)
    end

    it 'CRLF を LF に統一する' do
      expect(convert("a\r\nb\r\n")).to eq("a\nb\n")
    end

    it 'BOM を取り除く' do
      expect(convert("\uFEFFa\n")).to eq("a\n")
    end

    it '空の入力は空文字を返す' do
      expect(convert('')).to eq('')
    end

    it 'UTF-8 として不正な入力はエラーにする' do
      expect { run("\xFF\xFE".b) }.to raise_error(Reportmd::PreprocessError, /UTF-8/)
    end
  end

  describe '改ページ（^）' do
    it '行だけの ^ を改ページに変換する' do
      expect(convert("前\n\n^\n\n後\n")).to eq("前\n\n#{PAGEBREAK}\n\n後\n")
    end

    it '前後に空行がなくても、空行を補って変換する' do
      expect(convert("前\n^\n後\n")).to eq("前\n\n#{PAGEBREAK}\n\n後\n")
    end

    it 'ファイルの先頭・末尾の ^ も変換する' do
      expect(convert("^\n本文\n^\n")).to eq("#{PAGEBREAK}\n\n本文\n\n#{PAGEBREAK}\n")
    end

    it '行末の空白は許容する' do
      expect(convert("a\n\n^  \n\nb\n")).to eq("a\n\n#{PAGEBREAK}\n\nb\n")
    end

    it '連続した ^ はそれぞれ改ページにする' do
      expect(convert("a\n\n^\n^\n\nb\n")).to eq("a\n\n#{PAGEBREAK}\n\n#{PAGEBREAK}\n\nb\n")
    end

    it '文章中の ^ は変換しない' do
      source = "x^2 と 2^n\n\na ^ b\n\n^上付き^\n\n    ^\n"
      expect(convert(source)).to eq(source)
    end
  end

  describe '保護領域：コードブロック' do
    it 'バッククォートのコードブロック内の ^ は変換しない' do
      source = "```\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it 'チルダのコードブロック内の ^ は変換しない' do
      source = "~~~\n^\n~~~\n"
      expect(convert(source)).to eq(source)
    end

    it '情報文字列（言語名）つきのフェンスも保護する' do
      source = "```ruby\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロックを閉じたあとの ^ は変換する' do
      expect(convert("```\nコード\n```\n\n^\n")).to eq("```\nコード\n```\n\n#{PAGEBREAK}\n")
    end

    it '長いフェンスの内側にある短いフェンスでは閉じない' do
      source = "````\n```\n^\n```\n````\n"
      expect(convert(source)).to eq(source)
    end

    it '種類の違うフェンスでは閉じない' do
      source = "```\n~~~\n^\n```\n"
      expect(convert(source)).to eq(source)
    end

    it '開きフェンスより短いフェンスでは閉じない' do
      source = "````\n^\n```\n^\n````\n"
      expect(convert(source)).to eq(source)
    end

    it '情報文字列に ` を含む行はフェンスとみなさない' do
      expect(convert("``` a`b\n^\n")).to eq("``` a`b\n\n#{PAGEBREAK}\n")
    end

    it 'リスト内のようにインデントされたフェンスも保護する' do
      source = "- 項目\n\n    ```\n    ^\n    ```\n"
      expect(convert(source)).to eq(source)
    end

    it '閉じフェンスがなければ、末尾までコードとして扱い警告する' do
      result = run("```\n^\nまだコード\n")
      expect(result.text).to eq("```\n^\nまだコード\n")
      expect(result.warnings.map(&:line)).to eq([1])
      expect(result.warnings.first.message).to include('コードブロック')
    end
  end

  describe '保護領域：数式ブロック' do
    it '数式ブロック内の ^ 単独行は変換しない' do
      source = "$$\n^\n$$\n"
      expect(convert(source)).to eq(source)
    end

    it '開始行に式がある数式ブロックも保護する' do
      source = "$$ x = 1\n^\ny = 2 $$\n"
      expect(convert(source)).to eq(source)
    end

    it '1行で完結する $$ ... $$ は、後続の行に影響しない' do
      expect(convert("$$x^2$$\n\n^\n")).to eq("$$x^2$$\n\n#{PAGEBREAK}\n")
    end

    it '数式ブロックを閉じたあとの ^ は変換する' do
      expect(convert("$$\nx\n$$\n\n^\n")).to eq("$$\nx\n$$\n\n#{PAGEBREAK}\n")
    end

    it '閉じられていない数式ブロックは、開始行つきでエラーにする' do
      expect { run("本文\n\n$$\nx\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('数式ブロック')
      }
    end
  end

  describe '保護領域：YAMLフロントマター' do
    it 'フロントマター内の ^ は変換しない' do
      source = "---\ntitle: a\n^\n---\n\n本文\n"
      expect(convert(source)).to eq(source)
    end

    it '... で閉じるフロントマターも保護する' do
      source = "---\ntitle: a\n^\n...\n"
      expect(convert(source)).to eq(source)
    end

    it 'フロントマターのあとの ^ は変換する' do
      expect(convert("---\ntitle: a\n---\n\n^\n")).to eq("---\ntitle: a\n---\n\n#{PAGEBREAK}\n")
    end

    it '閉じられていないフロントマターはエラーにする' do
      expect { run("---\ntitle: a\n\n本文\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(1)
        expect(e.message).to include('フロントマター')
      }
    end

    it '先頭の --- の次が空行なら、水平線として扱いエラーにしない' do
      expect(convert("---\n\n^\n")).to eq("---\n\n#{PAGEBREAK}\n")
    end

    it 'ファイル先頭以外の --- はフロントマターとして扱わない' do
      source = "本文\n\n---\ntitle: a\n---\n"
      expect(convert(source)).to eq(source)
    end
  end

  describe '右揃え（-->）と中央揃え（<->）' do
    RIGHT  = '::: {.reportmd-right}'
    CENTER = '::: {.reportmd-center}'

    it '--> の行を右揃えのブロックに変換する' do
      expect(convert("前\n\n--> 2026年10月12日\n\n後\n"))
        .to eq("前\n\n#{RIGHT}\n2026年10月12日\n:::\n\n後\n")
    end

    it '<-> の行を中央揃えのブロックに変換する' do
      expect(convert("<-> 実験レポート\n")).to eq("#{CENTER}\n実験レポート\n:::\n")
    end

    it '連続する行をひとつのブロックにまとめ、行ごとに改行する' do
      expect(convert("--> 2026年10月12日\n--> 大阪工業大学\n--> 山田 太郎\n"))
        .to eq("#{RIGHT}\n2026年10月12日\\\n大阪工業大学\\\n山田 太郎\n:::\n")
    end

    it '空行で別のブロックに分かれる' do
      expect(convert("--> a\n\n--> b\n"))
        .to eq("#{RIGHT}\na\n:::\n\n#{RIGHT}\nb\n:::\n")
    end

    it '右揃えと中央揃えが隣り合う場合は、別のブロックにする' do
      expect(convert("--> a\n<-> b\n"))
        .to eq("#{RIGHT}\na\n:::\n\n#{CENTER}\nb\n:::\n")
    end

    it '前の段落に空行なしで続いても、新しいブロックを始める' do
      expect(convert("本文\n--> 右\n")).to eq("本文\n\n#{RIGHT}\n右\n:::\n")
    end

    it '内容が空の行は読み飛ばし、前後の行は同じブロックとして続ける' do
      expect(convert("--> a\n-->\n-->   \n--> b\n"))
        .to eq("#{RIGHT}\na\\\nb\n:::\n")
    end

    it '内容が空の行だけなら、その行を何も出力しない（前後の空行はそのまま残る）' do
      expect(convert("前\n\n-->\n\n後\n")).to eq("前\n\n\n後\n")
    end

    it '内容は Markdown のまま渡す（インライン書式）' do
      expect(convert("--> **太字**と$x^2$\n")).to eq("#{RIGHT}\n**太字**と$x^2$\n:::\n")
    end

    it '内容の末尾の空白は取り除く' do
      expect(convert("--> a  \n")).to eq("#{RIGHT}\na\n:::\n")
    end

    it '日付が番号付きリストと解釈されないように、ピリオドをエスケープする' do
      expect(convert("--> 2026. 10. 12\n")).to eq("#{RIGHT}\n2026\\. 10. 12\n:::\n")
    end

    it '文章中の --> や、記号の直後に文字が続く行は変換しない' do
      source = "a --> b\n\n-->text\n\n---> x\n\n    --> コード\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロック・数式ブロック・フロントマター内の --> は変換しない' do
      source = "```\n--> a\n```\n\n$$\n<-> b\n$$\n"
      expect(convert(source)).to eq(source)
      fm = "---\ntitle: a\n--> b\n---\n"
      expect(convert(fm)).to eq(fm)
    end

    it 'コードブロックの直前の揃え行も、ブロックとして出力する' do
      expect(convert("--> a\n```\ncode\n```\n"))
        .to eq("#{RIGHT}\na\n:::\n\n```\ncode\n```\n")
    end

    it 'ファイル末尾の揃え行も出力する（余分な空行は残さない）' do
      expect(convert("本文\n\n<-> 末尾")).to eq("本文\n\n#{CENTER}\n末尾\n:::\n")
    end

    describe '引用の内側' do
      it '接頭辞を保ち、空行は > にする' do
        expect(convert("> 引用\n> --> 右\n> --> 2行目\n"))
          .to eq("> 引用\n>\n> #{RIGHT}\n> 右\\\n> 2行目\n> :::\n")
      end

      it '引用の接頭辞が違う行とは、別のブロックにする' do
        expect(convert("> --> a\n--> b\n"))
          .to eq("> #{RIGHT}\n> a\n> :::\n>\n\n#{RIGHT}\nb\n:::\n")
      end
    end

    describe 'リストの内側' do
      it 'リスト記号の行に Div を置き、続く行を記号の幅だけ字下げする' do
        expect(convert("- 項目A\n- --> 右の項目\n- 項目C\n"))
          .to eq("- 項目A\n- #{RIGHT}\n  右の項目\n  :::\n- 項目C\n")
      end

      it '番号付きリストにも対応する' do
        expect(convert("1. <-> 中央\n")).to eq("1. #{CENTER}\n   中央\n   :::\n")
      end

      it 'リスト記号ごとに別の項目として出力する' do
        expect(convert("- --> a\n- --> b\n"))
          .to eq("- #{RIGHT}\n  a\n  :::\n- #{RIGHT}\n  b\n  :::\n")
      end

      it '内容が空のリスト項目は読み飛ばす' do
        expect(convert("- a\n- -->\n- b\n")).to eq("- a\n- b\n")
      end
    end
  end

  describe '番号付き見出し（#1〜#3）' do
    NUM = '{.reportmd-num}'

    it '#1〜#3 を、クラスつきの Pandoc の見出しに変換する' do
      expect(convert("#1 はじめに\n\n#2 背景\n\n#3 詳細\n"))
        .to eq("# はじめに #{NUM}\n\n## 背景 #{NUM}\n\n### 詳細 #{NUM}\n")
    end

    it '前後に空行がなくても、空行を補って見出しにする' do
      expect(convert("本文\n#1 はじめに\n本文2\n"))
        .to eq("本文\n\n# はじめに #{NUM}\n\n本文2\n")
    end

    it 'ファイルの先頭・末尾の見出しも変換する（末尾に余分な空行を残さない）' do
      expect(convert("#1 先頭\n本文\n#1 末尾")).to eq("# 先頭 #{NUM}\n\n本文\n\n# 末尾 #{NUM}\n")
    end

    it 'スペースが複数あっても、見出し文字列の前を詰める' do
      expect(convert("#1   はじめに\n")).to eq("# はじめに #{NUM}\n")
    end

    it '見出し文字列の末尾の空白は取り除く' do
      expect(convert("#1 はじめに  \n")).to eq("# はじめに #{NUM}\n")
    end

    it '見出し文字列の中のインライン書式や数式は、そのまま渡す' do
      expect(convert("#2 **太字**と$x^2$\n")).to eq("## **太字**と$x^2$ #{NUM}\n")
    end

    it '標準の # 見出しは、そのまま通す（番号なしの見出し）' do
      source = "# 番号なし\n\n## これも番号なし\n\n### これも\n"
      expect(convert(source)).to eq(source)
    end

    it '#1 の行に連続する見出しは、それぞれ見出しになる' do
      expect(convert("#1 a\n#2 b\n"))
        .to eq("# a #{NUM}\n\n## b #{NUM}\n")
    end

    describe '見出しにならない行' do
      it '#4 以降（と #0）は、警告して通常の段落として通す' do
        result = run("#4 未対応\n\n#0 x\n\n#9 y\n")
        expect(result.text).to eq("#4 未対応\n\n#0 x\n\n#9 y\n")
        expect(result.warnings.map(&:line)).to eq([1, 3, 5])
        expect(result.warnings.first.message).to include('#4')
      end

      it '見出し文字列が空なら、警告して通常の段落として通す' do
        result = run("#1\n\n#2   \n")
        expect(result.text).to eq("#1\n\n#2   \n")
        expect(result.warnings.map(&:line)).to eq([1, 3])
        expect(result.warnings.first.message).to include('見出しの文字列がありません')
      end

      it '#12 のように数字が2桁以上の行や、#タグ のような行は、警告せず通す' do
        source = "#12 foo\n\n#タグ\n\n#1つ目\n"
        result = run(source)
        expect(result.text).to eq(source)
        expect(result.warnings).to eq([])
      end

      it '行頭以外（字下げ・リスト・引用の内側）の #1 は変換しない' do
        source = " #1 字下げ\n\n- #1 リスト\n\n> #1 引用\n"
        result = run(source)
        expect(result.text).to eq(source)
        expect(result.warnings).to eq([])
      end

      it 'コードブロック・数式ブロック・フロントマター内の #1 は変換しない' do
        source = "```\n#1 コード\n```\n\n$$\n#1 数式\n$$\n"
        expect(convert(source)).to eq(source)
        front = "---\ntitle: a\n#1 b\n---\n"
        expect(convert(front)).to eq(front)
      end
    end

    describe 'レベルの飛び' do
      it '#1 の次に #3 が来たら警告するが、見出しにはする' do
        result = run("#1 a\n\n#3 b\n")
        expect(result.text).to eq("# a #{NUM}\n\n### b #{NUM}\n")
        expect(result.warnings.map(&:line)).to eq([3])
        expect(result.warnings.first.message).to include('#1 の次に #3')
      end

      it '最初の見出しが #1 でなければ警告する' do
        result = run("#2 a\n")
        expect(result.warnings.map(&:line)).to eq([1])
        expect(result.warnings.first.message).to include('見出しがない状態')
      end

      it '上のレベルに戻るのは、飛びではない' do
        expect(run("#1 a\n#2 b\n#3 c\n#1 d\n#2 e\n").warnings).to eq([])
      end

      it '同じレベルが続くのも、飛びではない' do
        expect(run("#1 a\n#1 b\n#2 c\n#2 d\n").warnings).to eq([])
      end
    end

    it '右揃えのブロックの直後の見出しも、正しく出力する' do
      expect(convert("--> 右\n#1 はじめに\n"))
        .to eq("::: {.reportmd-right}\n右\n:::\n\n# はじめに #{NUM}\n")
    end

    it '見出しの後の改ページも、正しく出力する' do
      expect(convert("#1 はじめに\n^\n本文\n"))
        .to eq("# はじめに #{NUM}\n\n::: {.reportmd-pagebreak}\n:::\n\n本文\n")
    end
  end

  describe '図（![f:...]）' do
    FIGURE = '::: {.reportmd-figure}'

    it '![f:タイトル](画像) を、図のブロックに変換し、画像の代替テキストをタイトルにする' do
      expect(convert("![f:システム構成図](images/a.png)\n"))
        .to eq("#{FIGURE}\n![システム構成図](images/a.png)\n:::\n")
    end

    it '画像の属性（{width=50%} など）はそのまま残す' do
      expect(convert("![f:図](a.png){width=50%}\n"))
        .to eq("#{FIGURE}\n![図](a.png){width=50%}\n:::\n")
    end

    it 'タイトルが空（![f] / ![f:]）なら、代替テキストを空にする' do
      expect(convert("![f](a.png)\n\n![f:](b.png)\n"))
        .to eq("#{FIGURE}\n![](a.png)\n:::\n\n#{FIGURE}\n![](b.png)\n:::\n")
    end

    it 'タイトルの中のインライン書式やコロンは、そのまま渡す' do
      expect(convert("![f:**太字**と$x^2$、比率 1:2](a.png)\n"))
        .to eq("#{FIGURE}\n![**太字**と$x^2$、比率 1:2](a.png)\n:::\n")
    end

    it '前後に空行がなくても、空行を補って変換する' do
      expect(convert("本文\n![f:図](a.png)\n続き\n"))
        .to eq("本文\n\n#{FIGURE}\n![図](a.png)\n:::\n\n続き\n")
    end

    it '行末の空白は取り除く' do
      expect(convert("![f:図](a.png)  \n")).to eq("#{FIGURE}\n![図](a.png)\n:::\n")
    end

    it '画像のパスがなければ、行番号つきでエラーにする' do
      expect { run("本文\n\n![f:パスなし]\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('画像のパス')
      }
    end

    it '全角コロンは図表として扱わず、警告してそのまま通す' do
      result = run("![f：全角](a.png)\n")
      expect(result.text).to eq("![f：全角](a.png)\n")
      expect(result.warnings.map(&:line)).to eq([1])
      expect(result.warnings.first.message).to include('半角コロン')
    end

    it '通常の画像（f: で始まらない）や、行の途中・リスト・引用の中の ![f: は変換しない' do
      source = "![図](a.png)\n\n本文 ![f:行中](a.png)\n\n- ![f:リスト](a.png)\n\n> ![f:引用](a.png)\n\n![fig:x](a.png)\n"
      result = run(source)
      expect(result.text).to eq(source)
      expect(result.warnings).to eq([])
    end

    it 'コードブロック・数式ブロック・フロントマター内の記法は変換しない' do
      source = "```\n![f:図](a.png)\n![t:表]\n```\n\n$$\n![f:図](a.png)\n$$\n"
      expect(convert(source)).to eq(source)
      front = "---\ntitle: a\n![f:図](a.png)\n---\n"
      expect(convert(front)).to eq(front)
    end

    it '右揃えのブロックの直後の図も、正しく出力する' do
      expect(convert("--> 右\n![f:図](a.png)\n"))
        .to eq("::: {.reportmd-right}\n右\n:::\n\n#{FIGURE}\n![図](a.png)\n:::\n")
    end
  end

  describe '表の見出し（![t:...]）' do
    CAPTION = '::: {.reportmd-table-caption}'
    TABLE = "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n"

    it '![t:タイトル] を、表の見出しのブロックに変換し、表はそのまま通す' do
      expect(convert("![t:実験結果]\n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it '見出し行と表の間に、空行が1つあってもよい' do
      expect(convert("![t:実験結果]\n\n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it 'タイトルが空（![t] / ![t:]）なら、中身のない見出しブロックにする' do
      expect(convert("![t]\n#{TABLE}\n![t:]\n#{TABLE}"))
        .to eq("#{CAPTION}\n:::\n\n#{TABLE}\n#{CAPTION}\n:::\n\n#{TABLE}")
    end

    it 'タイトルの中のインライン書式は、そのまま渡す' do
      expect(convert("![t:**太字**と$x^2$]\n#{TABLE}"))
        .to eq("#{CAPTION}\n**太字**と$x^2$\n:::\n\n#{TABLE}")
    end

    it '行末の空白があっても、見出しとして扱う' do
      expect(convert("![t:実験結果]  \n#{TABLE}"))
        .to eq("#{CAPTION}\n実験結果\n:::\n\n#{TABLE}")
    end

    it '先頭の | がないパイプ表の前でも使える' do
      table = "条件 | 結果\n-----|-----\nA | 10\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it 'グリッド表の前でも使える' do
      table = "+---+---+\n| a | b |\n+---+---+\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it '単純な表（ハイフンの区切り行）の前でも使える' do
      table = "条件  結果\n----  ----\nA     10\n"
      expect(convert("![t:表]\n#{table}")).to eq("#{CAPTION}\n表\n:::\n\n#{table}")
    end

    it '直後に表がなければ、見出し行の行番号つきでエラーにする' do
      expect { run("本文\n\n![t:なし]\n\n本文\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(3)
        expect(e.message).to include('直後に表がありません')
      }
    end

    it '空行が2つ以上あれば、エラーにする' do
      expect { run("![t:x]\n\n\n#{TABLE}") }
        .to raise_error(Reportmd::PreprocessError, /直後に表がありません/)
    end

    it 'ファイルの末尾にある見出し行は、エラーにする' do
      expect { run("![t:x]") }.to raise_error(Reportmd::PreprocessError, /直後に表がありません/)
    end

    it '後ろに (...) がある行は、表の見出しではないのでエラーにして、図の記法を案内する' do
      expect { run("![t:x](a.png)\n") }.to raise_error(Reportmd::PreprocessError) { |e|
        expect(e.line).to eq(1)
        expect(e.message).to include('![f:')
      }
    end

    it '全角コロンは表の見出しとして扱わず、警告してそのまま通す' do
      result = run("![t：全角]\n#{TABLE}")
      expect(result.text).to eq("![t：全角]\n#{TABLE}")
      expect(result.warnings.map(&:line)).to eq([1])
    end

    it '図と表が混ざっていても、それぞれ変換する' do
      expect(convert("![f:図](a.png)\n\n![t:表]\n#{TABLE}"))
        .to eq("#{FIGURE}\n![図](a.png)\n:::\n\n#{CAPTION}\n表\n:::\n\n#{TABLE}")
    end
  end

  describe '2スペースの字下げ' do
    M = '[]{.reportmd-indent}'

    it '空行のあと・ファイル先頭の、2スペースで始まる段落に印を付ける' do
      expect(convert("  先頭\n\n  次の段落\n")).to eq("#{M}先頭\n\n#{M}次の段落\n")
    end

    it '段落の途中の行（継続行）は変換しない' do
      expect(convert("  a\n  b\n")).to eq("#{M}a\n  b\n")
    end

    it '見出し・改ページ・右揃えの直後の段落も字下げする' do
      source = "# 見出し\n  本文\n\n^\n  次\n\n--> 右\n\n  後\n"
      expect(convert(source)).to include("# 見出し\n#{M}本文")
      expect(convert(source)).to include("#{M}次").and include("#{M}後")
    end

    it '4スペース以上（コード）・1スペース・3スペースは変換しない' do
      source = "    コード\n\n 一つ\n\n   三つ\n"
      expect(convert(source)).to eq(source)
    end

    it 'リストの続き・引用の続きは変換しない' do
      source = "- 項目\n  続き\n\n  項目の2段落目\n\n> 引用\n  続き\n"
      expect(convert(source)).to eq(source)
    end

    it '2スペースのあとが、リスト・見出し・引用・表・水平線などの記法なら変換しない' do
      source = "  - 項目\n\n  # 見出し\n\n  > 引用\n\n  | a | b |\n\n  ---\n"
      expect(convert(source)).to eq(source)
    end

    it 'コードブロック・数式ブロックの中は変換しない' do
      source = "```\n  コード\n```\n\n$$\n  x\n$$\n"
      expect(convert(source)).to eq(source)
    end

    it '2スペースのあとが強調などの記号でも字下げする' do
      expect(convert("  *強調* 開始\n")).to eq("#{M}*強調* 開始\n")
    end
  end
end
REPORTMD_EOF
cat > spec/filter_spec.rb <<'REPORTMD_EOF'
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require_relative '../lib/reportmd/preprocessor'

# 前処理 → Pandoc（filter.lua）を通した結果を確認するテスト。
# Pandoc が入っていない環境では、このファイルのテストを飛ばす。
RSpec.describe 'filter.lua' do
  filter_path = File.expand_path('../lib/reportmd/filter.lua', __dir__)
  define_method(:filter_path) { filter_path }

  define_method(:pandoc_available?) do
    system('pandoc', '--version', out: File::NULL, err: File::NULL)
  end

  define_method(:convert_with_pandoc) do |rmd, format, extra_args = []|
    markdown = Reportmd::Preprocessor.new(rmd).call.text
    out, err, status = Open3.capture3(
      'pandoc', '-f', 'markdown-raw_html-raw_tex',
      "--lua-filter=#{filter_path}", '-t', format, *extra_args,
      stdin_data: markdown
    )
    raise "pandoc が失敗しました: #{err}" unless status.success?

    out
  end

  before { skip 'pandoc が見つかりません' unless pandoc_available? }

  describe '改ページ' do
    it 'LaTeX では \newpage になる' do
      latex = convert_with_pandoc("前のページ\n\n^\n\n次のページ\n", 'latex')
      expect(latex).to match(/前のページ\s+\\newpage\s+次のページ/)
    end

    it 'コードブロックや数式ブロック内の ^ は \newpage にならない' do
      latex = convert_with_pandoc("```\n^\n```\n\n$$\n^\n$$\n", 'latex')
      expect(latex).not_to include('\newpage')
    end

    it 'LaTeX 以外の出力では、改ページのブロックが残らない' do
      html = convert_with_pandoc("前\n\n^\n\n後\n", 'html')
      expect(html).not_to include('reportmd-pagebreak')
    end
  end

  describe 'タイトルと著者' do
    let(:source) { "---\ntitle: 実験レポート\nauthor: 山田 太郎\n---\n\n本文\n" }

    it 'PDF のメタデータにだけ使い、本文にタイトルを出力しない' do
      latex = convert_with_pandoc(source, 'latex', ['-s'])
      expect(latex).not_to include('\\maketitle')
      expect(latex).to include('pdftitle={実験レポート}')
      expect(latex).to include('pdfauthor={山田 太郎}')
    end

    it '著者が複数なら、メタデータでは「, 」でつなぐ' do
      multi = "---\nauthor:\n  - 山田 太郎\n  - 佐藤 花子\n---\n\n本文\n"
      latex = convert_with_pandoc(multi, 'latex', ['-s'])
      expect(latex).to include('pdfauthor={山田 太郎, 佐藤 花子}')
    end
  end

  describe '右揃え・中央揃え' do
    it 'LaTeX では flushright 環境になる' do
      latex = convert_with_pandoc("--> 2026年10月12日\n", 'latex')
      expect(latex).to match(/\\begin\{flushright\}\s+2026年10月12日\s+\\end\{flushright\}/)
    end

    it 'LaTeX では中央揃えが center 環境になる' do
      latex = convert_with_pandoc("<-> 実験レポート\n", 'latex')
      expect(latex).to match(/\\begin\{center\}\s+実験レポート\s+\\end\{center\}/)
    end

    it '複数行は、行ごとに改行される' do
      latex = convert_with_pandoc("--> a\n--> b\n", 'latex')
      expect(latex).to match(/a\\\\\s+b/)
    end

    it '内容のインライン書式が使える' do
      latex = convert_with_pandoc("--> **太字**と$x^2$\n", 'latex')
      expect(latex).to include('\\textbf{太字}')
      expect(latex).to include('\\(x^2\\)')
    end

    it '引用・リストの内側でも、環境が正しく入れ子になる' do
      latex = convert_with_pandoc("> 引用\n> --> 右\n\n- 項目\n- --> 右の項目\n", 'latex')
      expect(latex).to include('\\begin{quote}')
      expect(latex.scan('\\begin{flushright}').length).to eq(2)
      expect(latex.scan('\\end{flushright}').length).to eq(2)
    end

    it 'HTML では text-align のスタイルになる' do
      html = convert_with_pandoc("--> a\n", 'html')
      expect(html).to include('text-align: right;')
    end
  end

  describe '見出しの番号' do
    let(:numbered_args) { ['--number-sections'] }

    it '#1〜#3 の見出しは、番号つきの \\section 系になる' do
      latex = convert_with_pandoc("#1 a\n\n#2 b\n\n#3 c\n", 'latex', numbered_args)
      expect(latex).to match(/\\section\{a\}/)
      expect(latex).to match(/\\subsection\{b\}/)
      expect(latex).to match(/\\subsubsection\{c\}/)
      expect(latex).not_to include('section*')
    end

    it '標準の # 見出しは、番号なし（\\section*）になる' do
      latex = convert_with_pandoc("# a\n\n## b\n\n### c\n", 'latex', numbered_args)
      expect(latex).to include('\\section*{a}')
      expect(latex).to include('\\subsection*{b}')
      expect(latex).to include('\\subsubsection*{c}')
    end

    it '番号つきと番号なしを混ぜても、それぞれ正しく分かれる' do
      latex = convert_with_pandoc("#1 はじめに\n\n# 参考文献\n", 'latex', numbered_args)
      expect(latex).to match(/\\section\{はじめに\}/)
      expect(latex).to include('\\section*{参考文献}')
    end

    it '番号つきの見出しにも、reportmd-num のクラスは出力に残らない' do
      latex = convert_with_pandoc("#1 a\n", 'latex', numbered_args)
      expect(latex).not_to include('reportmd-num')
    end

    it '見出しの中のインライン書式が使える' do
      latex = convert_with_pandoc("#1 **太字**と$x^2$\n", 'latex', numbered_args)
      expect(latex).to include('\\textbf{太字}')
      expect(latex).to include('\\(x^2\\)')
    end
  end

  describe '図表の番号とキャプション' do
    let(:table) { "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n" }

    # 設定（metadata の reportmd）を渡して変換する
    def convert_with_settings(rmd, format, settings)
      Tempfile.create(['settings', '.json']) do |file|
        file.write(JSON.generate('reportmd' => settings))
        file.flush
        convert_with_pandoc(rmd, format, ["--metadata-file=#{file.path}"])
      end
    end

    describe 'HTML での確認（番号とタイトル）' do
      it '図は、出現順に 図1、図2 と採番する' do
        html = convert_with_pandoc("![f:一つ目](a.png)\n\n![f:二つ目](b.png)\n", 'html')
        expect(html).to match(%r{<figcaption[^>]*>図1 一つ目</figcaption>})
        expect(html).to match(%r{<figcaption[^>]*>図2 二つ目</figcaption>})
      end

      it '表は、図とは別の連番（表1、表2）で採番する' do
        rmd = "![f:図](a.png)\n\n![t:一つ目]\n#{table}\n![f:図](b.png)\n\n![t:二つ目]\n#{table}"
        html = convert_with_pandoc(rmd, 'html')
        expect(html).to include('<caption>表1 一つ目</caption>')
        expect(html).to include('<caption>表2 二つ目</caption>')
        expect(html).to match(%r{<figcaption[^>]*>図2 図</figcaption>})
      end

      it 'タイトルが空なら、番号だけを表示する' do
        html = convert_with_pandoc("![f](a.png)\n\n![t]\n#{table}", 'html')
        expect(html).to match(%r{<figcaption[^>]*>図1</figcaption>})
        expect(html).to include('<caption>表1</caption>')
      end

      it 'タイトルのインライン書式が使える' do
        html = convert_with_pandoc("![f:**太字**の図](a.png)\n\n![t:$x^2$ の表]\n#{table}", 'html')
        expect(html).to include('<strong>太字</strong>の図')
        expect(html).to match(/<caption>表1 .*<sup>2<\/sup>.*の表<\/caption>/m)
      end

      it '画像の属性（width）が残る' do
        html = convert_with_pandoc("![f:図](a.png){width=50%}\n", 'html')
        expect(html).to include('width:50')
      end

      it '番号を付けない通常の画像は、図として扱わない' do
        html = convert_with_pandoc("![図](a.png)\n", 'html')
        expect(html).not_to include('図1')
      end

      it '設定でラベルを変えられる' do
        html = convert_with_settings("![f:A](a.png)\n\n![t:B]\n#{table}", 'html',
                                     'figure_label' => 'Fig.', 'table_label' => 'Table')
        expect(html).to match(%r{<figcaption[^>]*>Fig\.1 A</figcaption>})
        expect(html).to include('<caption>Table1 B</caption>')
      end

      it '見出し用の Div は、出力に残らない' do
        html = convert_with_pandoc("![f:図](a.png)\n\n![t:表]\n#{table}", 'html')
        expect(html).not_to include('reportmd-')
      end
    end

    describe 'LaTeX での確認（固定配置・位置）' do
      it '図は浮動体（figure 環境）にせず、samepage と center で、書いた位置に置く' do
        latex = convert_with_pandoc("![f:システム構成図](a.png)\n", 'latex')
        expect(latex).not_to include('\\begin{figure}')
        expect(latex).not_to include('\\caption')
        expect(latex).to include('\\begin{samepage}\\begin{center}')
        expect(latex).to include('\\end{center}\\end{samepage}')
        expect(latex).to include('図1 システム構成図')
      end

      it '図のキャプションは、既定では画像の下（bottom）に置く' do
        latex = convert_with_pandoc("![f:図](a.png)\n", 'latex')
        expect(latex.index('\\includegraphics')).to be < latex.index('図1 図')
      end

      it 'figure_position が top なら、図のキャプションを画像の上に置く' do
        latex = convert_with_settings("![f:図](a.png)\n", 'latex', 'figure_position' => 'top')
        expect(latex.index('図1 図')).to be < latex.index('\\includegraphics')
      end

      it '表のキャプションは、既定では表の上（top）に置く' do
        latex = convert_with_pandoc("![t:実験結果]\n#{table}", 'latex')
        expect(latex).not_to include('\\caption')
        expect(latex.index('表1 実験結果')).to be < latex.index('\\begin{longtable}')
        expect(latex).to include('\\nopagebreak')
      end

      it 'table_position が bottom なら、表のキャプションを表の下に置く' do
        latex = convert_with_settings("![t:実験結果]\n#{table}", 'latex', 'table_position' => 'bottom')
        expect(latex.index('\\end{longtable}')).to be < latex.index('表1 実験結果')
      end

      it '画像の属性（width）が \\includegraphics に渡る' do
        latex = convert_with_pandoc("![f:図](a.png){width=50%}\n", 'latex')
        expect(latex).to match(/\\includegraphics\[[^\]]*width=0\.5\\textwidth/)
      end
    end

    describe '想定外の入力' do
      it '図の行に画像以外の文字があれば、警告して番号を付けず、内容は残す' do
        markdown = Reportmd::Preprocessor.new("![f:図](a.png) 説明\n").call.text
        out, err, status = Open3.capture3('pandoc', '-f', 'markdown-raw_html-raw_tex',
                                          "--lua-filter=#{filter_path}", '-t', 'html', stdin_data: markdown)
        expect(status.success?).to be(true)
        expect(err).to include('warning')
        expect(out).to include('説明')
        expect(out).not_to include('図1')
      end
    end
  end

  describe '2スペースの字下げ' do
    it 'LaTeX では、1文字分の字下げに変換する（印は残らない）' do
      out = convert_with_pandoc("  段落です\n", 'latex')
      expect(out).to include('\\noindent\\hspace*{\\reportmdchar}段落です')
      expect(out).not_to include('reportmd-indent')
    end

    it 'LaTeX 以外では、印を取り除くだけにする' do
      out = convert_with_pandoc("  段落です\n", 'plain')
      expect(out.strip).to eq('段落です')
    end

    it '印のない段落は、そのまま' do
      expect(convert_with_pandoc("段落です\n", 'latex').strip).to eq('段落です')
    end
  end
end
REPORTMD_EOF
cat > spec/cli_spec.rb <<'REPORTMD_EOF'
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'zlib'
require_relative '../lib/reportmd/cli'

RSpec.describe Reportmd::CLI do
  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    code = described_class.run(args, stdout: out, stderr: err)
    [code, out.string, err.string]
  end

  def write_file(name, text)
    path = File.join(@dir, name)
    File.write(path, text)
    path
  end

  # PDF まで作れる環境（Pandoc・XeLaTeX・xeCJK・設定の既定フォント）かどうか
  def pdf_build_ready?
    return false unless system('pandoc', '--version', out: File::NULL, err: File::NULL)
    return false unless system('xelatex', '--version', out: File::NULL, err: File::NULL)
    return false if `kpsewhich xeCJK.sty 2>/dev/null`.strip.empty?

    fonts = `fc-list : family 2>/dev/null`.downcase
    fonts.include?('ipaexmincho') && fonts.include?('ipaexgothic') && fonts.include?('noto sans mono cjk jp')
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe 'コマンドの振り分け' do
    it '--version でバージョンを表示し、0 を返す' do
      code, out, = run_cli('--version')
      expect(code).to eq(0)
      expect(out).to eq("reportmd #{Reportmd::VERSION}\n")
    end

    it '--help で使い方を表示し、0 を返す' do
      code, out, = run_cli('--help')
      expect(code).to eq(0)
      expect(out).to include('reportmd build')
    end

    it '引数がなければ使い方を表示し、1 を返す' do
      code, _out, err = run_cli
      expect(code).to eq(1)
      expect(err).to include('reportmd build')
    end

    it '不明なコマンドは 1 を返す' do
      code, _out, err = run_cli('foo')
      expect(code).to eq(1)
      expect(err).to include('不明なコマンド')
    end
  end

  describe 'build の入力チェック' do
    it '入力ファイルがなければ 1 を返す' do
      code, _out, err = run_cli('build')
      expect(code).to eq(1)
      expect(err).to include('入力ファイルを1つ指定')
    end

    it '存在しない入力ファイルは 1 を返す' do
      code, _out, err = run_cli('build', File.join(@dir, 'nothing.rmd'))
      expect(code).to eq(1)
      expect(err).to include('入力ファイルが見つかりません')
    end

    it '不明なオプションは 1 を返す' do
      input = write_file('a.rmd', "本文\n")
      code, _out, err = run_cli('build', input, '--foo')
      expect(code).to eq(1)
      expect(err).to include('--foo')
    end

    it '不正な設定は、項目名つきのエラーにして 1 を返す' do
      input = write_file('a.rmd', "本文\n")
      write_file('setting.json', '{ "text": { "font_size": "99pt" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('text.font_size')
    end

    it '独自構文のエラーは、ファイル名と行番号つきで表示する' do
      input = write_file('a.rmd', "本文\n\n$$\nx\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:3: error: 数式ブロック")
    end
  end

  describe 'PDF の生成' do
    before { skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready? }

    let(:source) { "# テスト\n\n1ページ目の本文です。\n\n^\n\n2ページ目の本文です。\n" }

    it '入力と同じ場所に、同名の PDF を出力する（2ページに分かれる）' do
      input = write_file('report.rmd', source)
      code, out, err = run_cli('build', input)
      expect(err).to eq('')
      expect(code).to eq(0)
      pdf = File.join(@dir, 'report.pdf')
      expect(out).to include(pdf)
      expect(File.binread(pdf, 4)).to eq('%PDF')
      if system('pdfinfo', '--help', out: File::NULL, err: File::NULL)
        expect(`pdfinfo #{pdf}`).to match(/Pages:\s+2/)
      end
    end

    it '-o で出力先を指定できる' do
      input = write_file('report.rmd', source)
      output = File.join(@dir, 'out.pdf')
      code, = run_cli('build', input, '-o', output)
      expect(code).to eq(0)
      expect(File.exist?(output)).to be(true)
    end

    it '出力先のディレクトリがなければ 1 を返す' do
      input = write_file('report.rmd', source)
      code, _out, err = run_cli('build', input, '-o', File.join(@dir, 'nothing', 'out.pdf'))
      expect(code).to eq(1)
      expect(err).to include('出力先のディレクトリがありません')
    end

    it '存在しないフォントを指定したら、フォント名を示して 1 を返す' do
      input = write_file('report.rmd', source)
      write_file('setting.json', '{ "font": { "main": "NoSuchFontXYZ" } }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('NoSuchFontXYZ')
    end

    it '未知の設定キーは警告するが、PDF は出力する' do
      input = write_file('report.rmd', source)
      write_file('setting.json', '{ "unknown_key": 1 }')
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include('warning')
      expect(File.exist?(File.join(@dir, 'report.pdf'))).to be(true)
    end

    it '--keep-temp で一時ファイルを残す' do
      input = write_file('report.rmd', source)
      code, _out, err = run_cli('build', input, '--keep-temp')
      expect(code).to eq(0)
      kept = err[/一時ファイルを残しました: (.+)$/, 1]
      expect(kept).not_to be_nil
      expect(File.exist?(File.join(kept, 'body.md'))).to be(true)
      FileUtils.rm_rf(kept)
    end

    it '日本語のフロントマターのタイトルが、PDF のメタデータに入る' do
      input = write_file('report.rmd', "---\ntitle: 実験レポート\n---\n\n本文\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)
      if system('pdfinfo', '--help', out: File::NULL, err: File::NULL)
        expect(`pdfinfo #{File.join(@dir, 'report.pdf')}`).to include('実験レポート')
      end
    end
  end

  describe 'PDF の生成（右揃え・中央揃えの位置）' do
    A4_WIDTH = 595.276
    MARGIN_25MM = 70.866

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    # PDF 内の単語ごとの位置 { 単語 => [xMin, xMax] } を取り出す
    def word_positions(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="[\d.]+" xMax="([\d.]+)" yMax="[\d.]+">(.*?)</word>}m)
          .to_h { |x_min, x_max, text| [text, [x_min.to_f, x_max.to_f]] }
    end

    it '右揃えは右余白の位置に、中央揃えはページの中央に配置される' do
      input = write_file('align.rmd', "<-> 実験レポート\n\n--> 大阪工業大学\n\n- 項目\n- --> 右の項目\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)

      words = word_positions(File.join(@dir, 'align.pdf'))
      center = words.fetch('実験レポート').sum / 2
      expect(center).to be_within(1.0).of(A4_WIDTH / 2)
      expect(words.fetch('大阪工業大学').last).to be_within(1.0).of(A4_WIDTH - MARGIN_25MM)
      expect(words.fetch('右の項目').last).to be_within(1.0).of(A4_WIDTH - MARGIN_25MM)
    end

    it '設定の余白を変えると、右揃えの位置も変わる' do
      input = write_file('align.rmd', "--> 大阪工業大学\n")
      write_file('setting.json', '{ "page": { "margin": { "right": "40mm" } } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      right_edge = word_positions(File.join(@dir, 'align.pdf')).fetch('大阪工業大学').last
      expect(right_edge).to be_within(1.0).of(A4_WIDTH - 40 * 72 / 25.4)
    end

    it '段落の1行目は、paragraph_indent の分だけ字下げされる（1字 = 10.5pt）' do
      input = write_file('align.rmd', "段落の本文です。\n")
      code, = run_cli('build', input)
      expect(code).to eq(0)

      left = word_positions(File.join(@dir, 'align.pdf')).fetch('段落の本文です。').first
      expect(left).to be_within(1.0).of(MARGIN_25MM + 10.5)
    end
  end

  describe 'PDF の生成（見出しの番号と字下げ）' do
    A4_WIDTH = 595.276 unless defined?(A4_WIDTH)
    MARGIN_25MM = 70.866 unless defined?(MARGIN_25MM)
    PT_PER_TEXPT = 0.99626 # TeX の 1pt は PDF 上では 0.99626 単位

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    # PDF 内の単語の { text:, x_min:, x_max:, height: } を、出現順に取り出す
    def words_in(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>}m)
          .map { |x0, y0, x1, y1, text| { text: text, x_min: x0.to_f, x_max: x1.to_f, height: y1.to_f - y0.to_f } }
    end

    def word(words, text)
      words.find { |w| w[:text] == text } || raise("PDF に #{text.inspect} が見つかりません")
    end

    let(:source) do
      "#1 はじめに\n\n本文\n\n#2 背景\n\n#3 詳細\n\n#2 目的\n\n#1 まとめ\n\n# 番号なし\n"
    end

    it '番号が 1、1.1、1.1.1、1.2、2 の順に付き、標準の # 見出しには付かない' do
      input = write_file('h.rmd', source)
      code, = run_cli('build', input)
      expect(code).to eq(0)

      text = `pdftotext -layout #{File.join(@dir, 'h.pdf')} -`.force_encoding('UTF-8')
      expect(text).to match(/^\s*1\s+はじめに/)
      expect(text).to match(/^\s*1\.1\s+背景/)
      expect(text).to match(/^\s*1\.1\.1\s+詳細/)
      expect(text).to match(/^\s*1\.2\s+目的/)
      expect(text).to match(/^\s*2\s+まとめ/)
      expect(text).to match(/^\s*番号なし\s*$/)
    end

    it '既定では、レベルに応じて 0字・1字・2字だけ字下げされる（番号なしの見出しも同じ）' do
      input = write_file('h.rmd', source)
      run_cli('build', input)
      words = words_in(File.join(@dir, 'h.pdf'))

      one_char = 10.5 * PT_PER_TEXPT
      expect(word(words, '1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
      expect(word(words, '1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM + one_char)
      expect(word(words, '1.1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM + one_char * 2)
      expect(word(words, '番号なし')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
    end

    it 'heading.indents の設定で字下げ量を変えられる' do
      write_file('setting.json', '{ "heading": { "indents": [0, 0, 0] } }')
      input = write_file('h.rmd', source)
      code, = run_cli('build', input)
      expect(code).to eq(0)

      words = words_in(File.join(@dir, 'h.pdf'))
      expect(word(words, '1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
      expect(word(words, '1.1.1')[:x_min]).to be_within(0.5).of(MARGIN_25MM)
    end

    it 'レベル1の見出しは、本文より大きい文字で組まれる（heading.sizes の設定で変わる）' do
      input = write_file('h.rmd', "#1 はじめに\n\n本文です。\n")
      run_cli('build', input)
      words = words_in(File.join(@dir, 'h.pdf'))
      default_ratio = word(words, 'はじめに')[:height] / word(words, '本文です。')[:height]
      expect(default_ratio).to be > 1.2

      write_file('setting.json', '{ "heading": { "sizes": ["20pt", "12pt", "10.5pt"] } }')
      run_cli('build', input)
      big_ratio = word(words_in(File.join(@dir, 'h.pdf')), 'はじめに')[:height] / word(words, '本文です。')[:height]
      expect(big_ratio).to be > default_ratio * 1.3
    end

    it 'heading.bold を false にすると、見出しの文字が細くなる' do
      skip 'pdftoppm がありません' unless system('pdftoppm', '-v', out: File::NULL, err: File::NULL)
      input = write_file('h.rmd', "#1 はじめに\n")
      run_cli('build', input)
      bold_size = render_ink(File.join(@dir, 'h.pdf'), 'bold')

      write_file('setting.json', '{ "heading": { "bold": false } }')
      run_cli('build', input)
      thin_size = render_ink(File.join(@dir, 'h.pdf'), 'thin')

      expect(bold_size).to be > thin_size * 1.15
    end

    # 1ページ目を PGM（白黒画像）にして、黒い部分の量（濃さの合計）を返す
    def render_ink(pdf, name)
      prefix = File.join(@dir, name)
      system('pdftoppm', '-r', '100', '-gray', '-f', '1', '-l', '1', pdf, prefix, exception: true)
      image = Dir.glob("#{prefix}*.pgm").first
      pixels = File.binread(image).unpack('C*')
      pixels.last(pixels.length - header_length(pixels)).sum { |v| 255 - v }
    end

    # PGM（P5）のヘッダ（形式・幅高さ・最大値の3行分）のバイト数
    def header_length(bytes)
      newlines = 0
      bytes.each_with_index do |byte, i|
        newlines += 1 if byte == 10
        return i + 1 if newlines == 3
      end
      0
    end

    it '見出しのフォントが見つからなければ、設定名を示してエラーにする' do
      write_file('setting.json', '{ "heading": { "font": "NoSuchHeadingFontXYZ" } }')
      input = write_file('h.rmd', "#1 a\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include('NoSuchHeadingFontXYZ')
      expect(err).to include('heading.font')
    end

    it 'レベルが飛んだ見出しは、警告を出すが PDF は出力する' do
      input = write_file('h.rmd', "#1 a\n\n#3 b\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:3: warning: 見出しレベルが飛んでいます")
      expect(File.exist?(File.join(@dir, 'h.pdf'))).to be(true)
    end
  end

  describe 'PDF の生成（2スペースの字下げ）' do
    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
    end

    def left_of(pdf, text)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="[\d.]+" xMax="[\d.]+" yMax="[\d.]+">(.*?)</word>}m)
          .to_h { |x, t| [t, x.to_f] }.fetch(text)
    end

    it 'paragraph_indent が 0 でも、2スペース始まりの段落だけ1字（10.5pt）下がる' do
      input = write_file('ind.rmd', "字下げなし\n\n  字下げあり\n")
      write_file('setting.json', '{ "text": { "paragraph_indent": 0 } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      pdf = File.join(@dir, 'ind.pdf')
      expect(left_of(pdf, '字下げなし')).to be_within(1.0).of(70.866)
      expect(left_of(pdf, '字下げあり')).to be_within(1.0).of(70.866 + 10.5)
    end

    it 'paragraph_indent が 2 のとき、2スペース始まりの段落は1字になる（足し算しない）' do
      input = write_file('ind.rmd', "通常段落\n\n  二スペース\n")
      write_file('setting.json', '{ "text": { "paragraph_indent": 2 } }')
      code, = run_cli('build', input)
      expect(code).to eq(0)

      pdf = File.join(@dir, 'ind.pdf')
      expect(left_of(pdf, '通常段落')).to be_within(1.0).of(70.866 + 21)
      expect(left_of(pdf, '二スペース')).to be_within(1.0).of(70.866 + 10.5)
    end
  end

  describe '図表の記法のエラー' do
    it '直後に表がない ![t:...] は、ファイル名と行番号つきでエラーにして 1 を返す' do
      input = write_file('a.rmd', "本文\n\n![t:なし]\n\n本文\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:3: error: ![t:...] の直後に表がありません")
    end

    it '画像のパスがない ![f:...] は、行番号つきでエラーにして 1 を返す' do
      input = write_file('a.rmd', "![f:パスなし]\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(1)
      expect(err).to include("#{input}:1: error: 図には画像のパスが必要です")
    end
  end

  describe 'PDF の生成（図表の番号とキャプション）' do
    PNG_1PX = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    PAGE_WIDTH = 595.276 unless defined?(PAGE_WIDTH)
    TEXT_WIDTH_PT = 453.544 # A4 の幅から左右の余白 25mm を引いた本文幅

    before do
      skip 'PDF 生成に必要なツールやフォントがありません' unless pdf_build_ready?
      skip 'pdftotext がありません' unless system('pdftotext', '-v', out: File::NULL, err: File::NULL)
      File.binwrite(File.join(@dir, 'img.png'), Base64.decode64(PNG_1PX))
    end

    # PDF 内の単語の { text:, x_min:, x_max:, y_min:, y_max: } を、出現順に取り出す
    def pdf_words(pdf)
      html = IO.popen(['pdftotext', '-bbox', pdf, '-'], &:read).force_encoding('UTF-8')
      html.scan(%r{xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>}m)
          .map { |x0, y0, x1, y1, text| { text: text, x_min: x0.to_f, y_min: y0.to_f, x_max: x1.to_f, y_max: y1.to_f } }
    end

    def pdf_word(words, text)
      words.find { |w| w[:text] == text } || raise("PDF に #{text.inspect} が見つかりません")
    end

    def build_pdf(rmd, setting: nil)
      write_file('setting.json', setting) if setting
      input = write_file('fig.rmd', rmd)
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0), err
      File.join(@dir, 'fig.pdf')
    end

    let(:table) { "| 条件 | 結果 |\n|---|---|\n| A | 10 |\n" }
    let(:figure_doc) { "前の段落です。\n\n![f:システム構成図](img.png){width=40%}\n\n次の段落です。\n" }

    it '図と表は別々に、出現順に 図1、図2、表1、表2 と採番され、タイトルが付く' do
      rmd = "![f:一つ目](img.png){width=20%}\n\n![t:表の一つ目]\n#{table}\n" \
            "![f:二つ目](img.png){width=20%}\n\n![t:表の二つ目]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd)} -`.force_encoding('UTF-8')
      expect(text).to match(/図\s*1\s*一つ目/)
      expect(text).to match(/図\s*2\s*二つ目/)
      expect(text).to match(/表\s*1\s*表の一つ目/)
      expect(text).to match(/表\s*2\s*表の二つ目/)
    end

    it 'タイトルが空なら、番号だけが表示される' do
      rmd = "![f](img.png){width=20%}\n\n![t]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd)} -`.force_encoding('UTF-8')
      expect(text).to match(/図\s*1\s*$/)
      expect(text).to match(/表\s*1\s*$/)
    end

    it '図のキャプションは、既定では画像の下に、ページの中央に置かれる' do
      words = pdf_words(build_pdf(figure_doc))
      before = pdf_word(words, '前の段落です。')
      caption = pdf_word(words, 'システム構成図')
      after = pdf_word(words, '次の段落です。')

      image_height = 0.4 * TEXT_WIDTH_PT
      expect(caption[:y_min] - before[:y_max]).to be > image_height
      expect(after[:y_min] - caption[:y_max]).to be < 30

      line = words.select { |w| (w[:y_min] - caption[:y_min]).abs < 1 }
      center = (line.map { |w| w[:x_min] }.min + line.map { |w| w[:x_max] }.max) / 2
      expect(center).to be_within(1.5).of(PAGE_WIDTH / 2)
    end

    it 'figure_position を top にすると、図のキャプションが画像の上に置かれる' do
      words = pdf_words(build_pdf(figure_doc, setting: '{ "caption": { "figure_position": "top" } }'))
      before = pdf_word(words, '前の段落です。')
      caption = pdf_word(words, 'システム構成図')
      after = pdf_word(words, '次の段落です。')

      expect(caption[:y_min] - before[:y_max]).to be < 40
      expect(after[:y_min] - caption[:y_max]).to be > 0.4 * TEXT_WIDTH_PT
    end

    it '表のキャプションは、既定では表の上に置かれる' do
      words = pdf_words(build_pdf("![t:実験結果]\n#{table}"))
      expect(pdf_word(words, '実験結果')[:y_max]).to be < pdf_word(words, '条件')[:y_min]
    end

    it 'table_position を bottom にすると、表のキャプションが表の下に置かれる' do
      words = pdf_words(build_pdf("![t:実験結果]\n#{table}", setting: '{ "caption": { "table_position": "bottom" } }'))
      expect(pdf_word(words, '実験結果')[:y_min]).to be > pdf_word(words, '10')[:y_max]
    end

    it '設定でラベルを変えられる' do
      setting = '{ "caption": { "figure_label": "Fig.", "table_label": "Table" } }'
      rmd = "![f:図の例](img.png){width=20%}\n\n![t:表の例]\n#{table}"
      text = `pdftotext -layout #{build_pdf(rmd, setting: setting)} -`.force_encoding('UTF-8')
      expect(text).to match(/Fig\.\s*1\s*図の例/)
      expect(text).to match(/Table\s*1\s*表の例/)
    end

    it '全角コロンの記法は、図表として扱わず、警告を出す（PDF は出力する）' do
      input = write_file('fig.rmd', "![f：全角](img.png){width=20%}\n")
      code, _out, err = run_cli('build', input)
      expect(code).to eq(0)
      expect(err).to include("#{input}:1: warning:")
      expect(`pdftotext -layout #{File.join(@dir, 'fig.pdf')} -`.force_encoding('UTF-8')).not_to match(/図\s*1/)
    end

    # 幅 width、高さ height の、真っ白な PNG（グレースケール 8bit）を作る
    def blank_png(width, height)
      chunk = lambda do |type, data|
        [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
      end
      raw = ("\x00".b + ("\xFF".b * width)) * height
      "\x89PNG\r\n\x1a\n".b +
        chunk.call('IHDR', [width, height, 8, 0, 0, 0, 0].pack('NNCCCCC')) +
        chunk.call('IDAT', Zlib::Deflate.deflate(raw)) +
        chunk.call('IEND', ''.b)
    end

    it '幅を指定していない大きな画像は、本文幅に収まるよう縮小される' do
      skip 'pdfimages がありません' unless system('pdfimages', '-v', out: File::NULL, err: File::NULL)
      File.binwrite(File.join(@dir, 'big.png'), blank_png(2000, 40))
      pdf = build_pdf("![f:大きい図](big.png)\n\n本文\n")

      # pdfimages -list の x-ppi 列から、PDF 上の画像の幅（pt）を求める
      row = `pdfimages -list #{pdf}`.lines.grep(/\A\s*1\s+0\s+image/).first
      columns = row.split
      width_px = columns[3].to_f
      ppi = columns[12].to_f
      displayed_pt = width_px / ppi * 72
      expect(displayed_pt).to be <= TEXT_WIDTH_PT + 1
      expect(displayed_pt).to be > TEXT_WIDTH_PT - 5 # 本文幅いっぱいまで縮小される
    end
  end
end
REPORTMD_EOF
cat > docs/spec.md <<'REPORTMD_EOF'
# reportmd 仕様書

- バージョン：0.1.0（初期仕様案）
- ステータス：設計中
- 言語：Ruby
- 文書形式：Markdownベースの独自拡張形式
- ファイル拡張子：`.rmd`（R Markdownの `.Rmd` と衝突するため、変更案を募集予定。12章参照）

> **この文書の読み方**
> 「（推奨案）」と付いた項目は、こちらで仮に決めた項目です。変更したい場合は付録Aを参照してください。

## 1. 概要

### 1.1 目的

`reportmd` は、Markdownの簡潔な記法を維持しながら、大学のレポートなどに必要な組版機能を追加する文書作成ツールである。

HTMLやCSSを直接記述せずに、本文を執筆し、用紙サイズ・余白・フォントなどを設定ファイルで管理し、PDFとして出力できることを目指す。

### 1.2 設計方針

1. 本文は可能な限り標準的なMarkdownで記述する。
2. 独自構文は、短く直感的な記号を使用する。
3. 通常のMarkdown文書の解釈を可能な限り維持する。
4. 文書全体の設定（`setting.json`）と本文の記述を分離する。
5. 独自構文の処理を独立したモジュールとして実装する。
6. 前処理は、Pandocが理解できる標準的な構造（fenced div、クラス付きspanなど）にだけ変換する。LaTeXコードを直接出力しない。LaTeXへの変換は `filter.lua` が担当する。
7. 将来的な機能追加やVS Code拡張の開発を考慮する。

### 1.3 初期バージョン（0.1.0）の対象範囲

対象とするもの：

- 日本語のレポート本文のPDF出力
- 改ページ、右揃え、中央揃え、字下げ、見出し番号、図表番号
- 用紙・余白・フォント・文字サイズ・行間・見出し書式のJSON設定

初期バージョンでは対象としないもの：

- 生HTMLの埋め込み（HTMLタグは解釈しない）
- 表紙・タイトルページの専用機能
- 字数・行数の指定（例：40字×30行）
- 参考文献の管理
- 図表の本文中参照（「図1より…」の自動リンク）

## 2. 対象環境・使用技術

| 項目            | 技術          |
| ------------- | ----------- |
| 実装言語          | Ruby        |
| 入力形式          | `.rmd`      |
| 設定形式          | JSON        |
| Markdown解析・変換 | Pandoc      |
| PDF生成         | XeLaTeX     |
| 日本語フォント       | IPAex明朝など   |
| テスト           | RSpecを候補とする |
| 将来の拡張         | VS Code拡張   |

### 2.1 処理の流れと役割分担

```text
.rmd ──> preprocessor.rb ──> Pandoc ──> filter.lua ──> XeLaTeX ──> PDF
                                ▲                          ▲
                          setting.json の内容を渡す（一時ファイル経由）
```

| 段階 | 役割 |
| --- | --- |
| `preprocessor.rb` | Markdownの独自構文を認識し、Pandocが理解できる形式へ変換する。 |
| Pandoc | Markdownを構造化された文書データ（AST）に変換する。 |
| `filter.lua` | 図表の自動採番、キャプションの組版、必要に応じた見出し番号などを処理する。 |
| XeLaTeX | 日本語フォントや余白などの設定を反映し、PDFを生成する。 |

## 3. ファイル構成

基本的なプロジェクト構成を以下とする。

```text
reportmd/
├── bin/
│   └── reportmd
├── lib/
│   └── reportmd/
│       ├── cli.rb
│       ├── config.rb
│       ├── preprocessor.rb
│       ├── builder.rb
│       ├── filter.lua
│       ├── preamble.tex.erb
│       └── version.rb
├── docs/
│   └── spec.md
├── config/
│   └── default.json
├── examples/
│   ├── report.rmd
│   └── setting.json
├── spec/
├── Gemfile
└── README.md
```

- `cli.rb`：コマンドライン引数の処理
- `config.rb`：設定ファイルの読み込み・検証
- `preprocessor.rb`：独自構文の検出と変換
- `builder.rb`：PDF生成処理（Pandoc・XeLaTeXの呼び出し）
- `filter.lua`：Pandoc解析後の文書構造に対する変換
- `preamble.tex.erb`：設定ファイルの内容（用紙・余白・フォント・文字サイズ・行間・字下げ・ページ番号）をLaTeXのプリアンブルに変換するテンプレート。PandocのLaTeX標準テンプレートに、`--include-in-header` で追加する
- `version.rb`：バージョン番号
- `config/default.json`：内蔵のデフォルト設定（設定ファイルがない場合や、項目が省略された場合に使う）
- `examples/setting.json`：`examples/report.rmd` 用のサンプル設定
- `spec/`：自動テスト

## 4. コマンドライン仕様

### 4.1 基本コマンド

```bash
reportmd build report.rmd
```

指定した入力ファイルからPDFを生成する。出力先を省略した場合、入力ファイルと同じディレクトリに同名のPDFを出力する。

### 4.2 出力先の指定

```bash
reportmd build report.rmd -o output.pdf
```

### 4.3 設定ファイルの指定

```bash
reportmd build report.rmd -c setting.json
```

### 4.4 オプション

| オプション            | 説明                         |
| ---------------- | -------------------------- |
| `-o`, `--output` | 出力PDFのパス                   |
| `-c`, `--config` | 設定ファイルのパス                  |
| `--keep-temp`    | 一時ファイルを残す（デバッグ用。前処理後のMarkdownなどを確認できる） |
| `-v`, `--version` | バージョン表示                   |
| `-h`, `--help`   | ヘルプ表示                      |

### 4.5 パスの扱い

- 本文中の画像パスは、**入力ファイルのあるディレクトリ**を基準に解決する。実行時のカレントディレクトリには依存しない。
- 出力先に同名ファイルが存在する場合は上書きする。

## 5. 標準Markdownの対応範囲

本文はMarkdownを基本とし、以下の機能を利用できることを目指す。

- 見出し（標準の `#` 記法。番号なし見出しとして扱う。6.5参照）
- 段落
- 太字・斜体
- 箇条書き・番号付きリスト
- 引用
- リンク
- 表
- 画像
- フェンス付きコードブロック
- 数式（`$...$` と `$$...$$`）
- 脚注
- YAMLフロントマター（5.2参照）

具体的な対応範囲は、PandocのMarkdown拡張設定と実装時の検証によって確定する。

コードブロックにはバッククォート3個またはチルダ3個以上のフェンスを使用できることを目指す。

### 5.1 HTMLの扱い

初期バージョンでは、HTMLをサポートしない。PandocのMarkdownリーダーは、生HTML・生TeXの埋め込み拡張を無効にして使用する（例：`-f markdown-raw_html-raw_tex`）。HTMLタグは解釈せず、文字としてそのまま扱う想定とする（実装時に挙動を検証して確定する）。

これにより、`-->`（HTMLコメントの終端と同じ記号）を独自構文として安全に使える。

### 5.2 YAMLフロントマター

ファイルの先頭に、以下の形式でメタデータを書ける。

```yaml
---
title: 実験レポート
author: 山田 太郎
---
```

- 対応キーは `title` と `author`。設定ファイルの `document.title` / `document.author` より優先する。
- 初期バージョンでは、`title` と `author` はPDFのメタデータにのみ反映し、本文には自動で出力しない（タイトルは本文で `<-> 実験レポート` のように書く）。（推奨案）
- 対応外のキーは警告を表示して無視する。

### 5.3 文字コードと改行

- 入力は UTF-8 とする。BOMがある場合は取り除く。
- 改行コードは CRLF / LF のどちらでも受け付け、内部ではLFに統一する。

## 6. 独自構文

### 6.1 基本方針と前処理の共通ルール

独自構文には、意味を連想しやすい記号を使用する。本文に `reportmd` などの専用キーワードを毎回記述する方式は採用しない。

#### 保護領域

次の領域の内部は、前処理で一切変更しない。独自構文の記号が含まれていても変換しない。

| 領域 | 範囲 |
| --- | --- |
| フェンス付きコードブロック | 開きフェンス（バッククォートまたはチルダ3個以上）から、同じ種類で同じ数以上の閉じフェンスまで。閉じフェンスがない場合は、ファイル末尾までをコードとして扱い警告する。 |
| 数式ブロック | `$$` の開始から終了まで。1行で完結する `$$ ... $$` も対象。終了がない場合はエラー。 |
| YAMLフロントマター | ファイル先頭の `---` から、次の `---` または `...` まで。終了がない場合はエラー。 |
| インデントコードブロック | 行頭が半角スペース4個以上の行は変換対象としない（6.6参照）。 |

#### 処理の原則

- 前処理は行単位の状態機械として実装し、保護領域の内側かどうかを常に判定する。単純な全文の正規表現置換は使わない。
- 独自構文として認識した部分だけを変換し、それ以外の行は一字も変更しない。
- 変換後の行番号がずれる場合に備えて、エラー表示のために元の行番号を保持する。
- 変換結果のブロック（fenced divなど）は、前後に空行を補って出力する。独自構文の行は、直前に空行がなくても新しいブロックの開始として扱う。

### 6.2 改ページ

記法：

```text
前のページの本文

^

次のページの本文
```

- 単独行の `^`（行頭から `^` のみ。行末の空白は許容）を改ページ指示として扱う。
- 通常の文章中に含まれる `^` は改ページとして扱わない。
- 保護領域（コードブロック、数式ブロック、フロントマター）内の `^` は変換しない。
- リストや引用の内側では認識しない（トップレベルのみ）。

### 6.3 右揃え

記法：

```text
--> 2026年10月12日
--> 大阪工業大学
```

- 行頭の `-->` の後に半角スペースを1個以上置き、続けて内容を書く。
- 連続する右揃え行を、ひとつのブロックとして処理する。空行、または他の種類の行が現れた時点でブロックを終了する。
- ブロック内の各行は、1行ずつ改行して表示する（Markdownの通常の段落結合は行わない）。
- 内容は通常のMarkdownとして解釈する。太字、斜体、数式、リンクなどのインライン書式を使用できる。
- 内容が空の `-->`（`-->` だけの行）は読み飛ばす。何も出力せず、前後の右揃え行は同じブロックとして続ける。
- 記号の直後に半角スペースがない行（`-->text`）や、行頭に字下げのある行（`  --> text`）は、右揃えとして扱わない。
- 内容の先頭が「2026. 10. 12」のように番号付きリストに見える場合は、ピリオドをエスケープして、文字として扱う。
- 内容は、Markdownの1つの段落として読まれる。内容の先頭に `#` や `- ` などのブロック構文を書いた場合の動作は保証しない。

### 6.4 中央揃え

記法：

```text
<-> 実験レポート
```

- 規則は右揃え（6.3）と同じ。記号だけが `<->` に変わる。
- 右揃えの行と中央揃えの行が隣り合う場合は、別のブロックとして扱う。
- 左揃えは標準状態とし、専用の記号を設けない。

### 6.5 見出しと見出し番号

記法：

```text
#1 はじめに
#2 背景
#2 目的
#3 詳細
```

出力される見出し番号：

| 記法 | 番号 | 例 |
| --- | --- | --- |
| `#1` | 1 | 1 はじめに |
| `#2` | 1.1 | 1.1 背景 |
| `#3` | 1.1.1 | 1.1.1 詳細 |

既定の字下げを適用した表示例：

```text
1 はじめに
  1.1 背景
    1.1.1 詳細
```

- 行頭（0桁目）に `#` と半角数字1桁（1〜3）を書き、続けて半角スペースを1個以上置き、見出し文字列を書く。
- 番号は、各レベルごとにカウントする。上位のレベルが現れると、下位のカウントは最初からやり直す（`#1` のあとの最初の `#2` は 1.1 になる）。番号と見出し文字列の間は、全角1字ぶんあける。
- 初期バージョンは `#1`〜`#3` の3階層までとする。`#0`、`#4`〜`#9` は見出しとして扱わず、警告を出して通常の段落として扱う。`#12` のように数字が2桁以上の行や、`#タグ` のように数字が続かない行は、見出しではない普通の文字として扱い、警告も出さない。
- 見出し文字列が空（`#1` だけの行、`#1` のあとが空白だけの行）の場合は、警告を出して通常の段落として扱う。
- レベルを飛ばした場合（最初の見出しが `#2` の場合や、`#1` の次に `#3` が来た場合など）は警告を出す。見出しとしては扱い、番号は `1.0.1` のように、飛ばしたレベルが0になる。
- 番号付き見出しは、リストや引用の内側では使用できない（トップレベルのみ）。
- 標準Markdownの `#`、`##`、`###`（`#` の後に半角スペース）は、**番号なし**の見出しとして扱う。「はじめに」「参考文献」のように、番号を付けたくない見出しに使う。
- 番号付けは、Pandocの `--number-sections` に任せ、LaTeX標準の見出しカウンタで行う。前処理は `#1` を `# 見出し {.reportmd-num}` のように変換し、`filter.lua` が、このクラスを持たない標準の見出しに `.unnumbered` を付けて、番号なしにする。
- 見出しは、レベルに応じて字下げする。既定では、レベル1は0字、レベル2は1字、レベル3は2字だけ、見出しの左端を右へずらす。番号付き見出し（`#1`〜`#3`）と番号なし見出し（`#`〜`###`）の両方に、同じレベルなら同じ字下げを適用する。本文は、見出しの深さに応じた字下げをしない。
- 見出しのフォント・文字サイズ・太字・字下げ量は `setting.json` の `heading` で指定する（7章参照）。字下げ量の1字は、本文の文字サイズ（`text.font_size`）とする。
- 見出しの前には本文1行ぶん（行送り）、後ろにはその半分の空きを入れる。
- 太字（`heading.bold`）は、フォントに太字の書体があればそれを使い、なければ疑似的に太くして表示する。
- 標準の `####` 以降の見出しは、初期バージョンでは書式を指定できない（LaTeXの標準のまま）。

### 6.6 インデント

記法：

```text
通常の段落。

  この段落は、字下げ1字分になる。
```

- 段落の最初の行が、**ちょうど半角スペース2個**と空白以外の文字で始まる場合、その段落を字下げする。
- 3個（以下）や4個以上のスペースで始まる行は変換しない（4個以上は標準Markdownのコードブロック）。
- 認識するのは、直前が空行・ファイル先頭・見出し行・改ページや右揃えなどの変換結果の直後にある、トップレベルの段落のみ。段落の途中の行、リストの項目・続き、引用の内側では認識しない。
- 2スペースの直後が、リスト・見出し・引用・表・水平線・コードフェンス・`$$`・`:::`・脚注定義の記法に見える場合は、字下げとして扱わない。
- 字下げ量は `text.paragraph_indent` の設定にかかわらず**1字**に置き換える（加算しない）。1字は本文のフォントサイズ（既定10.5pt）とする。
  - 例：`paragraph_indent` が `0` のとき、2スペースで始めた段落だけが1字下がる。
  - 例：`paragraph_indent` が `2` のとき、2スペースで始めた段落は2字ではなく1字になる。
- 保護領域の内部は変更しない。
- 実装：前処理が段落の先頭を `[]{.reportmd-indent}` に置き換え、フィルタが LaTeX の `\noindent\hspace*{\reportmdchar}` に変換する。

### 6.7 図表番号

#### 6.7.1 記法の共通ルール

- 図は `![f:タイトル]`、表は `![t:タイトル]` の形で書く。`f`（figure）と `t`（table）は、図か表かを表す種類の指定である。**番号は書かない**。番号は自動で振る（6.7.4参照）。
- 種類とタイトルの区切りは、**半角コロン `:` のみ**を認識する。全角コロン `：` は区切りとして扱わない。全角コロンを使った場合（例：`![f：タイトル]`）は、通常のMarkdownとして扱い、警告を表示する。
- タイトルが空の場合（`![f]`、`![f:]`、`![t]`、`![t:]`）は、図表番号のみを表示する（例：「図1」）。
- タイトルは、インラインのMarkdown（強調や数式など）を含められる。
- 図表の記法は、行頭（0桁目）から、1行に1つだけ書く。リストや引用の内側、行の途中に書いた `![f:...](...)` は、図として扱わず、通常の画像として表示する（番号もキャプションも付かない）。
- 番号やキャプションを付けない通常の画像は、代替テキストを `f:` で始めなければ、そのまま表示される。
- 図表の記法は、前処理が、クラスつきのブロック（`.reportmd-figure`、`.reportmd-table-caption`）に変換し、番号とキャプションの組版は `filter.lua` が行う。

#### 6.7.2 図

記法：

```text
![f:システム構成図](images/system.png)
```

- 行には、画像だけを書く。同じ行に画像以外の文字があると、警告を表示して、番号とキャプションを付けない。
- 画像のパスは必須。ない場合（`![f:タイトル]` だけの行）はエラーとする。
- Pandocの画像属性（例：`{width=50%}`）をそのまま使用できる。
- 幅を指定していない画像は、本文幅より大きければ、本文幅に収まるよう縮小する。`{width=300%}` のように、本文幅より大きく指定した場合は、指定どおりの幅になる（はみ出す）。
- 画像のファイルが見つからない場合は、Pandocの警告が表示され、画像のない図（キャプションだけ）になる。

#### 6.7.3 表

記法：

```text
![t:実験結果]
| 条件 | 結果 |
|---|---|
| A | 10 |
| B | 20 |
```

- `![t:タイトル]` の行を、1行で単独で書く。後ろに `(...)` などがある行はエラーとする（画像には `![f:...](...)` を使う）。
- その直後（空行なし、または空行1つまで）にMarkdownの表を置く。直後に表がない場合は、`![t:...]` の行番号つきでエラーとする。
- 直後の表として認識するのは、パイプ表（先頭の `|` があってもなくてもよい）、グリッド表、単純な表（ハイフンの区切り行）。
- 表は、この行のタイトルと関連付けられる。表に付いていたPandoc標準のキャプション（`: タイトル`）がある場合は、使わない。

#### 6.7.4 採番と表示

- 図と表は、それぞれ別の連番で採番する。文書内の出現順に1から振る。
- 番号は記法の中に書かず、すべて自動で振る。順番を入れ替えても、番号は自動でずれる。
- 表示形式は「`図{番号} {タイトル}`」「`表{番号} {タイトル}`」とし、番号とタイトルの間は半角スペース1個とする。タイトルがない場合は番号のみ。
- 「図」「表」の文字列は、`caption.figure_label` と `caption.table_label` で変更できる。
- キャプションの位置は、`caption.figure_position`（既定：`bottom`）と `caption.table_position`（既定：`top`）で指定する。
- 図表は、浮動体として移動させず、書いた位置に固定して配置する。入りきらない場合は次のページの先頭に送られ、前のページの下に空白ができる。
- 図は、画像とキャプションを中央に揃え、同じページに収める。表のキャプションも中央に揃え、表の上に置く場合は、表と別のページにならないようにする。
- キャプションの文字サイズ・フォントは、本文と同じ。画像とキャプションの間には、本文の半行ぶんの空きを入れる。
- ラベルと番号の間には、空白を入れない（`caption.figure_label` を `"Fig."` にすると「Fig.1」と表示される）。「図」と数字の間に見える小さな空きは、日本語と英数字の間に入る組版上のものである。
- 自動採番とキャプションの組版は `filter.lua` が担当する。

### 6.8 右揃え・中央揃えのリスト・引用内での利用

右揃え（`-->`）と中央揃え（`<->`）は、リストや引用の内側でも使える。

```text
- 項目A
- --> 右揃えの項目

> <-> 中央揃えの引用
```

- 認識するのは、引用の `>` の直後、またはリスト記号（`-` `*` `+`、`1.` `1)`）の直後。リスト記号の前の字下げは3個までとし、入れ子のリストには、初期バージョンでは対応しない。
- 前処理は、引用の接頭辞をそのまま保持したまま、独自構文の部分だけを変換する。リスト項目の中では、リスト記号の行に変換後のブロックを置く。
- 連続した行をひとつのブロックとして扱う規則（6.3）は、同じ引用の接頭辞を持つ行の間でのみ適用する。リスト記号つきの行は、記号ごとに別の項目になるので、まとめずに1行ずつ変換する。

## 7. 設定ファイル

### 7.1 形式と場所

設定ファイルはJSONとし、初期ファイル名を `setting.json` とする。

設定ファイルは、次の優先順位で探す。（推奨案）

1. `-c` / `--config` で指定されたファイル
2. 入力ファイルと同じディレクトリの `setting.json`
3. 内蔵のデフォルト設定（`config/default.json`）

### 7.2 設定例

```json
{
  "document": {
    "paper": "a4",
    "title": "実験レポート",
    "author": ""
  },
  "page": {
    "margin": {
      "top": "25mm",
      "bottom": "25mm",
      "left": "25mm",
      "right": "25mm"
    },
    "numbering": true
  },
  "text": {
    "font_size": "10.5pt",
    "line_spacing": 1.5,
    "paragraph_indent": 1
  },
  "font": {
    "main": "IPAexMincho",
    "mono": "Noto Sans Mono CJK JP"
  },
  "heading": {
    "font": "IPAexGothic",
    "bold": true,
    "sizes": ["14pt", "12pt", "10.5pt"],
    "indents": [0, 1, 2]
  },
  "caption": {
    "figure_label": "図",
    "table_label": "表",
    "figure_position": "bottom",
    "table_position": "top"
  }
}
```

### 7.3 設定項目

| 項目                      | 意味                       | 型・許容値                          | 既定値                      |
| ----------------------- | ------------------------ | ------------------------------ | ------------------------ |
| `document.paper`        | 用紙サイズ                    | `"a4"` `"a5"` `"b5"` `"letter"` | `"a4"`                   |
| `document.title`        | 文書タイトル（PDFメタデータ）         | 文字列                            | 空                        |
| `document.author`       | 著者名（PDFメタデータ）            | 文字列                            | 空                        |
| `page.margin`           | 上下左右の余白                  | `mm` `cm` `pt` `in` の単位付き文字列 | `"25mm"`                 |
| `page.numbering`        | ページ番号の有効・無効（下中央に表示）      | 真偽値                            | `true`                   |
| `text.font_size`        | 本文の文字サイズ                 | `pt` 単位、6pt〜24pt               | `"10.5pt"`               |
| `text.line_spacing`     | 行間（標準の行送りに対する倍率）         | 数値、1.0〜3.0                     | `1.5`                    |
| `text.paragraph_indent` | 段落の既定の字下げ（字数）            | 数値、0〜5                         | `1`                      |
| `font.main`             | 本文フォント                   | 文字列（フォント名）                     | `"IPAexMincho"`          |
| `font.mono`             | 等幅フォント                   | 文字列（フォント名）                     | `"Noto Sans Mono CJK JP"` |
| `heading.font`          | 見出しフォント                  | 文字列（フォント名）                     | `"IPAexGothic"`          |
| `heading.bold`          | 見出しを太字にするか               | 真偽値                            | `true`                   |
| `heading.sizes`         | 見出しレベル1〜3の文字サイズ          | `pt` 単位の文字列を3個並べた配列            | `["14pt","12pt","10.5pt"]` |
| `heading.indents`       | 見出しレベル1〜3の字下げ量（字数）     | 数値（0〜5）を3個並べた配列               | `[0,1,2]`                |
| `caption.figure_label`  | 図キャプションのラベル文字列           | 文字列                            | `"図"`                    |
| `caption.table_label`   | 表キャプションのラベル文字列           | 文字列                            | `"表"`                    |
| `caption.figure_position` | 図キャプションの位置              | `"top"` `"bottom"`             | `"bottom"`               |
| `caption.table_position`  | 表キャプションの位置              | `"top"` `"bottom"`             | `"top"`                  |

### 7.4 読み込みと検証のルール

- 省略された項目には既定値を使う。入れ子の項目は、項目単位で既定値と統合する。
- 未知のキーは警告を表示して無視する。
- 値の型や範囲が不正な場合はエラーとし、項目名と許容値を表示する。
- 各項目は、実装時に適用処理と検証処理を用意する。未実装の設定を読み込んでも、反映済みであるかのように扱ってはならない（未実装の項目は「未対応」と警告する）。
- 指定されたフォントが見つからない場合はエラーとし、フォント名を表示する。

## 8. PDF生成仕様

1. `.rmd` ファイルをUTF-8として読み込む（5.3参照）。
2. 設定ファイルを読み込み、検証する。
3. 独自構文の前処理を行う（6章）。
4. Pandocで、前処理後のMarkdownを解析する。`title` と `author` はメタデータとして、そのほかの設定は `preamble.tex.erb` から生成したプリアンブルとしてPandocに渡す。
5. `filter.lua` で、図表番号・キャプションなどの書式変換を適用する。
6. XeLaTeXでPDFを生成する（Pandocが呼び出す）。
7. 成功時には出力先を表示し、失敗時には原因を確認できるエラーを表示する。

PDF生成時に一時ファイルを使用する場合は、一時ディレクトリに作成し、正常終了・異常終了のいずれでも不要な一時ファイルが残らないようにする。ただし `--keep-temp` が指定された場合は残す。

## 9. エラー処理

### 9.1 検出するエラー

少なくとも以下を検出する。

- 入力ファイルが存在しない
- 設定ファイルが存在しない、またはJSONとして不正
- 設定値が許容範囲外
- 独自構文の記述が不正
  - 直後に表がない `![t:...]`
  - 後ろに `(...)` がある `![t:...]`
  - 画像のパスがない `![f:...]`
  - 終了のない数式ブロック・フロントマター
- PandocまたはXeLaTeXが利用できない
- 指定されたフォントが見つからない
- PDF生成に失敗した

### 9.2 警告

エラーとはせず、警告を表示して処理を続けるもの。

- 全角コロンを使った図表ラベル風の記述（6.7.1）
- 図の行に、画像以外の文字がある場合（6.7.2）
- 未対応の見出しレベル（`#0`、`#4`〜`#9`）、見出し文字列が空の見出し、見出しレベルの飛ばし
- 閉じフェンスのないコードブロック
- 未知の設定キー、対応外のフロントマターのキー

### 9.3 表示と終了コード

- エラー・警告は標準エラー出力に、`ファイル名:行番号: 種類: メッセージ` の形式で表示する。
- 終了コード（コマンド終了時に返す、成功・失敗を表す数字）は次のとおりとする。

| 終了コード | 意味 |
| --- | --- |
| 0 | 成功（警告があっても0） |
| 1 | 失敗（入力・設定・独自構文のエラー、外部ツールが使えない、PDF生成の失敗など） |

## 10. テスト方針

独自構文の実装では、正常系だけでなく標準Markdownへの影響もテストする。

### 10.1 テストの種類

- **前処理の単体テスト**：入力テキストと、期待される出力テキストを比較する（スナップショット）。PDFを生成せずに高速に実行できる。
- **フィルタのテスト**：Pandocに通して、期待される文書構造になることを確認する。
- **結合テスト**：`examples/report.rmd` からPDFが生成できることを確認する（スモークテスト）。PDFの見た目そのものの比較は行わない。

### 10.2 確認する項目

- 通常のMarkdownからPDFを生成できる。
- 日本語が正常に表示される。
- 表・画像・数式・脚注が利用できる。
- 改ページ・右揃え・中央揃えが適用される。
- 内容のない `-->` / `<->` の行が読み飛ばされる。
- 右揃え・中央揃えの中でインライン書式が使える。リストや引用の内側でも動作する。
- インデントが規則どおり適用される（2個のみ変換、3個・4個以上は変換しない）。
- コードフェンス内の記号が変換されない。
- 数式ブロック内の `^` 単独行が変換されない。
- YAMLフロントマター内の記号が変換されない。
- 通常の文章中の記号が誤変換されない。
- リスト・引用・見出しなどの意味が保たれる。
- `#1`〜`#3` の見出し番号が、期待どおり（1、1.1、1.1.1）に付く。標準の `#` は番号が付かない。
- 見出しがレベルに応じて字下げされる（既定：0字・1字・2字）。設定で変更できる。
- 図表番号が出現順に付き、タイトルが空の場合は番号のみ表示される。
- 全角コロンの図表記法（`![f：…]`）は変換されず、警告が出る。
- 図表番号を書かなくても、図と表がそれぞれ出現順に1から採番される。
- 不正な設定や構文に対して、行番号つきのエラーを返し、終了コードが0以外になる。
- CRLFの入力、BOM付きの入力が正しく処理される。

## 11. 初期開発の完了条件

以下を満たした段階で、初期プロトタイプの完成とする。

- `.rmd` からPDFを生成できる。
- 日本語と基本的なMarkdown構文が利用できる。
- JSON設定で用紙・余白・フォント・文字サイズ・行間・見出し書式を指定できる。
- 独自構文による改ページ・インデント・右揃え・中央揃えが動作する。
- `#1`〜`#3` による見出し番号が動作する。
- 図表番号の記法とキャプション表示が動作する。
- コードブロック・数式ブロック・フロントマターの内容が保護される。
- 基本的な自動テストが整備されている。

## 12. 今後の検討事項

以下は初期仕様では確定しない。

- 拡張子 `.rmd` の変更（R Markdownとの衝突。別の案を募集する）
- 表紙・タイトルページ
- 字数・行数の指定
- HTMLのサポート
- 図表の本文中参照（相互参照）の記法（番号を書かない記法のため、参照用のIDの付け方も含めて検討する）
- 参考文献の管理方式
- ページ番号の位置・形式、ヘッダー・フッター
- 表のページ分割や長い表の扱い
- 2段階以上のインデント、リスト・引用内でのインデント
- `#4` 以降の見出しレベル
- 縦書き・段組み
- VS Code拡張の機能

以上を初期仕様案とし、実装・テストで問題が見つかった場合は、本文の互換性を優先して仕様を改訂する。

---

## 付録A：仮決めした項目（変更可能）

仕様を完成させるために、こちらで仮に決めた項目。変更したい場合は、該当箇所を書き換える。

| 項目 | 仮決めの内容 | 場所 |
| --- | --- | --- |
| 本文へのタイトル出力 | フロントマターの `title` / `author` はPDFメタデータのみ。本文には出さない | 5.2 |
| 設定ファイルの探索順 | `-c` → 入力ファイルと同じ場所の `setting.json` → 内蔵デフォルト（`config/default.json`） | 7.1 |
| `paragraph_indent` の既定値 | `1`（1字下げ。日本語文書の標準） | 7.3 |
| 表示形式 | 「図1 タイトル」（半角スペース1個）。ラベル文字は設定で変更可 | 6.7.4 |
| 内容のない `-->` / `<->` | 読み飛ばす（出力しない） | 6.3 |
| 終了のない `$$` / フロントマター | エラー | 6.1 |
| 終了コード | 0（成功）と1（失敗）の2種類 | 9.3 |
| 見出しの設定項目 | `heading.font` / `bold` / `sizes` / `indents` | 7.3 |

## 付録B：確認済みの方針

| 項目 | 決定内容 | 場所 |
| --- | --- | --- |
| 標準Markdownの `#` | 番号なし見出し | 6.5 |
| 図表の番号 | 記法に番号を書かず、`![f:タイトル]` / `![t:タイトル]` の形で、番号は自動採番 | 6.7 |
| 2スペースの字下げ | `paragraph_indent` にかかわらず、1字下げに置き換える | 6.6 |
| 見出しの字下げ | レベルに応じて字下げする（既定：0字・1字・2字）。設定 `heading.indents` で変更できる | 6.5 |
| 図表の配置 | 浮動体にせず、書いた位置に固定する | 6.7.4 |
REPORTMD_EOF
echo "更新しました。bundle exec rspec を実行してください"