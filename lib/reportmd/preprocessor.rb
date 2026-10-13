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
  #
  # 保護領域の内側は一切変更しない。
  class Preprocessor
    Result = Struct.new(:text, :warnings)

    PAGE_BREAK_LINE   = /\A\^[ \t]*\z/
    FENCE_OPEN_LINE   = /\A[ ]*(`{3,}|~{3,})(.*)\z/
    FRONT_MATTER_END  = /\A(---|\.\.\.)[ \t]*\z/
    FRONT_MATTER_OPEN = /\A---[ \t]*\z/

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
    def emit_block(block_lines)
      @output << '' unless @output.empty? || @output.last.empty?
      @output.concat(block_lines)
      @output << ''
      @after_generated = true
    end

    # --- 終了処理 -------------------------------------------------------

    def finish
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
      @output.pop if @after_generated && @output.last == ''
    end

    def build_text
      @output.empty? ? '' : "#{@output.join("\n")}\n"
    end
  end
end