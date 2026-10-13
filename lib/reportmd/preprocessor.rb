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
