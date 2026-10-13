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

      lines = split_lines(@source)
      lines.each_with_index do |line, index|
        process_line(line, index + 1, lines, index)
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

      if (fence = fence_open(line))
        @state = :fence
        @fence_char, @fence_len = fence
        @region_start = lineno
        emit(line)
      elsif math_open?(line)
        @state = :math
        @region_start = lineno
        emit(line)
      elsif line =~ PAGE_BREAK_LINE
        emit_block(PAGE_BREAK_BLOCK)
      else
        emit(line)
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