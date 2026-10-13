# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'preprocessor'
require_relative 'config'

module Reportmd
  # PDF 生成の途中で起きたエラー（外部ツールがない、PDF 生成に失敗した、など）。
  # file にはエラーの原因のファイル（フォントなら設定ファイル）が入る。
  # 省略した場合は、入力ファイルの問題として表示する。
  class BuildError < StandardError
    attr_reader :file

    def initialize(message, file: nil)
      super(message)
      @file = file
    end
  end

  # .rmd を読み、前処理 → Pandoc → XeLaTeX の順に実行して PDF を作る。
  class Builder
    FILTER_PATH   = File.join(__dir__, 'filter.lua')
    PREAMBLE_PATH = File.join(__dir__, 'preamble.tex.erb')

    PAPER_OPTIONS = {
      'a4' => 'a4paper', 'a5' => 'a5paper', 'b5' => 'b5paper', 'letter' => 'letterpaper'
    }.freeze

    TABLE_POSITION_ENVS = { 'center' => 'center', 'left' => 'flushleft' }.freeze

    # 行送りは、文字サイズのこの倍率を標準とする（LaTeX の標準に近い値）
    BASELINE_RATIO = 1.2
    PANDOC_READER = 'markdown-raw_html-raw_tex'
    CAPTION_KEYS = %w[figure_label table_label figure_position table_position].freeze
    PANDOC_ERROR_LINES = 25

    Result = Struct.new(:output_path, :warnings, :tool_output, :temp_dir)

    def initialize(input_path:, output_path:, config:, keep_temp: false)
      @input_name = input_path # 警告に表示する名前（指定されたとおり）
      @input_path = File.expand_path(input_path)
      @output_path = File.expand_path(output_path)
      @config = config
      @keep_temp = keep_temp
    end

    def call
      # 構文のエラーは外部ツールがなくても見つけられるので、先に前処理を行う
      preprocessed = Preprocessor.new(File.read(@input_path, encoding: 'UTF-8')).call

      check_tools!
      check_output_dir!
      check_fonts!

      tool_output = nil
      with_work_dir do |dir|
        paths = write_work_files(dir, preprocessed.text)
        tool_output = run_pandoc(paths)
      end
      Result.new(@output_path, preprocessed.warnings, tool_output, @kept_dir)
    end

    private

    # --- 事前チェック ---------------------------------------------------

    def check_tools!
      { 'pandoc' => 'Pandoc', 'xelatex' => 'XeLaTeX' }.each do |command, label|
        next if system(command, '--version', out: File::NULL, err: File::NULL)

        raise BuildError, "#{label}（#{command}）が見つかりません。インストールされているか確認してください"
      end
    end

    def check_output_dir!
      dir = File.dirname(@output_path)
      raise BuildError, "出力先のディレクトリがありません: #{dir}" unless File.directory?(dir)
    end

    # 設定されたフォントがインストールされているか確認する。
    # fc-list が使えない環境では、確認を飛ばす（XeLaTeX がエラーを出す）。
    def check_fonts!
      families = installed_font_families
      return unless families

      [%w[font main], %w[font mono], %w[heading font]].each do |path|
        name = @config.dig(*path)
        next if families.include?(name.downcase)

        raise BuildError.new(
          "フォント「#{name}」が見つかりません（設定: #{path.join('.')}）。" \
          '`fc-list : family` で使えるフォント名を確認してください',
          file: @config.source || Config::DEFAULT_PATH
        )
      end
    end

    def installed_font_families
      out, status = Open3.capture2('fc-list', ':', 'family')
      return nil unless status.success?

      out.lines.flat_map { |line| line.strip.split(',') }.map { |name| name.strip.downcase }
    rescue SystemCallError
      nil
    end

    # --- 作業用ファイル -------------------------------------------------

    def with_work_dir(&block)
      if @keep_temp
        @kept_dir = Dir.mktmpdir('reportmd-')
        block.call(@kept_dir)
      else
        Dir.mktmpdir('reportmd-', &block)
      end
    end

    def write_work_files(dir, markdown)
      paths = {
        body: File.join(dir, 'body.md'),
        meta: File.join(dir, 'meta.json'),
        preamble: File.join(dir, 'preamble.tex')
      }
      File.write(paths[:body], markdown)
      File.write(paths[:meta], JSON.generate(metadata))
      File.write(paths[:preamble], render_preamble)
      paths
    end

    # 文書のメタデータ。title と author は、空の項目を渡さない。
    # （本文中の YAML フロントマターの値が、これより優先される）
    # reportmd は、filter.lua が図表のキャプションの組版に使う設定。
    def metadata
      meta = %w[title author].each_with_object({}) do |key, result|
        value = @config.dig('document', key)
        result[key] = value unless value.to_s.strip.empty?
      end
      meta['reportmd'] = CAPTION_KEYS.to_h { |key| [key, @config.dig('caption', key)] }
      meta['reportmd']['source'] = @input_name # filter.lua の警告に表示するファイル名
      # 表の組み方（tabular の形）に関わる設定。線の太さなどはプリアンブルで決める
      meta['reportmd']['table_width'] = @config.dig('table', 'width')
      meta['reportmd']['table_header_align'] = @config.dig('table', 'header', 'align')
      meta['reportmd']['equation_numbering'] = @config.dig('equation', 'numbering')
      meta['reportmd']['equation_label'] = @config.dig('equation', 'label')
      meta
    end

    def render_preamble
      ERB.new(File.read(PREAMBLE_PATH, encoding: 'UTF-8'), trim_mode: '-')
         .result_with_hash(preamble_variables)
    end

    def preamble_variables
      font_size = @config.dig('text', 'font_size').to_f
      margin = @config.dig('page', 'margin')
      {
        **heading_variables(font_size),
        **table_variables(font_size),
        paper_option: PAPER_OPTIONS.fetch(@config.dig('document', 'paper')),
        margin_top: margin['top'], margin_bottom: margin['bottom'],
        margin_left: margin['left'], margin_right: margin['right'],
        font_main: @config.dig('font', 'main'),
        font_mono: @config.dig('font', 'mono'),
        font_size_pt: number(font_size),
        baseline_pt: number(font_size * BASELINE_RATIO),
        line_spacing: number(@config.dig('text', 'line_spacing')),
        # 1字 = 本文の文字サイズ
        parindent_pt: number(@config.dig('text', 'paragraph_indent') * font_size),
        page_numbering: @config.dig('page', 'numbering')
      }
    end

    # 見出しの書式。1字 = 本文の文字サイズ。
    # 見出しの前後の空きは、本文1行分（行送り）を基準にする。
    def heading_variables(font_size)
      leading = font_size * BASELINE_RATIO * @config.dig('text', 'line_spacing')
      sizes = @config.dig('heading', 'sizes').map(&:to_f)
      {
        heading_font: @config.dig('heading', 'font'),
        heading_bold: @config.dig('heading', 'bold'),
        heading_sizes: sizes.map { |size| number(size) },
        heading_leadings: sizes.map { |size| number(size * BASELINE_RATIO) },
        heading_indents: @config.dig('heading', 'indents').map { |n| number(n * font_size) },
        heading_before: number(leading),
        heading_after: number(leading * 0.5)
      }
    end

    # 表の書式。文字サイズが null なら本文と同じにする。
    # 表の中は本文の行間（line_spacing）を使わず、row_spacing だけで行の高さを決める。
    def table_variables(body_font_size)
      table = @config['table']
      size = table['font_size'] ? table['font_size'].to_f : body_font_size
      {
        table_position_env: TABLE_POSITION_ENVS.fetch(table['position']),
        table_font_size: number(size),
        table_baseline: number(size * BASELINE_RATIO),
        table_cell_padding: table['cell_padding'],
        table_row_spacing: number(table['row_spacing']),
        table_header_bold: table.dig('header', 'bold'),
        table_rules: table['rules']
      }
    end

    def number(value)
      value.to_f.round(3).to_s.sub(/\.0\z/, '')
    end

    # --- Pandoc の実行 --------------------------------------------------

    def run_pandoc(paths)
      args = [
        'pandoc', paths[:body],
        '-f', PANDOC_READER,
        "--lua-filter=#{FILTER_PATH}",
        "--metadata-file=#{paths[:meta]}",
        "--include-in-header=#{paths[:preamble]}",
        '-V', 'indent=true', # Pandoc 標準の段落間隔・字下げなしの設定を無効にする
        '--number-sections',  # 見出しの番号（標準の見出しは filter.lua で番号なしにする）
        '--pdf-engine=xelatex',
        '-o', @output_path
      ]
      # 画像などの相対パスは、入力ファイルのある場所を基準にする
      _out, err, status = Open3.capture3(*args, chdir: File.dirname(@input_path))
      raise BuildError, pandoc_failure_message(status, err) unless status.success?

      err.strip
    end

    def pandoc_failure_message(status, err)
      lines = err.lines.map(&:rstrip).reject(&:empty?)
      shown = lines.last(PANDOC_ERROR_LINES)
      detail = shown.map { |line| "  #{line}" }.join("\n")
      "PDF の生成に失敗しました（pandoc の終了コード: #{status.exitstatus}）\n#{detail}"
    end
  end
end
